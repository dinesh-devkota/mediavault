import CoreImage.CIFilterBuiltins
import SwiftUI

enum SubtitleSettings {
    static let account = "subdl-api-key"
    static let enabledKey = "subtitles.onlineAutomatic"
    static let languageKey = "subtitles.preferredLanguage"
    static let verifiedKey = "subtitles.subdlVerified"
    static let setupURL = URL(string: "https://subdl.com/panel/api")!
    static let languages = Array(Set(Locale.isoLanguageCodes + ["pt-br", "zh-cn", "zh-tw"]))

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code.uppercased()
    }
}

struct SubtitleSettingsView: View {
    @AppStorage(SubtitleSettings.enabledKey) private var automatic = false
    @AppStorage(SubtitleSettings.languageKey) private var language = "en"
    @AppStorage(SubtitleSettings.verifiedKey) private var verified = false
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var connecting = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Button("Back") { dismiss() }
            Section {
                NavigationLink {
                    SubtitleLanguagePicker(selection: $language)
                } label: { LabeledContent("Preferred language", value: SubtitleSettings.languageName(language)) }
                Toggle("Find subtitles automatically", isOn: $automatic)
                    .disabled(!hasKey || !verified)
                    .accessibilityIdentifier("automatic-subtitles-toggle")
            } header: { Text("Playback preferences") } footer: {
                Text("Matching local or embedded subtitles are preferred. Online subtitles are selected automatically only when the release filename matches. You can choose another release, adjust timing, or select Off in the player.")
            }
            Section {
                Label(hasKey && verified ? "Connected · key saved securely" : "Not connected", systemImage: hasKey && verified ? "checkmark.circle.fill" : "link")
                    .accessibilityIdentifier("subdl-connection-status")
                HStack(alignment: .top, spacing: 36) {
                    if let qr = Self.setupQR {
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: 200, height: 200)
                            .padding(12).background(.white).accessibilityLabel("QR code for SubDL API key setup")
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connect SubDL once").font(.headline)
                        Text("On your phone or computer, sign in to SubDL and copy your API key from:")
                        Text("subdl.com/panel/api").font(.title3)
                        Text("Enter the API key below. You can use your iPhone’s Apple TV keyboard. Your password is never needed here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SecureField(hasKey ? "New API key (optional replacement)" : "SubDL API key", text: $apiKey)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("subdl-api-key")
                Button(connecting ? "Checking connection…" : "Connect & enable automatic subtitles") { connect() }
                    .disabled(connecting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasKey)
                    .accessibilityIdentifier("subdl-connect")
                if hasKey { Button("Disconnect SubDL", role: .destructive) { disconnect() }.disabled(connecting) }
                if connecting { ProgressView() }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Online subtitles · SubDL") } footer: {
                Text("Connecting enables searches that send this video’s TMDB identifier, episode and language to SubDL. Downloads stay in app memory and never change your NAS files. SubDL account limits apply. Local SRT and WebVTT files work without an account.")
            }
        }
        .navigationTitle("Subtitles")
        .onAppear {
            do { hasKey = !(try Keychain.get(SubtitleSettings.account) ?? "").isEmpty }
            catch { message = "The saved key could not be read. Try again."; hasKey = false }
        }
        .onDisappear { generation = UUID(); task?.cancel(); task = nil; connecting = false }
    }

    private func connect() {
        generation = UUID(); let token = generation
        connecting = true; message = nil
        let typed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        task = Task { @MainActor in
            defer { if generation == token { connecting = false; task = nil } }
            do {
                let key = typed.isEmpty ? try Keychain.get(SubtitleSettings.account) ?? "" : typed
                try await SubDLClient().validateKey(key)
                try Task.checkCancellation()
                guard generation == token else { return }
                try Keychain.set(key, for: SubtitleSettings.account)
                hasKey = true; verified = true; automatic = true; apiKey = ""
                message = "Connected. Subtitles will use \(SubtitleSettings.languageName(language)) when available."
            } catch is CancellationError { }
            catch { if generation == token { message = error.localizedDescription } }
        }
    }

    private func disconnect() {
        do {
            try Keychain.delete(SubtitleSettings.account)
            automatic = false; verified = false; hasKey = false; apiKey = ""; message = "SubDL disconnected. Local subtitles remain available."
        } catch { message = error.localizedDescription }
    }

    private static var setupQR: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(SubtitleSettings.setupURL.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct SubtitleLanguagePicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            ForEach(SubtitleSettings.languages.sorted { SubtitleSettings.languageName($0).localizedStandardCompare(SubtitleSettings.languageName($1)) == .orderedAscending }, id: \.self) { code in
                Button { selection = code; dismiss() } label: {
                    HStack { Text(SubtitleSettings.languageName(code)); Spacer(); if selection == code { Image(systemName: "checkmark") } }
                }.accessibilityValue(selection == code ? "Selected" : "Not selected")
            }
            Text("Subtitle availability varies by title and language.").font(.caption).foregroundStyle(.secondary)
        }.navigationTitle("Subtitle language")
    }
}
