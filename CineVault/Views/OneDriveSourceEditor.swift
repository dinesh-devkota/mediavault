import SwiftData
import SwiftUI

@MainActor
struct OneDriveSourceEditor: View {
    let source: MediaSource?
    var onSaved: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var scanner: LibraryScanner

    private struct Draft {
        let clientID: String
        let client: OneDriveClient
        let driveID: String
        let credentials: OneDriveClient.Credentials
    }

    @State private var sourceID = UUID()
    @State private var name = ""
    @State private var clientID = ""
    @State private var draftsFolder: [CloudFileTransport.Item] = []
    @State private var children: [CloudFileTransport.Item] = []
    @State private var ignoredFolders: [String] = []
    @State private var ignoredFiles: [String] = []
    @State private var draft: Draft?
    @State private var challenge: OneDriveClient.Challenge?
    @State private var operation: Task<Void, Never>?
    @State private var operationLabel: String?
    @State private var error: String?
    @State private var confirmRemoval = false

    private let household = HouseholdStore.shared

    var body: some View {
        Form {
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            if let challenge {
                Section("Approve on another device") {
                    Text("Open \(challenge.verification_uri.absoluteString) on a phone or computer and enter this code.")
                    Text(challenge.user_code).font(.title.monospaced()).accessibilityIdentifier("onedrive-user-code")
                }
            }
            if let operationLabel {
                Section {
                    ProgressView(operationLabel)
                    if challenge != nil { Button("Cancel sign-in") { operation?.cancel() } }
                }
            } else if let folder = draftsFolder.last, draft != nil {
                folderSection(folder)
            } else if let source {
                connectedSections(source)
            } else {
                Section("Microsoft app registration") {
                    TextField("Public client ID", text: $clientID)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        #endif
                        .accessibilityIdentifier("onedrive-client")
                    Text("Use a Microsoft Entra public client registered for personal Microsoft accounts and delegated Files.Read.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Start Microsoft sign-in", action: signIn)
                        .disabled(UUID(uuidString: clientID.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                        .accessibilityIdentifier("onedrive-sign-in")
                }
            }
        }
        .navigationTitle(source == nil ? "Connect OneDrive" : "OneDrive source")
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .onAppear {
            if let source {
                name = source.name
                clientID = source.host
                ignoredFolders = source.ignoredFolders ?? []
                ignoredFiles = source.ignoredFiles ?? []
            } else if clientID.isEmpty {
                clientID = Bundle.main.object(forInfoDictionaryKey: "MediaVaultOneDriveClientID") as? String ?? ""
            }
        }
        .onDisappear { operation?.cancel(); clearDraft() }
        .onReceive(NotificationCenter.default.publisher(for: HouseholdStore.willLock, object: household)) { _ in
            operation?.cancel()
            clearDraft()
            dismiss()
        }
        .confirmationDialog("Disconnect OneDrive and remove its local library?", isPresented: $confirmRemoval) {
            Button("Disconnect and remove", role: .destructive, action: remove)
        }
    }

    @ViewBuilder private func folderSection(_ folder: CloudFileTransport.Item) -> some View {
        Section("Choose a media folder") {
            Text(draftsFolder.count == 1 ? "OneDrive" : draftsFolder.dropFirst().map(\.name).joined(separator: " / "))
                .foregroundStyle(.secondary)
            TextField("Library name", text: $name)
            Button("Use this folder and scan", action: save)
                .disabled(scanner.isScanning || trimmedName.isEmpty)
                .accessibilityIdentifier("onedrive-use-folder")
            if draftsFolder.count > 1 { Button("Up one folder") { browse(Array(draftsFolder.dropLast())) } }
        }
        Section("Folders") {
            if children.isEmpty { Text("No subfolders in this folder.").foregroundStyle(.secondary) }
            ForEach(children, id: \.id) { child in
                Button("Open \(child.name)") { browse(draftsFolder + [child]) }
                    .disabled(draftsFolder.count >= 64)
            }
        }
        Section { Button("Start over", action: clearDraft) }
    }

    @ViewBuilder private func connectedSections(_ source: MediaSource) -> some View {
        Section("Library") {
            TextField("Library name", text: $name)
            Button("Save and rescan", action: saveEdits).disabled(scanner.isScanning || trimmedName.isEmpty)
        }
        if let configuration = try? source.config() {
            SourceExclusionsEditor(folders: $ignoredFolders, files: $ignoredFiles, configuration: configuration)
        }
        Section("Connection") {
            Button("Reconnect Microsoft account", action: signIn).disabled(scanner.isScanning)
            Button("Disconnect OneDrive", role: .destructive) { confirmRemoval = true }.disabled(scanner.isScanning)
        }
    }

    private var trimmedName: String { String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)) }

