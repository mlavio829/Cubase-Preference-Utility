import Foundation

@MainActor
final class BackupLibraryStore {
    private let defaults: UserDefaults
    private let bookmarkKey = "backupLibraryBookmark"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
        defaults.set(data, forKey: bookmarkKey)
    }

    func resolve() -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        if isStale {
            try? save(url)
        }
        return url
    }

    func clear() {
        defaults.removeObject(forKey: bookmarkKey)
    }
}

nonisolated struct SecurityScopedAccess: Sendable {
    let url: URL
    private let didStart: Bool

    init(url: URL) {
        self.url = url
        didStart = url.startAccessingSecurityScopedResource()
    }

    func stop() {
        if didStart {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
