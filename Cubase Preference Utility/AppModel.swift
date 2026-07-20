import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let sources: [BackupSource]

    private(set) var sourceStatuses: [SourceStatus] = []
    private(set) var backups: [BackupRecord] = []
    private(set) var libraryURL: URL?
    private(set) var isCubaseRunning = false
    private(set) var cubaseVersion: String?
    private(set) var operation: OperationState = .idle
    var alert: AppAlert?
    var confirmation: ConfirmationRequest?
    var isShowingBackupImporter = false
    var isShowingLibraryPicker = false

    @ObservationIgnored private let backupService: BackupService
    @ObservationIgnored private let libraryStore: BackupLibraryStore
    @ObservationIgnored private let processMonitor: CubaseProcessMonitor
    @ObservationIgnored private let homeDirectory: URL
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    init(
        sources: [BackupSource] = BackupSource.cubase15Sources,
        backupService: BackupService = BackupService(),
        libraryStore: BackupLibraryStore = BackupLibraryStore(),
        processMonitor: CubaseProcessMonitor = CubaseProcessMonitor(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.sources = sources
        self.backupService = backupService
        self.libraryStore = libraryStore
        self.processMonitor = processMonitor
        self.homeDirectory = homeDirectory
        libraryURL = libraryStore.resolve()
        refreshProcessState()
    }

    deinit {
        operationTask?.cancel()
    }

    var canBackUp: Bool {
        libraryURL != nil && sourceStatuses.contains(where: \.isPresent) && !isCubaseRunning && !operation.isBusy
    }

    var statusMessage: String {
        if isCubaseRunning { return "Quit Cubase to protect settings while files are copied." }
        if libraryURL == nil { return "Choose a backup location to get started." }
        if sourceStatuses.contains(where: \.isPresent) == false { return "No supported Cubase settings folders were found." }
        return "Cubase is closed. Your settings are ready to back up."
    }

    func initialize() async {
        await refreshAll(showErrors: false)
    }

    func monitorCubase() async {
        while !Task.isCancelled {
            refreshProcessState()
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
        }
    }

    func chooseLibrary(_ url: URL) async {
        guard !operation.isBusy else { return }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw BackupError.libraryUnavailable
            }
            try libraryStore.save(url)
            libraryURL = url
            await refreshAll(showErrors: true)
        } catch {
            showError(error, title: "Couldn’t Use That Folder")
        }
    }

    func startBackup() {
        guard operationTask == nil, canBackUp else {
            if isCubaseRunning { showError(BackupError.cubaseIsRunning, title: "Cubase Is Running") }
            return
        }

        operation = .backingUp(OperationProgress(phase: .inspecting))
        operationTask = Task { [weak self] in
            await self?.performBackup()
        }
    }

    func cancelBackup() {
        guard case .backingUp = operation else { return }
        operationTask?.cancel()
    }

    func requestRestore(_ record: BackupRecord) {
        guard !operation.isBusy else { return }
        guard !isCubaseRunning else {
            showError(BackupError.cubaseIsRunning, title: "Cubase Is Running")
            return
        }
        confirmation = .restore(record)
    }

    func confirmRestore(_ record: BackupRecord) {
        confirmation = nil
        guard operationTask == nil, !operation.isBusy else { return }
        guard !isCubaseRunning else {
            showError(BackupError.cubaseIsRunning, title: "Cubase Is Running")
            return
        }

        operation = .restoring(OperationProgress(phase: .validating))
        operationTask = Task { [weak self] in
            await self?.performRestore(record)
        }
    }

    func requestDelete(_ record: BackupRecord) {
        guard !operation.isBusy else { return }
        confirmation = .delete(record)
    }

    func confirmDelete(_ record: BackupRecord) {
        confirmation = nil
        guard !operation.isBusy else { return }
        Task { [weak self] in
            await self?.performDelete(record)
        }
    }

    func importBackup(_ url: URL) async {
        guard !operation.isBusy else { return }
        let access = SecurityScopedAccess(url: url)
        defer { access.stop() }

        do {
            let record = try await backupService.readRecord(at: url)
            requestRestore(record)
        } catch {
            showError(error, title: "Couldn’t Open Backup")
        }
    }

    func refreshAll(showErrors: Bool = true) async {
        refreshProcessState()
        do {
            sourceStatuses = try await backupService.inspectSources(sources, homeDirectory: homeDirectory)
            if let libraryURL {
                let access = SecurityScopedAccess(url: libraryURL)
                defer { access.stop() }
                backups = try await backupService.scanLibrary(at: libraryURL)
            } else {
                backups = []
            }
        } catch {
            if showErrors { showError(error, title: "Couldn’t Refresh") }
        }
    }

    func revealLibrary() {
        guard let libraryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([libraryURL])
    }

    func revealBackup(_ record: BackupRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.url])
    }

    func openReleases() {
        NSWorkspace.shared.open(AppInfo.releasesURL)
    }

    func openIssues() {
        NSWorkspace.shared.open(AppInfo.issuesURL)
    }

    private func performBackup() async {
        defer {
            operation = .idle
            operationTask = nil
        }

        guard let libraryURL else {
            showError(BackupError.libraryUnavailable, title: "Choose a Backup Location")
            return
        }
        refreshProcessState()
        guard !isCubaseRunning else {
            showError(BackupError.cubaseIsRunning, title: "Cubase Is Running")
            return
        }

        let access = SecurityScopedAccess(url: libraryURL)
        defer { access.stop() }
        do {
            let record = try await backupService.createBackup(
                sources: sources,
                homeDirectory: homeDirectory,
                libraryURL: libraryURL,
                kind: .manual,
                appVersion: AppInfo.version,
                cubaseVersion: cubaseVersion
            ) { [weak self] progress in
                await self?.setBackupProgress(progress)
            }
            await refreshAll(showErrors: false)
            alert = AppAlert(
                kind: .success,
                title: "Backup Complete",
                message: "Saved \(record.manifest.presentSources.count) settings folders to \(record.url.lastPathComponent)."
            )
        } catch is CancellationError {
            alert = AppAlert(kind: .information, title: "Backup Cancelled", message: "No partial backup was kept.")
        } catch {
            showError(error, title: "Backup Failed")
        }
    }

    private func performRestore(_ record: BackupRecord) async {
        defer {
            operation = .idle
            operationTask = nil
        }

        guard let libraryURL else {
            showError(BackupError.libraryUnavailable, title: "Backup Library Unavailable")
            return
        }
        refreshProcessState()
        guard !isCubaseRunning else {
            showError(BackupError.cubaseIsRunning, title: "Cubase Is Running")
            return
        }

        let libraryAccess = SecurityScopedAccess(url: libraryURL)
        let archiveAccess = SecurityScopedAccess(url: record.url)
        defer {
            archiveAccess.stop()
            libraryAccess.stop()
        }

        do {
            let result = try await backupService.restore(
                archiveURL: record.url,
                sources: sources,
                homeDirectory: homeDirectory,
                libraryURL: libraryURL,
                appVersion: AppInfo.version,
                cubaseVersion: cubaseVersion
            ) { [weak self] progress in
                await self?.setRestoreProgress(progress)
            }
            await refreshAll(showErrors: false)
            alert = AppAlert(
                kind: .success,
                title: "Restore Complete",
                message: "Restored \(result.restoredSourceCount) settings folders. A safety backup was saved as \(result.safetyBackup.url.lastPathComponent)."
            )
        } catch {
            showError(error, title: "Restore Failed")
        }
    }

    private func performDelete(_ record: BackupRecord) async {
        do {
            try await backupService.deleteBackup(at: record.url)
            await refreshAll(showErrors: false)
            alert = AppAlert(kind: .information, title: "Backup Deleted", message: record.url.lastPathComponent)
        } catch {
            showError(error, title: "Couldn’t Delete Backup")
        }
    }

    private func setBackupProgress(_ progress: OperationProgress) {
        operation = .backingUp(progress)
    }

    private func setRestoreProgress(_ progress: OperationProgress) {
        operation = .restoring(progress)
    }

    private func refreshProcessState() {
        isCubaseRunning = processMonitor.isCubaseRunning()
        cubaseVersion = processMonitor.installedVersion()
    }

    private func showError(_ error: Error, title: String) {
        alert = AppAlert(kind: .error, title: title, message: error.localizedDescription)
    }
}
