#if os(iOS)
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AppleFilesSourceEditor: View {
    let source: MediaSource?
    var onSaved: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var scanner: LibraryScanner
    @State private var name = "Google Drive"
    @State private var ignoredFolders: [String] = []
    @State private var ignoredFiles: [String] = []
    @State private var showingFiles = false
    @State private var choosingDirectory = true
    @State private var pickerSession: UUID?
    @State private var selection: AppleFilesSelection?
    @State private var reconnectDirectory = true
    @State private var error: String?
    @State private var confirmsDisconnect = false

    private let household = HouseholdStore.shared
    private var trimmedName: String { String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)) }

    var body: some View {
        Form {
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            Section("Library") {
                TextField("Library name", text: $name)
                    .accessibilityIdentifier("files-source-name")
                if source != nil {
                    Button("Save and rescan", action: save).disabled(trimmedName.isEmpty || scanner.isScanning)
                } else if let selection {
                    Text(selection.directory ? (selection.entries.first?.name ?? "Folder") :
                         "\(selection.entries.count) selected files")
                    Button("Add selection and scan", action: save).disabled(trimmedName.isEmpty || scanner.isScanning)
                        .accessibilityIdentifier("files-source-save")
                }
            }
            if let source {
                if let config = try? source.config() {
                    SourceExclusionsEditor(folders: $ignoredFolders, files: $ignoredFiles, configuration: config)
                }
                Section("Connection") {
                    Button("Reconnect in Files") { pick(directory: reconnectDirectory) }.disabled(scanner.isScanning)
                    Button("Disconnect Files source", role: .destructive) { confirmsDisconnect = true }.disabled(scanner.isScanning)
                }
            } else {
                Section("Google Drive in Files") {
                    Text("In Files, tap Browse, then choose Google Drive under Locations. If the folder cannot be selected, choose the media files and any matching subtitle files.")
                    Button("Choose a folder") { pick(directory: true) }.accessibilityIdentifier("files-source-folder")
                    Button("Choose files") { pick(directory: false) }.accessibilityIdentifier("files-source-files")
                }
            }
        }
        .navigationTitle(source == nil ? "Google Drive via Files" : "Files source")
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: choosingDirectory ? [.folder] : [.data],
                      allowsMultipleSelection: !choosingDirectory, onCompletion: didPick)
        .onAppear {
            if let source {
                name = source.name
                ignoredFolders = source.ignoredFolders ?? []
                ignoredFiles = source.ignoredFiles ?? []
                reconnectDirectory = (try? AppleFilesSource.isDirectory(source.id)) ?? true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HouseholdStore.willLock, object: household)) { _ in
            pickerSession = nil
            selection = nil
            showingFiles = false
            dismiss()
        }
        .confirmationDialog("Disconnect this Files source and remove its MediaVault library?", isPresented: $confirmsDisconnect) {
            Button("Disconnect and remove", role: .destructive, action: disconnect)
        }
    }

    private func pick(directory: Bool) {
        guard household.isAdmin, !scanner.isScanning else { return }
        pickerSession = household.sessionToken
        choosingDirectory = directory
        error = nil
        showingFiles = true
    }

    private func didPick(_ result: Result<[URL], Error>) {
        guard let session = pickerSession, household.sessionIsCurrent(session), household.isAdmin else { return }
        pickerSession = nil
        do {
            let selected = try AppleFilesSelection.capture(result.get(), directory: choosingDirectory)
            if let source {
                try AppleFilesSource.install(selected, id: source.id, replacing: true)
                scan(source)
            } else {
                selection = selected
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        guard household.isAdmin, !scanner.isScanning, !trimmedName.isEmpty else { return }
        error = nil
        if let source {
            do {
                source.name = trimmedName
                try source.applyIgnoredPaths(folders: ignoredFolders, files: ignoredFiles)
                try context.save()
                scan(source)
                dismiss()
            } catch {
                context.rollback()
                self.error = error.localizedDescription
            }
            return
        }
        guard let selection else { return }
        let target = MediaSource(name: trimmedName, host: "", share: "", rootPath: "", username: "")
        target.sourceProtocol = CloudFileProvider.appleFiles.rawValue
        do {
            try AppleFilesSource.install(selection, id: target.id, replacing: false)
            context.insert(target)
            do { try context.save() }
            catch {
                context.rollback()
                try? AppleFilesSource.remove(target.id)
                throw error
            }
            self.selection = nil
            scan(target)
            if let onSaved { onSaved() } else { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func disconnect() {
        guard let source, household.isAdmin, !scanner.isScanning else { return }
        do {
            let id = source.id
            try AppleFilesSource.remove(id) {
                context.delete(source)
                do { try context.save() }
                catch { context.rollback(); throw error }
            }
            Task { await SMBService.shared.reset(sourceID: id) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func scan(_ target: MediaSource) {
        let session = household.sessionToken
        Task {
            await SMBService.shared.reset(sourceID: target.id)
            guard household.isAdmin, household.sessionIsCurrent(session) else { return }
            await scanner.scan(target, context: context)
        }
    }
}
#endif
