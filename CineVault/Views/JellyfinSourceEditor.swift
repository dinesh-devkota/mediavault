import SwiftData
import SwiftUI

@MainActor
struct JellyfinSourceEditor: View {
    let source: MediaSource?
    var onSaved: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var scanner: LibraryScanner
    @State private var draftID = UUID()
    @State private var endpoint = ""
    @State private var username = ""
    @State private var password = ""
    @State private var quickCode: String?
    @State private var account: JellyfinAccount?
    @State private var libraries: [JellyfinCatalogItem] = []
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    @State private var signingOut = false
    @State private var removedConfig: SourceConfig?
    @State private var removeConfirmation = false

    private var household: HouseholdStore { .shared }
    private var sourceID: UUID { source?.id ?? draftID }

    var body: some View {
        Form {
            if source == nil {
                Section("Server") {
                    TextField("HTTPS address", text: $endpoint)
                        .textContentType(.URL)
                        .disabled(task != nil || account != nil)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if let removedConfig, task == nil {
                Button("Retry clearing credentials") { clearCredentials(removedConfig) }
            }
            if let quickCode {
                Section("Quick Connect") {
                    Text("Open Quick Connect on a device already signed in to this server. Enter the code shown below.")
                    Text(quickCode).font(.title)
                }
            }
            if task != nil {
                if signingOut { ProgressView("Removing source…") }
                else { ProgressView(quickCode == nil ? "Connecting…" : "Waiting for approval…") }
                if !signingOut { Button("Cancel") { task?.cancel() } }
            } else if let account {
                Section("Choose a library") {
                    if libraries.isEmpty {
                        Text("This account has no available libraries.")
                    }
                    ForEach(libraries) { library in
                        Button(library.name) { save(library: library, account: account) }
                    }
                    Button("Use a different account") {
                        let host = endpoint, id = sourceID
                        self.account = nil
                        libraries = []
                        Task {
                            if let client = try? JellyfinSourceConnection.client(endpoint: host, sourceID: id) {
                                try? await client.signOut(account)
                            }
                        }
                    }
                }
            } else if removedConfig == nil {
                Section(source == nil ? "Sign in" : "Reconnect") {
                    TextField("Username", text: $username).textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                    Button("Sign in") { authenticate(quick: false) }.disabled(username.isEmpty)
                    Button("Use Quick Connect") { authenticate(quick: true) }
                }
            }
            if source != nil && removedConfig == nil {
                Section {
                    Button("Remove source", role: .destructive) { removeConfirmation = true }
                        .disabled(task != nil || scanner.isScanning)
                }
            }
        }
        .navigationTitle(source == nil ? "Connect Jellyfin" : "Jellyfin Source")
        .confirmationDialog("Remove this Jellyfin source and its local library?", isPresented: $removeConfirmation, titleVisibility: .visible) {
            Button("Remove source", role: .destructive) { remove() }
        }
        .onAppear { if let source { endpoint = source.host } }
        .onDisappear {
            if !signingOut { task?.cancel() }
            password = ""
            if let account {
                let host = endpoint, id = sourceID
                Task {
                    if let client = try? JellyfinSourceConnection.client(endpoint: host, sourceID: id) {
                        try? await client.signOut(account)
                    }
                }
            }
        }
    }

    private func authenticate(quick: Bool) {
        guard task == nil, household.isAdmin else { return }
        let session = household.sessionToken
        error = nil
        task = Task { @MainActor in
            defer { quickCode = nil; password = ""; task = nil }
            var newAccount: JellyfinAccount?
            let client: JellyfinClient
            do { client = try JellyfinSourceConnection.client(endpoint: endpoint, sourceID: sourceID) }
            catch { self.error = error.localizedDescription; return }
            do {
                let received: JellyfinAccount
                if quick {
                    let challenge = try await client.beginQuickConnect()
                    quickCode = challenge.code
                    received = try await waitForQuickConnect(client, secret: challenge.secret, session: session)
                } else {
                    received = try await client.signIn(username: username, password: password)
                }
                newAccount = received
                try Task.checkCancellation()
                guard household.sessionIsCurrent(session), household.isAdmin else { throw HouseholdError.denied }
                if let source, source.username != received.user.id {
                    throw JellyfinEditorError.accountChanged
                }
                let found = try await client.libraries(received).filter {
                    JellyfinSourceConnection.validItemID($0.id) && !$0.name.isEmpty
                }
                try Task.checkCancellation()
                guard household.sessionIsCurrent(session), household.isAdmin else { throw HouseholdError.denied }
                libraries = found.filter { source == nil || $0.id == source?.share }
                account = received
                newAccount = nil
            } catch is CancellationError {
                if let newAccount { try? await client.signOut(newAccount) }
            } catch {
                if let newAccount { try? await client.signOut(newAccount) }
                self.error = error.localizedDescription
            }
        }
    }

    private func waitForQuickConnect(_ client: JellyfinClient, secret: String, session: UUID) async throws -> JellyfinAccount {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(180))
        while clock.now < deadline {
            try await clock.sleep(for: .seconds(3))
            guard household.sessionIsCurrent(session), household.isAdmin else { throw HouseholdError.denied }
            if try await client.pollQuickConnect(secret: secret).authenticated {
                return try await client.finishQuickConnect(secret: secret)
            }
        }
        throw JellyfinEditorError.quickConnectExpired
    }

    private func save(library: JellyfinCatalogItem, account: JellyfinAccount) {
        guard household.isAdmin, !scanner.isScanning else { return }
        do {
            let address = try WebDAVAddress(endpoint)
            let target = source ?? MediaSource(name: library.name, host: address.endpoint.absoluteString,
                                               share: library.id, rootPath: "", username: account.user.id)
            if source == nil {
                target.id = draftID
                target.sourceProtocol = "jellyfin"
            }
            try target.setPassword(account.token)
            if source == nil {
                context.insert(target)
                do { try context.save() }
                catch {
                    context.delete(target)
                    try? target.setPassword("")
                    throw error
                }
            }
            self.account = nil
            Task { await scanner.scan(target, context: context) }
            if let onSaved { onSaved() } else { dismiss() }
        } catch { self.error = error.localizedDescription }
    }

    private func remove() {
        guard let source, household.isAdmin, task == nil, !scanner.isScanning else { return }
        let config: SourceConfig
        do { config = try source.config() }
        catch { self.error = error.localizedDescription; return }
        let id = source.id
        if let uncommitted = account {
            account = nil
            let host = endpoint
            Task {
                if let client = try? JellyfinSourceConnection.client(endpoint: host, sourceID: id) {
                    try? await client.signOut(uncommitted)
                }
            }
        }
        context.delete(source)
        do { try context.save() }
        catch {
            context.rollback()
            self.error = error.localizedDescription
            return
        }
        removedConfig = config
        clearCredentials(config)
    }

    private func clearCredentials(_ config: SourceConfig) {
        do { try Keychain.delete("source-\(config.id.uuidString)") }
        catch { self.error = error.localizedDescription; return }
        signingOut = true
        error = nil
        task = Task {
            if let connection = try? JellyfinSourceConnection(config: config) {
                try? await connection.client.signOut(connection.account)
            }
            dismiss()
        }
    }
}

private enum JellyfinEditorError: LocalizedError {
    case accountChanged, quickConnectExpired

    var errorDescription: String? {
        switch self {
        case .accountChanged: return "Sign in with the account already linked to this library."
        case .quickConnectExpired: return "This Quick Connect code expired. Request a new one."
        }
    }
}
