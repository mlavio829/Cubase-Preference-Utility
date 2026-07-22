import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = [
        GridItem(.flexible(minimum: 260)),
        GridItem(.flexible(minimum: 260)),
    ]

    var body: some View {
        @Bindable var model = model

        ScrollView {
            LazyVStack(alignment: .leading) {
                HeroSection(model: model)

                if model.operation.isBusy {
                    OperationBanner(model: model)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }

                sourceSection
                librarySection
                historySection
            }
            .padding(24)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .background {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.08), Color.clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            .ignoresSafeArea()
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.isShowingBackupImporter = true
                } label: {
                    Label("Open Backup", systemImage: "doc.badge.arrow.up")
                }
                .help("Open a .cubasebackup file")
                .disabled(model.operation.isBusy)

                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh folders and backup history")
                .disabled(model.operation.isBusy)
            }
        }
        .fileImporter(
            isPresented: $model.isShowingBackupImporter,
            allowedContentTypes: [.cubaseBackup],
            allowsMultipleSelection: false,
            onCompletion: handleBackupImport,
            onCancellation: {}
        )
        .fileImporter(
            isPresented: $model.isShowingLibraryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleLibrarySelection,
            onCancellation: {}
        )
        .alert(item: $model.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: confirmationBinding,
            titleVisibility: .visible
        ) {
            confirmationActions
        } message: {
            Text(confirmationMessage)
        }
        .task { await model.initialize() }
        .task { await model.monitorCubase() }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading) {
            SectionHeading(
                title: "Settings Folders",
                subtitle: "Available folders are included automatically. Missing folders are safely skipped."
            )

            LazyVGrid(columns: columns) {
                ForEach(model.sources) { source in
                    SourceCard(
                        source: source,
                        status: model.sourceStatuses.first(where: { $0.id == source.id }),
                        openInFinder: { model.openSourceFolder(source) }
                    )
                }
            }
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading) {
            SectionHeading(
                title: "Backup Library",
                subtitle: "Backups stay here until you delete them. Choose iCloud Drive or an external disk for extra protection."
            )

            HStack {
                Image(systemName: model.libraryURL == nil ? "externaldrive.badge.questionmark" : "externaldrive.fill")
                    .font(.title2)
                    .foregroundStyle(model.libraryURL == nil ? Color.orange : Color.accentColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading) {
                    Text(model.libraryURL?.lastPathComponent ?? "No location selected")
                        .font(.headline)
                    Text(model.libraryURL?.path(percentEncoded: false) ?? "Choose where Cubase backups should be stored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                Spacer()

                if model.libraryURL != nil {
                    Button("Reveal") { model.revealLibrary() }
                }
                Button(model.libraryURL == nil ? "Choose Location" : "Change") {
                    model.isShowingLibraryPicker = true
                }
                .buttonStyle(.glass)
            }
            .cardSurface()
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading) {
            SectionHeading(
                title: "Backup History",
                subtitle: "Restore a snapshot or reveal it in Finder. A safety snapshot is created before every restore."
            )

            if model.libraryURL == nil {
                ContentUnavailableView(
                    "Choose a Backup Location",
                    systemImage: "externaldrive.badge.plus",
                    description: Text("Your backup history will appear here.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
                .cardSurface()
            } else if model.backups.isEmpty {
                ContentUnavailableView(
                    "No Backups Yet",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    description: Text("Close Cubase, then choose Back Up Now to create the first snapshot.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
                .cardSurface()
            } else {
                LazyVStack {
                    ForEach(model.backups) { record in
                        BackupRow(record: record, model: model)
                    }
                }
            }
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { model.confirmation != nil },
            set: { if !$0 { model.confirmation = nil } }
        )
    }

    private var confirmationTitle: String {
        switch model.confirmation {
        case .restore: "Restore This Backup?"
        case .delete: "Delete This Backup?"
        case nil: "Confirm"
        }
    }

    private var confirmationMessage: String {
        switch model.confirmation {
        case .restore(let record):
            "Cubase settings in \(record.manifest.presentSources.count) folders will be replaced. A pre-restore safety backup will be created first."
        case .delete(let record):
            "\(record.url.lastPathComponent) will be permanently removed."
        case nil:
            ""
        }
    }

    @ViewBuilder
    private var confirmationActions: some View {
        switch model.confirmation {
        case .restore(let record):
            Button("Restore Backup") { model.confirmRestore(record) }
            Button("Cancel", role: .cancel) { model.confirmation = nil }
        case .delete(let record):
            Button("Delete Backup", role: .destructive) { model.confirmDelete(record) }
            Button("Cancel", role: .cancel) { model.confirmation = nil }
        case nil:
            EmptyView()
        }
    }

    private func handleBackupImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await model.importBackup(url) }
        case .failure(let error):
            model.alert = AppAlert(kind: .error, title: "Couldn’t Open Backup", message: error.localizedDescription)
        }
    }

    private func handleLibrarySelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await model.chooseLibrary(url) }
        case .failure(let error):
            model.alert = AppAlert(kind: .error, title: "Couldn’t Choose Location", message: error.localizedDescription)
        }
    }
}

