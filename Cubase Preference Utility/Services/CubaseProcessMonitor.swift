import AppKit
import Foundation

@MainActor
struct CubaseProcessMonitor {
    private let bundleIdentifierPrefix = "com.steinberg.cubase"

    func isCubaseRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { application in
            application.bundleIdentifier?.lowercased().hasPrefix(bundleIdentifierPrefix) == true
        }
    }

    func installedVersion() -> String? {
        let knownApplications = [
            URL(fileURLWithPath: "/Applications/Cubase 15.app", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Applications/Cubase 15.app", directoryHint: .isDirectory),
        ]

        return knownApplications.lazy.compactMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }.first
    }
}
