import Foundation

nonisolated enum BackupSourceID: String, CaseIterable, Codable, Sendable {
    case steinbergContent
    case audioPresets
    case audioSteinberg
    case cubasePreferences
}

nonisolated struct BackupSource: Identifiable, Codable, Hashable, Sendable {
    let id: BackupSourceID
    let name: String
    let relativePath: String
    let symbolName: String

    var archivePath: String { "payload/\(id.rawValue)" }

    func url(relativeTo homeDirectory: URL) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(homeDirectory) { url, component in
                url.appending(path: String(component), directoryHint: .isDirectory)
            }
    }

    func nearestExistingDirectory(relativeTo homeDirectory: URL, fileManager: FileManager = .default) -> URL? {
        var directoryURL = url(relativeTo: homeDirectory)
        let homePath = homeDirectory.standardizedFileURL.path

        while true {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return directoryURL
            }
            guard directoryURL.standardizedFileURL.path != homePath else { return nil }
            directoryURL.deleteLastPathComponent()
        }
    }

    static let cubase15Sources: [BackupSource] = [
        BackupSource(
            id: .steinbergContent,
            name: "Steinberg Content",
            relativePath: "Library/Application Support/Steinberg/Content",
            symbolName: "shippingbox"
        ),
        BackupSource(
            id: .audioPresets,
            name: "Audio Presets",
            relativePath: "Library/Audio/Presets/Steinberg Media Technologies",
            symbolName: "slider.horizontal.3"
        ),
        BackupSource(
            id: .audioSteinberg,
            name: "Audio Steinberg",
            relativePath: "Library/Audio/Steinberg",
            symbolName: "waveform"
        ),
        BackupSource(
            id: .cubasePreferences,
            name: "Cubase 15 Preferences",
            relativePath: "Library/Preferences/Cubase 15",
            symbolName: "gearshape"
        ),
    ]
}

nonisolated struct BackupSourceSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: BackupSourceID
    let name: String
    let relativePath: String
    let archivePath: String
    let wasPresent: Bool
    let fileCount: Int
    let byteCount: Int64
}

nonisolated enum BackupKind: String, Codable, Hashable, Sendable {
    case manual
    case preRestore

    var displayName: String {
        switch self {
        case .manual: "Manual Backup"
        case .preRestore: "Pre-Restore Safety Backup"
        }
    }
}

nonisolated struct BackupManifest: Identifiable, Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    static let formatIdentifier = "com.lavicon.cubase-backup"

    let formatIdentifier: String
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let kind: BackupKind
    let appVersion: String
    let macOSVersion: String
    let cubaseVersion: String?
    let sources: [BackupSourceSnapshot]

    init(
        formatIdentifier: String = Self.formatIdentifier,
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID = UUID(),
        createdAt: Date = .now,
        kind: BackupKind,
        appVersion: String,
        macOSVersion: String,
        cubaseVersion: String?,
        sources: [BackupSourceSnapshot]
    ) {
        self.formatIdentifier = formatIdentifier
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.cubaseVersion = cubaseVersion
        self.sources = sources
    }

    var presentSources: [BackupSourceSnapshot] {
        sources.filter(\.wasPresent)
    }

    var totalByteCount: Int64 {
        presentSources.reduce(0) { $0 + $1.byteCount }
    }
}

nonisolated struct BackupRecord: Identifiable, Hashable, Sendable {
    let url: URL
    let manifest: BackupManifest
    let archiveByteCount: Int64

    var id: UUID { manifest.id }
}

nonisolated struct RestoreResult: Sendable {
    let restoredSourceCount: Int
    let safetyBackup: BackupRecord
}

nonisolated struct SourceStatus: Identifiable, Hashable, Sendable {
    let source: BackupSource
    let url: URL
    let isPresent: Bool
    let fileCount: Int
    let byteCount: Int64

    var id: BackupSourceID { source.id }
}

nonisolated enum OperationPhase: String, Equatable, Sendable {
    case inspecting = "Inspecting folders"
    case staging = "Copying settings"
    case archiving = "Creating archive"
    case validating = "Validating archive"
    case safetyBackup = "Creating safety backup"
    case restoring = "Restoring settings"
    case rollingBack = "Rolling back changes"
    case refreshing = "Refreshing backup library"
}

nonisolated struct OperationProgress: Equatable, Sendable {
    let phase: OperationPhase
    let completed: Int
    let total: Int

    init(phase: OperationPhase, completed: Int = 0, total: Int = 0) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }

    var fractionCompleted: Double? {
        guard total > 0 else { return nil }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

enum OperationState: Equatable {
    case idle
    case backingUp(OperationProgress)
    case restoring(OperationProgress)

    var isBusy: Bool {
        if case .idle = self { return false }
        return true
    }

    var progress: OperationProgress? {
        switch self {
        case .idle: nil
        case .backingUp(let progress), .restoring(let progress): progress
        }
    }

    var title: String {
        switch self {
        case .idle: "Ready"
        case .backingUp: "Backing Up"
        case .restoring: "Restoring"
        }
    }
}

nonisolated enum BackupError: LocalizedError, Equatable, Sendable {
    case noSourcesFound
    case libraryUnavailable
    case cubaseIsRunning
    case invalidArchive(String)
    case unsupportedSchema(Int)
    case unsafeArchivePath(String)
    case sourceCopyFailed(String)
    case safetyBackupFailed(String)
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSourcesFound:
            "No Cubase settings folders were found."
        case .libraryUnavailable:
            "The backup library is unavailable. Choose or reconnect its folder."
        case .cubaseIsRunning:
            "Quit Cubase before backing up or restoring settings."
        case .invalidArchive(let reason):
            "This is not a valid Cubase settings backup. \(reason)"
        case .unsupportedSchema(let version):
            "This backup uses unsupported format version \(version)."
        case .unsafeArchivePath(let path):
            "The backup contains an unsafe path: \(path)"
        case .sourceCopyFailed(let path):
            "Could not copy the settings at \(path)."
        case .safetyBackupFailed(let reason):
            "The safety backup could not be created, so nothing was restored. \(reason)"
        case .restoreFailed(let reason):
            "The restore could not be completed. \(reason)"
        }
    }
}

struct AppAlert: Identifiable, Equatable {
    enum Kind: Equatable {
        case success
        case error
        case information
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
}

enum ConfirmationRequest: Identifiable, Equatable {
    case restore(BackupRecord)
    case delete(BackupRecord)

    var id: String {
        switch self {
        case .restore(let record): "restore-\(record.id)"
        case .delete(let record): "delete-\(record.id)"
        }
    }
}
