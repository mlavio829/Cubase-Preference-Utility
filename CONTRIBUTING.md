# Contributing

Thank you for helping improve Cubase Preference Utility.

## Before opening a pull request

1. Search existing issues and pull requests.
2. Open an issue before making a large product or archive-format change.
3. Keep real Cubase data out of fixtures, logs, screenshots, and commits.
4. Add or update tests for behavior changes.
5. Run the app scheme’s tests on macOS 26 with Xcode 26.6 or newer.

## Development expectations

- Use Swift 6 concurrency checks and keep UI state on `MainActor`.
- Keep filesystem tests isolated to temporary directories.
- Preserve schema-v1 compatibility unless a migration is explicitly designed.
- Do not add telemetry, network backup, or a new dependency without discussion.
- Use semantic SwiftUI controls and include keyboard and accessibility behavior.

By submitting a contribution, you agree that it is licensed under the project’s MIT License.