    private func signIn() {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = source.flatMap { try? OneDriveSourceBinding($0.config()) }
        perform("Connecting to Microsoft…") { token in
            let client = try OneDriveClient(clientID: id)
            challenge = try await client.beginSignIn()
            try requireOwner(token)
            guard let challenge else { throw CancellationError() }
            operationLabel = "Waiting for Microsoft approval…"
            let credentials = try await client.completeSignIn(challenge)
            try requireOwner(token)
            self.challenge = nil
            operationLabel = "Reading folders…"
            let driveID = try await client.identifyDrive(accessToken: credentials.access_token)
            try requireOwner(token)

            let connection = Draft(clientID: id, client: client, driveID: driveID, credentials: credentials)
            if let source {
                guard let stored, stored.driveID == driveID else { throw CloudFileError.accountChanged }
                _ = try await folderChildren(stored.folderID, draft: connection, session: token)
                try requireOwner(token)
                try await OneDriveAccountStore.shared.install(credentials, binding: stored, id: source.id)
                try requireOwner(token)
                await SMBService.shared.reset(sourceID: source.id)
                try requireOwner(token)
                Task { await scanner.scan(source, context: context) }
                finish()
            } else {
                let root = try await client.rootFolder(accessToken: credentials.access_token)
                try requireOwner(token)
                children = try await folderChildren(root.id, draft: connection, session: token)
                try requireOwner(token)
                draft = connection
                draftsFolder = [root]
                if trimmedName.isEmpty { name = "OneDrive" }
            }
        }
    }

    private func browse(_ path: [CloudFileTransport.Item]) {
        guard let draft, let target = path.last else { return }
        let unique = Set(path.map(\.id))
        guard unique.count == path.count else { return }
        perform("Reading folders…") { token in
            let found = try await folderChildren(target.id, draft: draft, session: token)
            try requireOwner(token)
            children = found
            draftsFolder = path
        }
    }

    private func folderChildren(_ id: String, draft: Draft, session: UUID) async throws -> [CloudFileTransport.Item] {
        let store = household
        let results = try await OneDriveFileSource.folders(client: draft.client, driveID: draft.driveID, folderID: id,
                                                           access: draft.credentials.access_token, authorize: {
            try Task.checkCancellation()
            guard store.sessionIsCurrent(session), store.isAdmin else { throw HouseholdError.denied }
        })
        return CloudFileTransport.usableEntries(results).filter { $0.isDirectory && $0.id != id }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func save() {
        guard let draft, let folder = draftsFolder.last, !trimmedName.isEmpty else { return }
        let newName = trimmedName
        perform("Saving OneDrive source…") { token in
            let sourceBinding = try OneDriveSourceBinding(clientID: draft.clientID, driveID: draft.driveID, folderID: folder.id)
            let target = MediaSource(name: newName, host: sourceBinding.clientID, share: sourceBinding.folderID,
                                     rootPath: "", username: sourceBinding.driveID)
            target.id = sourceID
            target.sourceProtocol = CloudFileProvider.oneDrive.rawValue
            try await OneDriveAccountStore.shared.install(draft.credentials, binding: sourceBinding, id: sourceID)
            do {
                try requireOwner(token)
                context.insert(target)
                do { try context.save() }
                catch { context.rollback(); throw error }
            } catch {
                try? await OneDriveAccountStore.shared.remove(id: sourceID)
                throw error
            }
            clearDraft()
            Task { await scanner.scan(target, context: context) }
            finish()
        }
    }

    private func saveEdits() {
        guard let source, !trimmedName.isEmpty else { return }
        perform("Saving OneDrive source…") { token in
            try requireOwner(token)
            do {
                source.name = trimmedName
                try source.applyIgnoredPaths(folders: ignoredFolders, files: ignoredFiles)
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
            await SMBService.shared.reset(sourceID: source.id)
            try requireOwner(token)
            Task { await scanner.scan(source, context: context) }
            finish()
        }
    }

    private func remove() {
        guard let source else { return }
        perform("Disconnecting OneDrive…") { token in
            let id = source.id
            try await OneDriveAccountStore.shared.remove(id: id)
            await SMBService.shared.reset(sourceID: id)
            try requireOwner(token)
            context.delete(source)
            do { try context.save() }
            catch { context.rollback(); throw error }
            dismiss()
        }
    }

    private func perform(_ label: String, action: @escaping @MainActor (UUID) async throws -> Void) {
        guard operation == nil, household.isAdmin, !scanner.isScanning else { return }
        error = nil
        operationLabel = label
        let session = household.sessionToken
        operation = Task { @MainActor in
            defer { challenge = nil; operationLabel = nil; operation = nil }
            do { try requireOwner(session); try await action(session) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    private func requireOwner(_ token: UUID) throws {
        try Task.checkCancellation()
        guard household.sessionIsCurrent(token), household.isAdmin else { throw HouseholdError.denied }
    }

    private func clearDraft() {
        draft = nil
        challenge = nil
        children = []
        draftsFolder = []
    }

    private func finish() {
        if let onSaved { onSaved() } else { dismiss() }
    }
}
