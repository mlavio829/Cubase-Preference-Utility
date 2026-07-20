import Foundation
@preconcurrency import ZIPFoundation

actor BackupService {
    typealias ProgressHandler = @Sendable (OperationProgress) async -> Void

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func inspectSources(_ sources: [BackupSource], homeDirectory: URL) throws -> [SourceStatus] {
        try sources.map { source in
            let url = source.url(relativeTo: homeDirectory)
            let present = itemExists(at: url)
            let statistics: (fileCount: Int, byteCount: Int64) = present
                ? try folderStatistics(at: url)
                : (fileCount: 0, byteCount: 0)
            return SourceStatus(
                source: source,
                url: url,
                isPresent: present,
                fileCount: statistics.fileCount,
                byteCount: statistics.byteCount
            )
        }
    }

    func scanLibrary(at libraryURL: URL) throws -> [BackupRecord] {
        guard itemExists(at: libraryURL) else { throw BackupError.libraryUnavailable }
        let urls = try fileManager.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return urls
            .filter { $0.pathExtension.caseInsensitiveCompare("cubasebackup") == .orderedSame }
            .compactMap { try? readRecord(at: $0) }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    func readRecord(at archiveURL: URL) throws -> BackupRecord {
        let manifest = try readAndValidateManifest(at: archiveURL)
        let byteCount = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return BackupRecord(url: archiveURL, manifest: manifest, archiveByteCount: Int64(byteCount))
    }

    func createBackup(
        sources: [BackupSource],
        homeDirectory: URL,
        libraryURL: URL,
        kind: BackupKind,
        appVersion: String,
        cubaseVersion: String?,
        progress: @escaping ProgressHandler
    ) async throws -> BackupRecord {
        try await createBackupInternal(
            sources: sources,
            homeDirectory: homeDirectory,
            libraryURL: libraryURL,
            kind: kind,
            appVersion: appVersion,
            cubaseVersion: cubaseVersion,
            allowEmpty: kind == .preRestore,
            progress: progress
        )
    }

    func restore(
        archiveURL: URL,
        sources: [BackupSource],
        homeDirectory: URL,
        libraryURL: URL,
        appVersion: String,
        cubaseVersion: String?,
        progress: @escaping ProgressHandler
    ) async throws -> RestoreResult {
        await progress(OperationProgress(phase: .validating))
        let manifest = try readAndValidateManifest(at: archiveURL)
        let temporaryRoot = fileManager.temporaryDirectory
            .appending(path: "CubasePreferenceRestore-\(UUID().uuidString)", directoryHint: .isDirectory)
        let extractionRoot = temporaryRoot.appending(path: "Extracted", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        try Task.checkCancellation()
        try fileManager.unzipItem(
            at: archiveURL,
            to: extractionRoot,
            skipCRC32: false,
            allowUncontainedSymlinks: false
        )
        try validateExtractedPayload(manifest: manifest, extractionRoot: extractionRoot)

        await progress(OperationProgress(phase: .safetyBackup))
        let safetyBackup: BackupRecord
        do {
            safetyBackup = try await createBackupInternal(
                sources: sources,
                homeDirectory: homeDirectory,
                libraryURL: libraryURL,
                kind: .preRestore,
                appVersion: appVersion,
                cubaseVersion: cubaseVersion,
                allowEmpty: true,
                progress: { _ in }
            )
        } catch {
            throw BackupError.safetyBackupFailed(error.localizedDescription)
        }

        let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let snapshots = manifest.presentSources
        var replacements: [Replacement] = []

        do {
            for (index, snapshot) in snapshots.enumerated() {
                await progress(OperationProgress(phase: .restoring, completed: index, total: snapshots.count))
                guard let source = sourceByID[snapshot.id] else {
                    throw BackupError.invalidArchive("It contains an unknown settings source.")
                }

                let extractedURL = extractionRoot.appending(path: snapshot.archivePath, directoryHint: .isDirectory)
                guard itemExists(at: extractedURL) else {
                    throw BackupError.invalidArchive("The payload for \(snapshot.name) is missing.")
                }

                let destinationURL = source.url(relativeTo: homeDirectory)
                let parentURL = destinationURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

                let token = UUID().uuidString
                let incomingURL = parentURL.appending(path: ".cubase-restore-new-\(token)", directoryHint: .isDirectory)
                let previousURL = parentURL.appending(path: ".cubase-restore-old-\(token)", directoryHint: .isDirectory)
                try fileManager.copyItem(at: extractedURL, to: incomingURL)

                let previousExisted = itemExists(at: destinationURL)
                if previousExisted {
                    try fileManager.moveItem(at: destinationURL, to: previousURL)
                }

                do {
                    try fileManager.moveItem(at: incomingURL, to: destinationURL)
                } catch {
                    if previousExisted, itemExists(at: previousURL) {
                        try? fileManager.moveItem(at: previousURL, to: destinationURL)
                    }
                    try? fileManager.removeItem(at: incomingURL)
                    throw error
                }

                replacements.append(
                    Replacement(
                        destinationURL: destinationURL,
                        previousURL: previousURL,
                        previousExisted: previousExisted
                    )
                )
            }

            for replacement in replacements where replacement.previousExisted {
                try? fileManager.removeItem(at: replacement.previousURL)
            }
            await progress(OperationProgress(phase: .restoring, completed: snapshots.count, total: snapshots.count))
            return RestoreResult(restoredSourceCount: snapshots.count, safetyBackup: safetyBackup)
        } catch {
            await progress(OperationProgress(phase: .rollingBack))
            for replacement in replacements.reversed() {
                if itemExists(at: replacement.destinationURL) {
                    try? fileManager.removeItem(at: replacement.destinationURL)
                }
                if replacement.previousExisted, itemExists(at: replacement.previousURL) {
                    try? fileManager.moveItem(at: replacement.previousURL, to: replacement.destinationURL)
                }
            }
            throw BackupError.restoreFailed(error.localizedDescription)
        }
    }

    func deleteBackup(at archiveURL: URL) throws {
        guard archiveURL.pathExtension.caseInsensitiveCompare("cubasebackup") == .orderedSame else {
            throw BackupError.invalidArchive("Only Cubase backup files can be deleted here.")
        }
        try fileManager.removeItem(at: archiveURL)
    }

    private func createBackupInternal(
        sources: [BackupSource],
        homeDirectory: URL,
        libraryURL: URL,
        kind: BackupKind,
        appVersion: String,
        cubaseVersion: String?,
        allowEmpty: Bool,
        progress: @escaping ProgressHandler
    ) async throws -> BackupRecord {
        guard itemExists(at: libraryURL) else { throw BackupError.libraryUnavailable }

        let temporaryRoot = fileManager.temporaryDirectory
            .appending(path: "CubasePreferenceBackup-\(UUID().uuidString)", directoryHint: .isDirectory)
        let stagingURL = temporaryRoot.appending(path: "Staging", directoryHint: .isDirectory)
        let payloadURL = stagingURL.appending(path: "payload", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: payloadURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        await progress(OperationProgress(phase: .inspecting))
        var snapshots: [BackupSourceSnapshot] = []
        var presentCount = 0

        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            await progress(OperationProgress(phase: .staging, completed: index, total: sources.count))
            let sourceURL = source.url(relativeTo: homeDirectory)
            let present = itemExists(at: sourceURL)
            var statistics = (fileCount: 0, byteCount: Int64(0))

            if present {
                presentCount += 1
                statistics = try folderStatistics(at: sourceURL)
                let destinationURL = stagingURL.appending(path: source.archivePath, directoryHint: .isDirectory)
                do {
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                } catch {
                    throw BackupError.sourceCopyFailed(sourceURL.path(percentEncoded: false))
                }
            }

            snapshots.append(
                BackupSourceSnapshot(
                    id: source.id,
                    name: source.name,
                    relativePath: source.relativePath,
                    archivePath: source.archivePath,
                    wasPresent: present,
                    fileCount: statistics.fileCount,
                    byteCount: statistics.byteCount
                )
            )
        }

        guard allowEmpty || presentCount > 0 else { throw BackupError.noSourcesFound }

        let manifest = BackupManifest(
            kind: kind,
            appVersion: appVersion,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            cubaseVersion: cubaseVersion,
            sources: snapshots
        )
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: stagingURL.appending(path: "manifest.json"), options: .atomic)

        try Task.checkCancellation()
        await progress(OperationProgress(phase: .archiving))
        let filename = archiveFilename(for: manifest)
        let finalURL = uniqueDestination(for: filename, in: libraryURL)
        let partialURL = libraryURL.appending(path: ".\(UUID().uuidString).partial")
        defer { try? fileManager.removeItem(at: partialURL) }

        try fileManager.zipItem(
            at: stagingURL,
            to: partialURL,
            shouldKeepParent: false,
            compressionMethod: .deflate
        )

        try Task.checkCancellation()
        await progress(OperationProgress(phase: .validating))
        let validated = try readAndValidateManifest(at: partialURL)
        guard validated.id == manifest.id else {
            throw BackupError.invalidArchive("The completed archive did not match its manifest.")
        }

        try fileManager.moveItem(at: partialURL, to: finalURL)
        await progress(OperationProgress(phase: .staging, completed: sources.count, total: sources.count))
        return try readRecord(at: finalURL)
    }

    private func readAndValidateManifest(at archiveURL: URL) throws -> BackupManifest {
        guard archiveURL.isFileURL else {
            throw BackupError.invalidArchive("The selected item is not a local file.")
        }

        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw BackupError.invalidArchive("The ZIP structure could not be read.")
        }

        guard let manifestEntry = archive["manifest.json"], manifestEntry.type == .file else {
            throw BackupError.invalidArchive("manifest.json is missing.")
        }

        var manifestData = Data()
        do {
            let checksum = try archive.extract(manifestEntry) { manifestData.append($0) }
            guard checksum == manifestEntry.checksum else {
                throw BackupError.invalidArchive("The manifest checksum is invalid.")
            }
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.invalidArchive("The manifest could not be read.")
        }

        let manifest: BackupManifest
        do {
            manifest = try decoder.decode(BackupManifest.self, from: manifestData)
        } catch {
            throw BackupError.invalidArchive("The manifest is malformed.")
        }

        guard manifest.schemaVersion == BackupManifest.currentSchemaVersion else {
            throw BackupError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.formatIdentifier == BackupManifest.formatIdentifier else {
            throw BackupError.invalidArchive("It was not created in the Cubase backup format.")
        }
        try validateManifestSources(manifest)

        let allowedRoots = Set(manifest.sources.map(\.archivePath))
        var sawManifest = false
        for entry in archive {
            let path = entry.path
            try validateArchivePath(path)
            if path == "manifest.json" {
                sawManifest = true
                continue
            }
            if path == "payload" || path == "payload/" { continue }
            guard allowedRoots.contains(where: { path == $0 || path == "\($0)/" || path.hasPrefix("\($0)/") }) else {
                throw BackupError.unsafeArchivePath(path)
            }
        }
        guard sawManifest else { throw BackupError.invalidArchive("manifest.json is missing.") }
        return manifest
    }

    private func validateManifestSources(_ manifest: BackupManifest) throws {
        let expected = Dictionary(uniqueKeysWithValues: BackupSource.cubase15Sources.map { ($0.id, $0) })
        let sourceIDs = Set(manifest.sources.map(\.id))
        guard sourceIDs.count == manifest.sources.count else {
            throw BackupError.invalidArchive("The manifest contains duplicate sources.")
        }
        guard sourceIDs == Set(expected.keys) else {
            throw BackupError.invalidArchive("The manifest does not describe all supported settings sources.")
        }

        for snapshot in manifest.sources {
            guard let source = expected[snapshot.id],
                  source.relativePath == snapshot.relativePath,
                  source.archivePath == snapshot.archivePath else {
                throw BackupError.invalidArchive("A source path does not match the supported Cubase 15 locations.")
            }
        }
    }

    private func validateArchivePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0"),
              !components.contains(where: { $0 == ".." }) else {
            throw BackupError.unsafeArchivePath(path)
        }
    }

    private func validateExtractedPayload(manifest: BackupManifest, extractionRoot: URL) throws {
        for snapshot in manifest.presentSources {
            let payloadURL = extractionRoot.appending(path: snapshot.archivePath, directoryHint: .isDirectory)
            guard itemExists(at: payloadURL) else {
                throw BackupError.invalidArchive("The payload for \(snapshot.name) is missing.")
            }
        }
    }

    private func folderStatistics(at rootURL: URL) throws -> (fileCount: Int, byteCount: Int64) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            return (0, 0)
        }

        var fileCount = 0
        var byteCount: Int64 = 0
        while let itemURL = enumerator.nextObject() as? URL {
            let values = try itemURL.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                fileCount += 1
                byteCount += Int64(values.fileSize ?? 0)
            } else if values.isSymbolicLink == true {
                fileCount += 1
            }
        }

        if let enumerationError { throw enumerationError }
        return (fileCount, byteCount)
    }

    private func itemExists(at url: URL) -> Bool {
        (try? url.checkResourceIsReachable()) == true || fileManager.fileExists(atPath: url.path)
    }

    private func archiveFilename(for manifest: BackupManifest) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let prefix = manifest.kind == .preRestore ? "Pre-Restore" : "Cubase Settings"
        return "\(prefix) - \(formatter.string(from: manifest.createdAt)).cubasebackup"
    }

    private func uniqueDestination(for filename: String, in libraryURL: URL) -> URL {
        let proposed = libraryURL.appending(path: filename)
        guard itemExists(at: proposed) else { return proposed }

        let stem = proposed.deletingPathExtension().lastPathComponent
        let suffix = UUID().uuidString.prefix(8)
        return libraryURL.appending(path: "\(stem) - \(suffix).cubasebackup")
    }
}

private extension BackupService {
    nonisolated struct Replacement: Sendable {
        let destinationURL: URL
        let previousURL: URL
        let previousExisted: Bool
    }
}
