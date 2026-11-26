import SwiftData
import SwiftUI

@MainActor
struct PlexSourceEditor: View {
    let source: MediaSource?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var scanner: LibraryScanner
    @ObservedObject private var household = HouseholdStore.shared
    @State private var draftID = UUID()
    @State private var name = ""
    @State private var code: String?
    @State private var task: Task<Void, Never>?
    @State private var servers: [PlexAccountClient.Server] = []
    @State private var selection: Selection?
    @State private var linkingSession: UUID?
    @State private var message: String?
    @State private var confirmRemoval = false

    private struct Selection {
        let server: PlexAccountClient.Server
        let origin: URL
        let libraries: [PlexMediaClient.Section]
    }

    private var id: UUID { source?.id ?? draftID }

    var body: some View {
        Form {
            if household.isAdmin {
                if let source {
                    Section("Source name") {
                        TextField("Name", text: $name)
                        Button("Save name") { rename(source) }.disabled(task != nil || scanner.isScanning || cleanName.isEmpty)
                    }
                }
                if let message { Text(message).foregroundStyle(.secondary) }
                if let code {
                    Section("Link Apple TV") {
                        Text("On a phone or computer, open plex.tv/link and enter this code.")
                        Text(code).font(.title).accessibilityIdentifier("plex-link-code")
                    }
                }
                if task != nil {
                    ProgressView(code == nil ? "Contacting Plex…" : "Waiting for approval…")
                    Button("Cancel") { task?.cancel() }
                } else if let selection {
                    Section("Choose a library") {
                        ForEach(selection.libraries) { library in
                            Button(library.title) { save(library, selection: selection) }.disabled(scanner.isScanning)
                        }
                        Button("Choose a different server") { self.selection = nil }
                    }
                } else if !servers.isEmpty {
                    Section("Choose a server") {
                        ForEach(servers) { server in Button(server.name) { select(server) } }
                        Button("Start over") { clearLink() }
                    }
                } else {
                    Section(source == nil ? "Plex account" : "Reconnect") {
                        Button(source == nil ? "Link with Plex" : "Reconnect Plex") { link() }
                            .accessibilityIdentifier("plex-link-start")
                    }
                }
                if source != nil {
                    Button("Remove Plex source", role: .destructive) { confirmRemoval = true }
                        .disabled(task != nil || scanner.isScanning)
                }
            }
        }
        .navigationTitle(source == nil ? "Connect Plex" : "Plex Source")
        .onAppear { name = source?.name ?? "" }
        .onDisappear { task?.cancel(); clearLink() }
        .onReceive(NotificationCenter.default.publisher(for: HouseholdStore.willLock)) { _ in
            task?.cancel()
            clearLink()
            dismiss()
        }
        .confirmationDialog("Remove this Plex source and its local library?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove Plex source", role: .destructive) { remove() }
        }
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func check(_ session: UUID) throws {
        try Task.checkCancellation()
        guard household.isAdmin, household.sessionIsCurrent(session) else { throw HouseholdError.denied }
    }

    private func clearLink() {
        servers = []
        selection = nil
        code = nil
        linkingSession = nil
    }

    private func link() {
        guard household.isAdmin, task == nil else { return }
        let session = household.sessionToken
        linkingSession = session
        message = nil
        task = Task {
            defer { code = nil; task = nil }
            do {
                let client = try PlexAccountClient(deviceID: id.uuidString)
                let pin = try await client.beginLink()
                try check(session)
                code = pin.code
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(Int64(min(pin.expiresIn, 600))))
                while clock.now < deadline {
                    try await clock.sleep(for: .seconds(2))
                    try check(session)
                    guard clock.now < deadline else { break }
                    guard let token = try await client.pollLink(pin) else { continue }
                    try check(session)
                    let found = try await client.listServers(accountToken: token)
                    try check(session)
                    var unique: Set<String> = []
                    servers = found.filter {
                        PlexSourceConnection.validServerID($0.id) && (source == nil || source?.username == $0.id)
                            && unique.insert($0.id).inserted
                    }
                    guard !servers.isEmpty else { throw PlexSourceError.selectionUnavailable }
                    return
                }
                throw PlexSourceError.linkExpired
            } catch is CancellationError {
                clearLink()
            } catch {
                clearLink()
                if household.sessionIsCurrent(session) { message = error.localizedDescription }
            }
        }
    }

    private func select(_ server: PlexAccountClient.Server) {
        guard let session = linkingSession, task == nil else { return }
        message = nil
        task = Task {
            defer { task = nil }
            do {
                try check(session)
                let (client, libraries) = try await PlexSourceConnection.connect(server, deviceID: id)
                try check(session)
                let available = libraries.filter { source == nil || source?.share == $0.id }
                guard !available.isEmpty else { throw PlexSourceError.selectionUnavailable }
                selection = Selection(server: server, origin: client.origin, libraries: available)
            } catch is CancellationError {
            } catch {
                if household.sessionIsCurrent(session) { message = error.localizedDescription }
            }
        }
    }

    private func save(_ library: PlexMediaClient.Section, selection: Selection) {
        guard let session = linkingSession, !scanner.isScanning else { return }
        do {
            try check(session)
            guard let token = selection.server.accessToken,
                  source == nil || (source?.username == selection.server.id && source?.share == library.id) else {
                throw PlexSourceError.selectionUnavailable
            }
            let target = source ?? MediaSource(name: library.title, host: selection.origin.absoluteString,
                                              share: library.id, rootPath: "", username: selection.server.id)
            guard !target.isDeleted else { throw PlexSourceError.selectionUnavailable }
            let previousHost = target.host
            if source == nil {
                target.id = draftID
                target.sourceProtocol = "plex"
            }
            let previousToken = try target.password()
            try target.setPassword(token)
            target.host = selection.origin.absoluteString
            if source == nil { context.insert(target) }
            do { try context.save() } catch {
                target.host = previousHost
                if source == nil { context.delete(target) }
                if previousToken.isEmpty { try Keychain.delete("source-\(target.id.uuidString)") }
                else { try target.setPassword(previousToken) }
                throw error
            }
            clearLink()
            Task { await scanner.scan(target, context: context) }
            dismiss()
        } catch { message = error.localizedDescription }
    }

    private func rename(_ source: MediaSource) {
        guard household.isAdmin, !scanner.isScanning, !cleanName.isEmpty, !source.isDeleted else { return }
        let old = source.name
        source.name = cleanName
        do { try context.save(); dismiss() }
        catch { source.name = old; message = error.localizedDescription }
    }

    private func remove() {
        guard let source, household.isAdmin, task == nil, !scanner.isScanning, !source.isDeleted else { return }
        let id = source.id
        do {
            let token = try source.password()
            try Keychain.delete("source-\(id.uuidString)")
            context.delete(source)
            do { try context.save() }
            catch {
                context.rollback()
                if !token.isEmpty { try Keychain.set(token, for: "source-\(id.uuidString)") }
                throw error
            }
            clearLink()
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
