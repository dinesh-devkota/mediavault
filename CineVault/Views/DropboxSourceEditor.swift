import CoreImage
import SwiftData
import SwiftUI
import UIKit

@MainActor
struct DropboxSourceEditor: View {
    let source: MediaSource?
    var onSaved: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var scanner: LibraryScanner

    private struct Draft {
        let appKey: String
        let client: DropboxClient
        let credentials: DropboxClient.Credentials
    }

    @State private var draftID = UUID()
    @State private var appKey = ""
    @State private var name = ""
    @State private var code = ""
    @State private var approval: DropboxClient.Authorization?
    @State private var qrCode: UIImage?
    @State private var draft: Draft?
    @State private var folders: [CloudFileTransport.Item] = []
    @State private var children: [CloudFileTransport.Item] = []
    @State private var ignoredFolders: [String] = []
    @State private var ignoredFiles: [String] = []
    @State private var operation: Task<Void, Never>?
    @State private var operationLabel: String?
    @State private var error: String?
    @State private var confirmRemoval = false
    @State private var removedSourceID: UUID?
    @State private var removedCredentials = false

    private let household = HouseholdStore.shared
    private var sourceID: UUID { source?.id ?? draftID }
    private var trimmedName: String { String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)) }

    var body: some View {
        Form {
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            if let operationLabel {
                Section {
                    ProgressView(operationLabel)
                    if removedSourceID == nil { Button("Cancel", role: .cancel) { operation?.cancel() } }
                }
            } else if let removedSourceID {
                Section {
                    if !removedCredentials { Button("Retry clearing credentials") { clearCredentials(removedSourceID) } }
                    Button("Done") { dismiss() }
                }
            } else if let draft {
                folderSections(draft)
            } else if let approval {
                approvalSection(approval)
            } else if let source {
                connectedSections(source)
            } else {
                Section("Dropbox app registration") {
                    TextField("Public Dropbox app key", text: $appKey).accessibilityIdentifier("dropbox-app-key")
                    Text("Use the app key from a Dropbox API app with metadata and content read permissions.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Get Dropbox approval", action: begin)
                        .disabled(appKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("dropbox-begin")
                }
            }
        }
        .navigationTitle(source == nil ? "Connect Dropbox" : "Dropbox Source")
        .onAppear {
            if let source {
                name = source.name
                appKey = source.host
                ignoredFolders = source.ignoredFolders ?? []
                ignoredFiles = source.ignoredFiles ?? []
            } else if appKey.isEmpty {
                appKey = Bundle.main.object(forInfoDictionaryKey: "MediaVaultDropboxAppKey") as? String ?? ""
            }
        }
        .onDisappear {
            if removedSourceID == nil { operation?.cancel() }
            abandonDraft()
        }
        .onReceive(NotificationCenter.default.publisher(for: HouseholdStore.willLock, object: household)) { _ in
            if removedSourceID == nil { operation?.cancel() }
            abandonDraft()
            dismiss()
        }
        .confirmationDialog("Disconnect Dropbox and remove its local library?", isPresented: $confirmRemoval) {
            Button("Sign out and remove", role: .destructive, action: remove)
        }
    }

    @ViewBuilder private func approvalSection(_ approval: DropboxClient.Authorization) -> some View {
        Section("Approve Dropbox on another device") {
            Text("Scan the QR code with your phone. In Dropbox, sign in and copy the one-time code.")
            if let qrCode {
                Image(uiImage: qrCode).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 250, height: 250).padding(12).background(.white)
                    .accessibilityLabel("Open Dropbox approval on a phone")
                    .accessibilityIdentifier("dropbox-approval-qr")
            }
            SecureField("Dropbox one-time code", text: $code).accessibilityIdentifier("dropbox-approval-code")
            Button(source == nil ? "Verify code and choose a folder" : "Verify code and reconnect") {
                finishApproval(approval)
            }.disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Start a new approval") { clearApproval() }
        }
    }

    @ViewBuilder private func folderSections(_ draft: Draft) -> some View {
        Section("Choose a media folder") {
            Text(folders.isEmpty ? "Dropbox" : folders.map(\.name).joined(separator: " / "))
                .foregroundStyle(.secondary)
            TextField("Source name (optional)", text: $name)
            if let folder = folders.last {
                Button("Use this folder and scan") { save(draft, folder: folder) }.disabled(scanner.isScanning)
                Button("Up one folder") { browse(draft, stack: Array(folders.dropLast())) }
            }
        }
        Section("Folders") {
            if children.isEmpty { Text("No subfolders in this folder.").foregroundStyle(.secondary) }
            ForEach(children, id: \.id) { child in
                Button("Open \(child.name)") { browse(draft, stack: folders + [child]) }
                    .disabled(folders.count >= 64)
            }
        }
        Section { Button("Use another account", action: abandonDraft) }
    }

    @ViewBuilder private func connectedSections(_ source: MediaSource) -> some View {
        Section("Library") {
            TextField("Source name", text: $name)
            Button("Save and rescan", action: saveEdits).disabled(scanner.isScanning || trimmedName.isEmpty)
        }
        if let configuration = try? source.config() {
            SourceExclusionsEditor(folders: $ignoredFolders, files: $ignoredFiles, configuration: configuration)
        }
        Section("Connection") {
            Button("Reconnect Dropbox", action: begin).disabled(scanner.isScanning)
            Button("Sign out and remove", role: .destructive) { confirmRemoval = true }.disabled(scanner.isScanning)
        }
    }

    private func begin() {
        guard household.isAdmin, operation == nil else { return }
        do {
            let cleanKey = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let authorization = try DropboxClient(appKey: cleanKey).beginAuthorization()
            guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw DropboxClientError.invalidConfiguration }
            filter.setValue(Data(authorization.url.absoluteString.utf8), forKey: "inputMessage")
            guard let image = filter.outputImage,
                  let rendered = CIContext().createCGImage(image, from: image.extent) else {
                throw DropboxClientError.invalidConfiguration
            }
            appKey = cleanKey
            error = nil
            qrCode = UIImage(cgImage: rendered)
            approval = authorization
        } catch { self.error = error.localizedDescription }
    }

    private func finishApproval(_ approval: DropboxClient.Authorization) {
        let entered = code
        code = ""
        perform("Verifying Dropbox approval…") { session in
            let client = try DropboxClient(appKey: appKey)
            let credentials = try await client.completeManualAuthorization(approval, code: entered)
            clearApproval()
            let received = Draft(appKey: appKey, client: client, credentials: credentials)
            do {
                try ownerCheck(session)()
                guard let account = credentials.account_id, DropboxClient.isAccountID(account),
                      let refresh = credentials.refresh_token, DropboxClient.isToken(refresh),
                      DropboxClient.isToken(credentials.access_token), credentials.expires_in > 0 else {
                    throw CloudFileError.needsSignIn
                }
                if let source {
                    let binding = try DropboxSourceBinding(source.config())
                    guard binding.accountID == account, binding.appKey == received.appKey else { throw CloudFileError.accountChanged }
                    _ = try await folderItems(received, id: binding.folderID, session: session)
                    let previous = try await DropboxAccountStore.shared.install(
                        credentials, binding: binding, id: source.id, authorize: ownerCheck(session))
                    if let previous { Task { _ = await previous.revoke() } }
                    await SMBService.shared.reset(sourceID: source.id)
                    try ownerCheck(session)()
                    Task { await scanner.scan(source, context: context) }
                    finish()
                } else {
                    children = try await folderItems(received, id: nil, session: session)
                    draft = received
                }
            } catch {
                release(received)
                throw error
            }
        }
    }

    private func folderItems(_ draft: Draft, id: String?, session: UUID) async throws -> [CloudFileTransport.Item] {
        let entries = try await DropboxFileSource.items(client: draft.client, folderID: id,
                                                        access: draft.credentials.access_token,
                                                        authorize: ownerCheck(session))
        return entries.filter(\.isDirectory).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func browse(_ draft: Draft, stack: [CloudFileTransport.Item]) {
        perform("Reading Dropbox folders…") { session in
            let found = try await folderItems(draft, id: stack.last?.id, session: session)
            try ownerCheck(session)()
            folders = stack
            children = found
        }
    }

    private func save(_ draft: Draft, folder: CloudFileTransport.Item) {
        let label = trimmedName.isEmpty ? folder.name : trimmedName
        perform("Saving the Dropbox source…") { session in
            guard let account = draft.credentials.account_id else { throw CloudFileError.needsSignIn }
            let binding = try DropboxSourceBinding(appKey: draft.appKey, accountID: account, folderID: folder.id)
            _ = try await folderItems(draft, id: folder.id, session: session)
            let target = MediaSource(name: label, host: binding.appKey, share: binding.folderID,
                                     rootPath: "", username: binding.accountID)
            target.id = draftID
            target.sourceProtocol = CloudFileProvider.dropbox.rawValue
            _ = try await DropboxAccountStore.shared.install(
                draft.credentials, binding: binding, id: target.id, authorize: ownerCheck(session))
            do {
                try ownerCheck(session)()
                context.insert(target)
                try context.save()
            } catch {
                context.rollback()
                _ = try? await DropboxAccountStore.shared.remove(id: target.id)
                throw error
            }
            self.draft = nil
            Task { await scanner.scan(target, context: context) }
            finish()
        }
    }

    private func saveEdits() {
        guard let source, !trimmedName.isEmpty else { return }
        perform("Saving the Dropbox source…") { session in
            try ownerCheck(session)()
            do {
                source.name = trimmedName
                try source.applyIgnoredPaths(folders: ignoredFolders, files: ignoredFiles)
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
            await SMBService.shared.reset(sourceID: source.id)
            try ownerCheck(session)()
            Task { await scanner.scan(source, context: context) }
            finish()
        }
    }

    private func remove() {
        guard let source else { return }
        perform("Removing the Dropbox source…") { session in
            try ownerCheck(session)()
            let id = source.id
            context.delete(source)
            do { try context.save() }
            catch { context.rollback(); throw error }
            removedSourceID = id
            try await disconnect(id)
        }
    }

    private func clearCredentials(_ id: UUID) {
        perform("Clearing Dropbox credentials…") { _ in try await disconnect(id) }
    }

    private func disconnect(_ id: UUID) async throws {
        await SMBService.shared.reset(sourceID: id)
        let grant = try await DropboxAccountStore.shared.remove(id: id)
        removedCredentials = true
        let revoked = await grant?.revoke() ?? true
        if revoked { dismiss(); return }
        error = "The local source was removed. To revoke the Dropbox grant, use Connected apps in your Dropbox account."
    }

    private func perform(_ label: String, action: @escaping @MainActor (UUID) async throws -> Void) {
        guard operation == nil, household.isAdmin, !scanner.isScanning else { return }
        error = nil
        operationLabel = label
        let session = household.sessionToken
        operation = Task { @MainActor in
            defer { operationLabel = nil; operation = nil }
            do { try ownerCheck(session)(); try await action(session) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    private func ownerCheck(_ session: UUID) -> CloudFileTransport.Permission {
        let household = household
        return {
            try Task.checkCancellation()
            guard household.sessionIsCurrent(session), household.isAdmin else { throw HouseholdError.denied }
        }
    }

    private func release(_ draft: Draft) {
        let id = sourceID
        Task {
            if let refresh = draft.credentials.refresh_token,
               await DropboxAccountStore.shared.isSaved(refresh, id: id) { return }
            try? await draft.client.revoke(accessToken: draft.credentials.access_token)
        }
    }

    private func clearApproval() {
        code = ""
        qrCode = nil
        approval = nil
    }

    private func abandonDraft() {
        if let draft { release(draft) }
        draft = nil
        folders = []
        children = []
        clearApproval()
    }

    private func finish() {
        if let onSaved { onSaved() } else { dismiss() }
    }
}