private struct HeroSection: View {
    let model: AppModel

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading) {
                Label("Cubase Preference Utility", systemImage: "archivebox.fill")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("Create dependable snapshots of your Cubase 15 settings and restore them safely.")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Label(
                    model.statusMessage,
                    systemImage: model.isCubaseRunning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(model.isCubaseRunning ? .orange : .secondary)
                .padding(.top, 4)
            }

            Spacer(minLength: 24)

            Button {
                model.startBackup()
            } label: {
                Label("Back Up Now", systemImage: "arrow.down.doc.fill")
                    .font(.headline)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canBackUp)
            .accessibilityHint("Creates a new snapshot in the selected backup library")
        }
        .padding(24)
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }
}

private struct OperationBanner: View {
    let model: AppModel

    var body: some View {
        HStack {
            if let fraction = model.operation.progress?.fractionCompleted {
                ProgressView(value: fraction)
                    .frame(width: 120)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            VStack(alignment: .leading) {
                Text(model.operation.title)
                    .font(.headline)
                Text(model.operation.progress?.phase.rawValue ?? "Working")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if case .backingUp(let progress) = model.operation,
               progress.phase == .inspecting || progress.phase == .staging {
                Button("Cancel") { model.cancelBackup() }
            }
        }
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.operation.title), \(model.operation.progress?.phase.rawValue ?? "working")")
    }
}

private struct SourceCard: View {
    let source: BackupSource
    let status: SourceStatus?
    let openInFinder: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: source.symbolName)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.12), in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading) {
                Text(source.name)
                    .font(.headline)

                Text("~/\(source.relativePath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                Label(statusText, systemImage: status?.isPresent == true ? "checkmark.circle.fill" : "minus.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status?.isPresent == true ? .green : .secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .cardSurface()
        .contentShape(.interaction, .rect(cornerRadius: 14))
        .contextMenu {
            Button(action: openInFinder) {
                Label("Open Folder Location", systemImage: "folder")
            }
        }
        .help(status?.isPresent == true ? "Right-click to open this folder in Finder" : "Right-click to open the nearest available parent folder in Finder")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("source-card-\(source.id.rawValue)")
    }

    private var statusText: String {
        guard let status else { return "Checking…" }
        guard status.isPresent else { return "Not found — skipped" }
        let size = ByteCountFormatter.string(fromByteCount: status.byteCount, countStyle: .file)
        return "Available · \(status.fileCount) items · \(size)"
    }
}

private struct BackupRow: View {
    let record: BackupRecord
    let model: AppModel

    var body: some View {
        HStack {
            Image(systemName: record.manifest.kind == .preRestore ? "lifepreserver.fill" : "archivebox.fill")
                .font(.title2)
                .foregroundStyle(record.manifest.kind == .preRestore ? Color.orange : Color.accentColor)
                .frame(width: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading) {
                Text(record.manifest.kind.displayName)
                    .font(.headline)
                Text(record.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
                if let computerName = record.manifest.computerName {
                    Text(computerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(record.manifest.presentSources.count) folders · \(ByteCountFormatter.string(fromByteCount: record.archiveByteCount, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Restore") { model.requestRestore(record) }
                .buttonStyle(.glass)
                .disabled(model.operation.isBusy || model.isCubaseRunning)
                .accessibilityLabel("Restore backup from \(record.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))")

            Menu {
                Button("Reveal in Finder") { model.revealBackup(record) }
                Divider()
                Button("Delete Backup", role: .destructive) { model.requestDelete(record) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 32, minHeight: 32)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("More actions for backup from \(record.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))")
        }
        .cardSurface()
    }
}

private struct SectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }
}

private struct CardSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                reduceTransparency ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .controlBackgroundColor).opacity(0.72),
                in: .rect(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.separator.opacity(0.45))
            }
    }
}

private extension View {
    func cardSurface() -> some View {
        modifier(CardSurface())
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
        .frame(width: 920, height: 760)
}
