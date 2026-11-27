#if os(tvOS)
import CoreImage
import Foundation
import SwiftData
import SwiftUI
import UIKit

@MainActor
struct DriveCompanionSourceEditor: View {
    let source: MediaSource?
    let endpoint: URL?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var scanner: LibraryScanner
    @ObservedObject private var household = HouseholdStore.shared

    private struct Pending {
        let verificationURL: URL
        let code: String
        let expiresAt: Date
        let qr: UIImage?
    }

    private struct Draft {
        let endpoint: URL
        let connection: DriveCompanionConnection
    }

    private struct Request {
        let id: UUID
        let session: UUID
    }

    private enum Phase {
        case idle, starting, pairing(Pending), review(Draft), saving, removing
    }

    private enum PairingError: LocalizedError {
        case expired

        var errorDescription: String? { "The pairing code expired. Start pairing again to get a new code." }
    }

    @State private var name = "Google Drive"
    @State private var phase = Phase.idle
    @State private var requestID = UUID()
    @State private var operation: Task<Void, Never>?
    @State private var message: String?
    @State private var confirmRemoval = false

    private var nameToSave: String { String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)) }

    private var availableEndpoint: URL? {
        guard let endpoint, source == nil || source?.host == endpoint.absoluteString else { return nil }
        return endpoint
    }

    var body: some View {
        Form {
            if household.isAdmin {
                if let message {
                    Label(message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange).accessibilityIdentifier("drive-companion-message")
                }
                switch phase {
                case .idle:
                    if source == nil { startSection }
                    else { connectedSections }
                case .starting:
                    Section {
                        ProgressView("Getting a pairing code…")
                        cancellationButton
                    }
                case .pairing(let pending):
                    pairingSection(pending)
                case .review(let draft):
                    reviewSection(draft)
                case .saving:
                    Section { ProgressView("Saving the Google Drive source…") }
                case .removing:
                    Section { ProgressView("Removing the Google Drive source…") }
                }
            } else {
                Text("An unlocked household owner can manage Google Drive sources.")
            }
        }
        .navigationTitle(source == nil ? "Connect Google Drive" : "Google Drive source")
        .onAppear { if let source { name = source.name } }
        .onDisappear { cancelWork() }
        .onTVExit {
            switch phase {
            case .starting, .pairing, .review: cancelWork()
            case .idle, .saving, .removing: dismiss()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HouseholdStore.willLock, object: household)) { _ in
            cancelWork()
            dismiss()
        }
        .confirmationDialog("Remove this Google Drive source?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove source", role: .destructive, action: remove)
        } message: {
            Text("Removes the source and disconnects its Google Drive access.")
        }
    }

    private var startSection: some View {
        Section("Pair with your phone or computer") {
            Text("Open the pairing page on another device and choose the Google Drive files to add to MediaVault.")
                .foregroundStyle(.secondary)
            Button("Start pairing", action: begin).buttonStyle(.borderedProminent)
                .disabled(availableEndpoint == nil || scanner.isScanning)
                .accessibilityIdentifier("drive-companion-start")
        }
    }

    private func pairingSection(_ pending: Pending) -> some View {
        Section("Enter this code on another device") {
            if let qr = pending.qr {
                Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 232, height: 232).padding(12).background(.white)
                    .accessibilityLabel("Open the Google Drive pairing page")
                    .accessibilityIdentifier("drive-companion-qr")
            }
            Text(pending.verificationURL.absoluteString)
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("drive-companion-verification-url")
            Text(pending.code).font(.title.monospaced())
                .accessibilityIdentifier("drive-companion-code")
            HStack {
                ProgressView("Waiting for your selection…")
                Spacer()
                Text(pending.expiresAt, style: .timer).monospacedDigit()
                    .accessibilityLabel("Time until the pairing code expires")
            }
            cancellationButton
        }
    }

    private var cancellationButton: some View {
        Button("Cancel pairing", role: .cancel) { cancelWork() }
            .accessibilityIdentifier("drive-companion-cancel")
    }

    private func reviewSection(_ draft: Draft) -> some View {
        let count = draft.connection.files.count
        return Section(source == nil ? "Review your selection" : "Review your renewed connection") {
            Text("\(count) \(count == 1 ? "file" : "files") selected in Google Drive")
                .accessibilityIdentifier("drive-companion-selected-count")
            if source == nil {
                TextField("Library name", text: $name).accessibilityIdentifier("drive-companion-name")
            }
            Button(source == nil ? "Save and scan" : "Reconnect and scan") { save(draft) }
                .buttonStyle(.borderedProminent)
                .disabled(count == 0 || nameToSave.isEmpty || scanner.isScanning)
                .accessibilityIdentifier("drive-companion-save")
            Button("Start over", action: cancelWork).accessibilityIdentifier("drive-companion-restart")
        }
    }

    @ViewBuilder private var connectedSections: some View {
        Section("Library") {
            TextField("Library name", text: $name).accessibilityIdentifier("drive-companion-name")
            Button("Save name and rescan", action: rename).disabled(nameToSave.isEmpty || scanner.isScanning)
                .accessibilityIdentifier("drive-companion-rename")
        }
        Section("Connection") {
            if availableEndpoint == nil {
                Text("Reconnect requires the companion service used to add this source.").foregroundStyle(.secondary)
            }
            Button("Reconnect Google Drive", action: begin).disabled(availableEndpoint == nil || scanner.isScanning)
                .accessibilityIdentifier("drive-companion-reconnect")
            Button("Remove source", role: .destructive) { confirmRemoval = true }.disabled(scanner.isScanning)
                .accessibilityIdentifier("drive-companion-remove")
        }
    }

    private func begin() {
        guard let endpoint = availableEndpoint else { return }
        perform(.starting) { request in
            let client = try DriveCompanionClient(endpoint: endpoint)
            let pairing = try await client.beginPairing()
            var received: Draft?
            var reviewed = false
            defer {
                if let received { abandon(received) }
                else if !reviewed { Task { try? await client.cancel(pairing) } }
            }
            try requireCurrent(request)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(pairing.expiresIn))
            phase = .pairing(Pending(verificationURL: pairing.verificationUrl, code: pairing.code,
                                     expiresAt: .now.addingTimeInterval(TimeInterval(pairing.expiresIn)),
                                     qr: Self.makeQR(pairing.verificationUrl)))
            while clock.now < deadline {
                if let connection = try await client.poll(pairing) {
                    let draft = Draft(endpoint: endpoint, connection: connection)
                    received = draft
                    try requireCurrent(request)
                    guard clock.now < deadline else { throw PairingError.expired }
                    phase = .review(draft)
                    received = nil
                    reviewed = true
                    return
                }
                try requireCurrent(request)
                try await clock.sleep(until: min(deadline, clock.now.advanced(by: .seconds(2))), tolerance: nil)
                try requireCurrent(request)
            }
            throw PairingError.expired
        }
    }

    private func save(_ draft: Draft) {
        let label = nameToSave
        guard !label.isEmpty, !draft.connection.files.isEmpty else { return }
        perform(.saving) { request in
            let target: MediaSource
            do {
                let authorize = ownerCheck(request.session)
                if let source {
                    try await DriveCompanionSourceStore.reconnect(source: source, endpoint: draft.endpoint,
                        connection: draft.connection, context: context, authorize: authorize)
                    target = source
                } else {
                    target = try await DriveCompanionSourceStore.create(name: label, endpoint: draft.endpoint,
                        connection: draft.connection, context: context, authorize: authorize)
                }
            } catch {
                if (try? requireCurrent(request)) != nil { phase = .review(draft) }
                else { abandon(draft) }
                throw error
            }
            try requireCurrent(request)
            finishAndScan(target)
        }
    }

    private func rename() {
        guard let source, !nameToSave.isEmpty else { return }
        let label = nameToSave
        perform(.saving) { request in
            try requireCurrent(request)
            source.name = label
            do { try context.save() }
            catch { context.rollback(); throw error }
            finishAndScan(source)
        }
    }

    private func remove() {
        guard let source else { return }
        perform(.removing) { request in
            try await DriveCompanionSourceStore.remove(source: source, context: context, authorize: ownerCheck(request.session))
            try requireCurrent(request)
            dismiss()
        }
    }

    private func perform(_ next: Phase, work: @escaping @MainActor (Request) async throws -> Void) {
        guard operation == nil, household.isAdmin, !scanner.isScanning else { return }
        let request = Request(id: UUID(), session: household.sessionToken)
        requestID = request.id
        phase = next
        message = nil
        operation = Task { @MainActor in
            do {
                try requireCurrent(request)
                try await work(request)
            } catch is CancellationError {
            } catch {
                if (try? requireCurrent(request)) != nil { message = error.localizedDescription }
            }
            if requestID == request.id {
                operation = nil
                if case .review = phase { return }
                phase = .idle
            }
        }
    }

    private func ownerCheck(_ session: UUID) -> () throws -> Void {
        let household = household
        return {
            try Task.checkCancellation()
            guard household.isAdmin, household.sessionIsCurrent(session) else { throw HouseholdError.denied }
        }
    }

    private func requireCurrent(_ request: Request) throws {
        guard requestID == request.id else { throw CancellationError() }
        try ownerCheck(request.session)()
    }

    private func cancelWork() {
        if case .review(let draft) = phase { abandon(draft) }
        requestID = UUID()
        operation?.cancel()
        operation = nil
        phase = .idle
        message = nil
    }

    private func abandon(_ draft: Draft) {
        let source = source
        Task { await DriveCompanionSourceStore.abandon(endpoint: draft.endpoint, connection: draft.connection, protecting: source) }
    }

    private func finishAndScan(_ target: MediaSource) {
        Task { await scanner.scan(target, context: context) }
        dismiss()
    }

    private static func makeQR(_ url: URL) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        guard let image = filter.outputImage,
              let rendered = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: rendered)
    }
}
#endif
