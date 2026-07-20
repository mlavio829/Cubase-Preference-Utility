import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingFolderPicker = false

    var body: some View {
        Form {
            Section("Backup Library") {
                LabeledContent("Location") {
                    Text(model.libraryURL?.path(percentEncoded: false) ?? "Not selected")
                        .foregroundStyle(model.libraryURL == nil ? .secondary : .primary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Choose Location…") { isShowingFolderPicker = true }
                    Button("Reveal in Finder") { model.revealLibrary() }
                        .disabled(model.libraryURL == nil)
                }
            }

            Section("Cubase 15 Sources") {
                ForEach(model.sources) { source in
                    LabeledContent(source.name) {
                        Text("~/\(source.relativePath)")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Privacy") {
                Text("The app contains no telemetry or analytics. Backups stay in the folder you choose, and update checks only open GitHub Releases in your browser.")
                    .foregroundStyle(.secondary)
            }

            Section("Project") {
                HStack {
                    Button("View on GitHub") {
                        NSWorkspace.shared.open(AppInfo.repositoryURL)
                    }
                    Button("Report an Issue") { model.openIssues() }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .fileImporter(
            isPresented: $isShowingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleFolderSelection,
            onCancellation: {}
        )
    }

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await model.chooseLibrary(url) }
        case .failure(let error):
            model.alert = AppAlert(kind: .error, title: "Couldn’t Choose Location", message: error.localizedDescription)
        }
    }
}
