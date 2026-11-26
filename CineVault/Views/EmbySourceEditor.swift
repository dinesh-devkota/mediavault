import SwiftData
import SwiftUI

@MainActor
struct EmbySourceEditor: View {
    let source: MediaSource?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var scanner: LibraryScanner
    @ObservedObject private var household = HouseholdStore.shared

    @State private var draftID = UUID()
    @State private var name = ""
    @State private var endpoint = ""
    @State private var username = ""
    @State private var password = ""
    @State private var selection: String?
    @State private var connection: AuthenticatedEmby?
    @State private var status: String?
    @State private var operation: Task<Void, Never>?
    @State private var confirmingRemoval = false
    @State private var removed = false
    @State private var active = false

    private var disabled: Bool { !household.isAdmin || scanner.isScanning || operation != nil || removed }

    var body: some View {
        Form {
            if let status {
                Section { Text(status).foregroundStyle(.secondary) }
            }
            if operation != nil { ProgressView(removed ? "Signing out…" : "Connecting to Emby…") }
            if let source, !removed {
                Section("Linked library") {
                    Text(source.host).font(.caption).foregroundStyle(.secondary)
                    TextField("Library name", text: $name)
                        .accessibilityIdentifier("emby-library-name")
                    Button("Save library name") { rename() }
                }.disabled(disabled)
            }
            if !removed {
                Section(source == nil ? "Emby server" : "Reconnect account") {
                    if source == nil {
                        TextField("HTTPS server address", text: $endpoint)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("emby-server-address")
                    }
                    TextField("Emby username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("emby-username")
                    SecureField("Emby password", text: $password)
                        .accessibilityIdentifier("emby-password")
                    Button(source == nil ? "Sign in and list libraries" : "Reconnect to Emby") { authenticate() }
                        .accessibilityIdentifier("emby-connect")
                        .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection != nil)
                }.disabled(disabled)
                if source == nil, let connection {
                    Section("Emby library") {
                        ForEach(connection.libraries, id: \.Id) { library in
                            Button {
                                selection = library.Id
                            } label: {
                                Label(library.Name, systemImage: selection == library.Id ? "checkmark.circle.fill" : "circle")
                            }
                        }
                        Button("Add library") { saveNew() }
                            .accessibilityIdentifier("emby-add-library")
                            .disabled(selection == nil)
                    }.disabled(disabled)
                }
                if source != nil {
                    Button("Sign out and remove library", role: .destructive) { confirmingRemoval = true }
                        .disabled(disabled)
                }
            }
            Button("Close") { dismiss() }.disabled(removed && operation != nil)
        }
        .navigationTitle(source == nil ? "Add Emby Library" : "Edit Emby Library")
        .onAppear {
            guard household.isAdmin else { dismiss(); return }
            active = true
            if let source { name = source.name; endpoint = source.host }
        }
        .onDisappear {
            // A late authentication response still has to release any issued server token.
            active = false
            releaseDraft()
        }
        .onReceive(NotificationCenter.default.publisher(for: HouseholdStore.willLock, object: household)) { _ in
            active = false
            releaseDraft()
            dismiss()
        }
        .confirmationDialog("Remove this Emby library?", isPresented: $confirmingRemoval) {
            Button("Sign out and remove library", role: .destructive) { remove() }
        } message: {
            Text("This removes the library and its playback history from this Apple TV.")
        }
    }

    private func authenticate() {
        guard !disabled else { return }
        let session = household.sessionToken
        let savedToken: String
        let client: EmbyClient
        do {
            savedToken = try source?.password() ?? ""
            client = try EmbySourceConnection.client(endpoint: source?.host ?? endpoint, sourceID: source?.id ?? draftID)
        } catch {
            status = error.localizedDescription
            return
        }
        let login = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        password = ""
        status = nil
        operation = Task {
            defer { operation = nil }
            var temporaryAccount: EmbyClient.Account?
            do {
                let account = try await client.signIn(username: login, password: secret)
                temporaryAccount = account
                guard active, household.sessionIsCurrent(session), household.isAdmin else { throw CancellationError() }
                let libraries = EmbySourceConnection.libraries(try await client.libraries(account))
                try Task.checkCancellation()
                guard active, household.sessionIsCurrent(session), household.isAdmin, !scanner.isScanning else {
                    throw CancellationError()
                }
                if let source {
                    guard !source.isDeleted, source.modelContext != nil,
                          account.User.Id == source.username,
                          libraries.contains(where: { $0.Id == source.share }) else {
                        throw EmbyEditorError.originalAccountRequired
                    }
                    try source.setPassword(account.AccessToken)
                    temporaryAccount = nil
                    dismiss()
                    Task { await scanner.scan(source, context: context) }
                } else {
                    guard !libraries.isEmpty else { throw EmbyEditorError.noLibraries }
                    connection = AuthenticatedEmby(client: client, account: account, libraries: libraries)
                    temporaryAccount = nil
                }
            } catch is CancellationError {
                // Leaving the form or changing profiles invalidates this operation.
            } catch {
                status = error.localizedDescription
            }
            if let temporaryAccount, temporaryAccount.AccessToken != savedToken {
                Task.detached { try? await client.signOut(temporaryAccount) }
            }
        }
    }

    private func saveNew() {
        guard !disabled, let connection,
              let library = connection.libraries.first(where: { $0.Id == selection }) else { return }
        let source = MediaSource(name: library.Name, host: connection.client.endpoint.absoluteString,
                                 share: library.Id, rootPath: "", username: connection.account.User.Id)
        source.id = draftID
        source.sourceProtocol = "emby"
        do {
            try source.setPassword(connection.account.AccessToken)
            context.insert(source)
            do { try context.save() }
            catch {
                context.delete(source)
                try? Keychain.delete("source-\(draftID.uuidString)")
                throw error
            }
            self.connection = nil
            dismiss()
            Task { await scanner.scan(source, context: context) }
        } catch { status = error.localizedDescription }
    }

    private func rename() {
        guard !disabled, let source, !source.isDeleted else { return }
        let updated = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.isEmpty else { status = "Enter a library name."; return }
        let original = source.name
        source.name = updated
        do { try context.save(); dismiss() }
        catch { source.name = original; status = error.localizedDescription }
    }

    private func remove() {
        guard !disabled, let source, !source.isDeleted else { return }
        do {
            let key = "source-\(source.id.uuidString)"
            let config = try source.config()
            try Keychain.delete(key)
            context.delete(source)
            do { try context.save() }
            catch {
                context.rollback()
                try Keychain.set(config.password, for: key)
                throw error
            }
            removed = true
            if let connection = try? EmbySourceConnection(config: config) {
                operation = Task {
                    defer { operation = nil }
                    do {
                        try await connection.client.signOut(connection.account)
                        dismiss()
                    } catch EmbyError.http(401) { dismiss() }
                    catch { status = "The library was removed from this TV. Revoke its session in the Emby server dashboard." }
                }
            } else { dismiss() }
        } catch { status = error.localizedDescription }
    }

    private func releaseDraft() {
        guard let connection else { return }
        self.connection = nil
        Task.detached { try? await connection.client.signOut(connection.account) }
    }
}

private struct AuthenticatedEmby: Sendable {
    let client: EmbyClient
    let account: EmbyClient.Account
    let libraries: [EmbyClient.Item]
}

private enum EmbyEditorError: LocalizedError {
    case noLibraries, originalAccountRequired

    var errorDescription: String? {
        switch self {
        case .noLibraries: return "This account has no compatible movie, TV or photo libraries."
        case .originalAccountRequired: return "Sign in with the original Emby account and verify it has access to this library."
        }
    }
}
