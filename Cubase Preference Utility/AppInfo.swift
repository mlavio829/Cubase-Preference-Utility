import Foundation

nonisolated enum AppInfo {
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    static let repositoryURL = URL(string: "https://github.com/mlavio829/Cubase-Preference-Utility")!
    static let releasesURL = repositoryURL.appending(path: "releases/latest")
    static let issuesURL = repositoryURL.appending(path: "issues/new/choose")
}
