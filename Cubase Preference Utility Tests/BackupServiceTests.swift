import Foundation
import Testing
import ZIPFoundation
@testable import Cubase_Preference_Utility

@Suite("Backup service")
struct BackupServiceTests {
    @Test("Default sources resolve below any user home")
    func sourceResolutionUsesProvidedHome() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let paths = BackupSource.cubase15Sources.map {
            let path = $0.url(relativeTo: home).path(percentEncoded: false)
            return path.hasSuffix("/") ? String(path.dropLast()) : path
        }

        #expect(paths == [
            "/Users/example/Library/Application Support/Steinberg/Content",
            "/Users/example/Library/Audio/Presets/Steinberg Media Technologies",
            "/Users/example/Library/Audio/Steinberg",
            "/Users/example/Library/Preferences/Cubase 15",
        ])
    }

    @Test("Missing sources resolve to their nearest existing parent for Finder")
    func missingSourceFinderFallback() throws {
        let fixture = try TestFixture()
        defer { fixture.remove() }
        let audio = fixture.home.appending(path: "Library/Audio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let source = BackupSource.cubase15Sources[2]

        #expect(source.nearestExistingDirectory(relativeTo: fixture.home)?.standardizedFileURL == audio.standardizedFileURL)

        let exactSource = source.url(relativeTo: fixture.home)
        try FileManager.default.createDirectory(at: exactSource, withIntermediateDirectories: true)
        #expect(source.nearestExistingDirectory(relativeTo: fixture.home)?.standardizedFileURL == exactSource.standardizedFileURL)
    }

    @Test("Backup and restore round trip replaces stale contents and preserves absent sources")
    func backupAndRestoreRoundTrip() async throws {
        let fixture = try TestFixture()
        defer { fixture.remove() }

        let preferences = BackupSource.cubase15Sources[3].url(relativeTo: fixture.home)
        try FileManager.default.createDirectory(at: preferences.appending(path: "Empty", directoryHint: .isDirectory), withIntermediateDirectories: true)
        let settingsFile = preferences.appending(path: "Réglages.xml")
        try Data("original".utf8).write(to: settingsFile)
        try FileManager.default.createSymbolicLink(
            atPath: preferences.appending(path: "Current Settings").path,
            withDestinationPath: "Réglages.xml"
        )

        let service = BackupService()
        let backup = try await service.createBackup(
            sources: BackupSource.cubase15Sources,
            homeDirectory: fixture.home,
            libraryURL: fixture.library,
            kind: .manual,
            appVersion: "1.0 (1)",
            cubaseVersion: "15.0.30",
            progress: { _ in }
        )

        #expect(backup.manifest.presentSources.map(\.id) == [.cubasePreferences])

        try FileManager.default.removeItem(at: preferences)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: preferences.appending(path: "stale.txt"))

        let audioSteinberg = BackupSource.cubase15Sources[2].url(relativeTo: fixture.home)
        try FileManager.default.createDirectory(at: audioSteinberg, withIntermediateDirectories: true)
        try Data("leave me".utf8).write(to: audioSteinberg.appending(path: "newer.txt"))

        let result = try await service.restore(
            archiveURL: backup.url,
            sources: BackupSource.cubase15Sources,
            homeDirectory: fixture.home,
            libraryURL: fixture.library,
            appVersion: "1.0 (1)",
            cubaseVersion: "15.0.30",
            progress: { _ in }
        )

        #expect(result.restoredSourceCount == 1)
        #expect(FileManager.default.fileExists(atPath: preferences.appending(path: "stale.txt").path) == false)
        #expect(try String(contentsOf: settingsFile, encoding: .utf8) == "original")
        #expect(try String(contentsOf: audioSteinberg.appending(path: "newer.txt"), encoding: .utf8) == "leave me")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: preferences.appending(path: "Current Settings").path).contains("Réglages.xml"))
        #expect(result.safetyBackup.manifest.kind == .preRestore)
        #expect(Set(result.safetyBackup.manifest.presentSources.map(\.id)) == [.audioSteinberg, .cubasePreferences])
    }

    @Test("Manual backup fails when every source is missing")
    func missingSourcesAreRejected() async throws {
        let fixture = try TestFixture()
        defer { fixture.remove() }
        let service = BackupService()

        await #expect(throws: BackupError.noSourcesFound) {
            try await service.createBackup(
                sources: BackupSource.cubase15Sources,
                homeDirectory: fixture.home,
                libraryURL: fixture.library,
                kind: .manual,
                appVersion: "1.0",
                cubaseVersion: nil,
                progress: { _ in }
            )
        }
    }

    @Test("Unsafe archive traversal is rejected")
    func traversalArchiveIsRejected() async throws {
        let fixture = try TestFixture()
        defer { fixture.remove() }
        let archiveURL = fixture.library.appending(path: "malicious.cubasebackup")
        let manifest = BackupManifest(
            kind: .manual,
            appVersion: "1.0",
            macOSVersion: "26.0",
            cubaseVersion: "15",
            sources: BackupSource.cubase15Sources.map {
                BackupSourceSnapshot(
                    id: $0.id,
                    name: $0.name,
                    relativePath: $0.relativePath,
                    archivePath: $0.archivePath,
                    wasPresent: false,
                    fileCount: 0,
                    byteCount: 0
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try addData(manifestData, path: "manifest.json", to: archive)
        try addData(Data("escape".utf8), path: "../escape.txt", to: archive)

        let service = BackupService()
        await #expect(throws: BackupError.self) {
            try await service.readRecord(at: archiveURL)
        }
    }

    @Test("Foreign and corrupt files are rejected")
    func corruptArchiveIsRejected() async throws {
        let fixture = try TestFixture()
        defer { fixture.remove() }
        let archiveURL = fixture.library.appending(path: "corrupt.cubasebackup")
        try Data("not a zip".utf8).write(to: archiveURL)

        let service = BackupService()
        await #expect(throws: BackupError.self) {
            try await service.readRecord(at: archiveURL)
        }
    }

    @Test("Foreign format identifiers are rejected")
    func foreignArchiveIsRejected() async throws {
        let fixture = try TestFixture()
        defer { fixture.remove() }
        let archiveURL = fixture.library.appending(path: "foreign.cubasebackup")
        let manifest = BackupManifest(
            formatIdentifier: "example.foreign-backup",
            kind: .manual,
            appVersion: "1.0",
            macOSVersion: "26.0",
            cubaseVersion: nil,
            sources: snapshots()
        )
        try createArchive(at: archiveURL, manifest: manifest)

        let service = BackupService()
        await #expect(throws: BackupError.self) {
            try await service.readRecord(at: archiveURL)
        }
    }

    @Test("Unsupported manifest schemas are rejected")
    func unsupportedSchemaIsRejected() async throws {
        let fixture = try TestFixture()
        defer { fixture.remove() }
        let archiveURL = fixture.library.appending(path: "future.cubasebackup")
        let manifest = BackupManifest(
            schemaVersion: 999,
            kind: .manual,
            appVersion: "99.0",
            macOSVersion: "99.0",
            cubaseVersion: nil,
            sources: snapshots()
        )
        try createArchive(at: archiveURL, manifest: manifest)

        let service = BackupService()
        await #expect(throws: BackupError.unsupportedSchema(999)) {
            try await service.readRecord(at: archiveURL)
        }
    }

    private func snapshots() -> [BackupSourceSnapshot] {
        BackupSource.cubase15Sources.map {
            BackupSourceSnapshot(
                id: $0.id,
                name: $0.name,
                relativePath: $0.relativePath,
                archivePath: $0.archivePath,
                wasPresent: false,
                fileCount: 0,
                byteCount: 0
            )
        }
    }

    private func createArchive(at url: URL, manifest: BackupManifest) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let archive = try Archive(url: url, accessMode: .create)
        try addData(try encoder.encode(manifest), path: "manifest.json", to: archive)
    }

    private func addData(_ data: Data, path: String, to archive: Archive) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate
        ) { position, size in
            let lower = Int(position)
            return data.subdata(in: lower..<(lower + size))
        }
    }
}

private struct TestFixture {
    let root: URL
    let home: URL
    let library: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "CubasePreferenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "Home", directoryHint: .isDirectory)
        library = root.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
