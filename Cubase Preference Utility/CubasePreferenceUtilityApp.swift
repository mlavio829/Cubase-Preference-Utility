import SwiftUI

@main
struct CubasePreferenceUtilityApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 620)
                .onOpenURL { url in
                    Task { await model.importBackup(url) }
                }
        }
        .defaultSize(width: 920, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 520)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Backup") {
            Button("Back Up Now") {
                model.startBackup()
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(!model.canBackUp)

            Button("Open Backup…") {
                model.isShowingBackupImporter = true
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(model.operation.isBusy)

            Divider()

            Button("Reveal Backup Library") {
                model.revealLibrary()
            }
            .disabled(model.libraryURL == nil)
        }

        CommandGroup(after: .help) {
            Button("Check for Updates…") {
                model.openReleases()
            }

            Button("Report an Issue…") {
                model.openIssues()
            }
        }
    }
}
