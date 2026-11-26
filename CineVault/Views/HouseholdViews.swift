import CineVaultCore
import SwiftData
import SwiftUI

struct HouseholdUnavailableView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "lock.shield").font(.system(size: 64))
            Text("This item isn’t available for this profile").font(.title2)
            Text("Ask an Admin to update your allowed folders or ratings.").foregroundStyle(.secondary)
            Button("Back") { dismiss() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(CinemaTheme.background)
    }
}

struct HouseholdPickerView: View {
    @ObservedObject var household: HouseholdStore
    @State private var selected: HouseholdProfile?
    var body: some View {
        NavigationStack {
            VStack(spacing: 34) {
                Image(systemName: "person.2.circle").font(.system(size: 70)).foregroundStyle(CinemaTheme.accent)
                Text("Who’s watching?").font(.largeTitle.bold())
                Text("Your library, your place in every story.").foregroundStyle(.secondary)
                if household.storageFailure {
                    Text(HouseholdError.storage.localizedDescription).multilineTextAlignment(.center).frame(maxWidth: 850)
                    Button("Retry secure storage") { household.reload() }
                } else {
                    #if os(iOS)
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(household.profiles) { profile in
                                Button { select(profile) } label: {
                                    Label(profile.name, systemImage: profile.isAdmin ? "lock.shield" : "person.crop.circle")
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("household-profile-\(profile.name)")
                                .accessibilityHint(profile.pin == nil ? "" : "PIN required")
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                    #else
                    GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        HStack(spacing: 28) {
                            ForEach(household.profiles) { profile in
                                Button { select(profile) } label: {
                                    VStack(spacing: 18) {
                                        Image(systemName: profile.isAdmin ? "lock.shield" : "person.crop.circle")
                                            .font(.system(size: 56))
                                        Text(profile.name).font(.title3.bold()).lineLimit(2).minimumScaleFactor(0.7).multilineTextAlignment(.center)
                                        Text(profile.isAdmin ? "Admin PIN required" : profile.pin == nil ? "Choose profile" : "PIN required")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.frame(width: 260, height: 210)
                                }.accessibilityIdentifier("household-profile-\(profile.name)")
                            }
                        }.padding(40).frame(minWidth: geometry.size.width)
                    }
                    }.frame(height: 320)
                    #endif
                    Text("Profiles and permissions stay on this device. Admin manages access in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                #if os(iOS)
                PhonePrivacyPolicyLink().font(.caption)
                #endif
            }
            #if os(iOS)
            .padding()
            #else
            .padding(50)
            #endif
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CinemaTheme.background).preferredColorScheme(.dark)
                .accessibilityIdentifier("household-picker")
                .sheet(item: $selected) { HouseholdUnlockView(household: household, profile: $0) }
                .onReceive(NotificationCenter.default.publisher(for: HouseholdStore.willLock)) { _ in selected = nil }
        }
    }

    private func select(_ profile: HouseholdProfile) {
        if profile.pin != nil { selected = profile }
        else {
            let intent = household.authenticationToken
            Task { try? await household.unlockAsync(profile.id, pin: "", intent: intent) }
        }
    }
}

private struct HouseholdUnlockView: View {
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @ObservedObject var household: HouseholdStore
    let profile: HouseholdProfile
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Enter the six-digit PIN for \(profile.name).")
                    SecureField("Six-digit PIN", text: $pin).keyboardType(.numberPad).textContentType(.password)
                        .accessibilityIdentifier("household-unlock-pin")
                    Button("Unlock") {
                        let intent = household.authenticationToken, submittedPIN = pin
                        pin = ""; busy = true
                        operation = Task { @MainActor in
                            busy = true; defer { busy = false }
                            do { try await household.unlockAsync(profile.id, pin: submittedPIN, intent: intent); pin = ""; dismiss() }
                            catch is CancellationError { }
                            catch { self.error = error.localizedDescription; pin = "" }
                        }
                    }.disabled(!HouseholdPIN.valid(pin)).accessibilityIdentifier("household-unlock")
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section { Button("Back") { pin = ""; dismiss() } }
            }.disabled(busy).overlay { if busy { ProgressView("Checking PIN…") } }.onDisappear { operation?.cancel() }.navigationTitle(profile.name).onTVExit { pin = ""; dismiss() }
        }
    }
}

struct HouseholdSettingsView: View {
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @ObservedObject private var household = HouseholdStore.shared
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var error: String?
    @State private var disabling = false
    var body: some View {
        Form {
            if !household.configured {
                Section {
                    Text("Give everyone their own library, Watchlist and viewing progress. Choose exactly which folders and US ratings each viewer can see.")
                    Text("Admin keeps your current library and history. New viewers see nothing until you allow folders. Profiles stay on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField(household.hasSavedProfiles ? "Existing Admin PIN" : "Create six-digit Admin PIN", text: $pin).keyboardType(.numberPad)
                        .accessibilityIdentifier("household-setup-pin")
                    SecureField("Confirm Admin PIN", text: $confirmation).keyboardType(.numberPad)
                        .accessibilityIdentifier("household-setup-confirm")
                    Text("Keep this PIN safe. There is no in-app bypass if it is forgotten.").font(.caption).foregroundStyle(.secondary)
                    Button("Enable household profiles") {
                        let intent = household.authenticationToken, submittedPIN = pin, repeatedPIN = confirmation
                        pin = ""; confirmation = ""; busy = true
                        operation = Task { @MainActor in
                            busy = true; defer { busy = false }
                            do { try await household.setupAsync(pin: submittedPIN, confirmation: repeatedPIN, intent: intent); pin = ""; confirmation = "" }
                            catch is CancellationError { }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(!HouseholdPIN.valid(pin) || !HouseholdPIN.valid(confirmation))
                        .accessibilityIdentifier("household-enable")
                } header: { Text("A library for everyone") }
            } else if household.isAdmin {
                Section("Viewers") {
                    ForEach(household.profiles.filter { !$0.isAdmin }) { profile in
                        NavigationLink(profile.name) { HouseholdProfileEditor(profile: profile) }
                            .accessibilityIdentifier("household-edit-\(profile.name)")
                    }
                    NavigationLink("Add viewer") { HouseholdProfileEditor(profile: HouseholdProfile(name: "")) }
                        .accessibilityIdentifier("household-add-viewer")
                }
                Section {
                    Button("Switch profile") { household.lock() }
                    NavigationLink("Change Admin PIN") { HouseholdAdminPINView() }
                    Button("Turn off household profiles", role: .destructive) { disabling = true }
                } footer: {
                    Text("Returning to MediaVault asks who’s watching. Protected titles and photos stay hidden until an allowed profile unlocks them.")
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.disabled(busy).overlay { if busy { ProgressView("Saving securely…") } }.onDisappear { operation?.cancel() }.navigationTitle("Household profiles")
            .sheet(isPresented: $disabling) { HouseholdDisableView() }
    }
}

private struct HouseholdDisableView: View {
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var pin = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Text("Turning off profiles makes the complete library visible and returns to your original Admin viewing history. Viewer profiles and history stay on this device until you remove those profiles.")
                SecureField("Admin PIN", text: $pin).keyboardType(.numberPad)
                Button("Turn off profiles", role: .destructive) {
                    let intent = HouseholdStore.shared.authenticationToken, submittedPIN = pin
                    pin = ""; busy = true
                    operation = Task { @MainActor in
                        busy = true; defer { busy = false }
                        do { try await HouseholdStore.shared.disableAsync(adminPIN: submittedPIN, intent: intent); pin = ""; dismiss() }
                        catch is CancellationError { }
                        catch { self.error = error.localizedDescription; pin = "" }
                    }
                }.disabled(!HouseholdPIN.valid(pin))
                if let error { Text(error).foregroundStyle(.red) }
                Button("Back") { dismiss() }
            }.disabled(busy).overlay { if busy { ProgressView("Checking PIN…") } }.onDisappear { operation?.cancel() }.navigationTitle("Turn off profiles?")
        }
    }
}

private struct HouseholdAdminPINView: View {
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var current = ""
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var error: String?
    var body: some View {
        Form {
            SecureField("Current Admin PIN", text: $current).keyboardType(.numberPad)
            SecureField("New six-digit Admin PIN", text: $pin).keyboardType(.numberPad)
            SecureField("Confirm new PIN", text: $confirmation).keyboardType(.numberPad)
            Button("Save new PIN") {
                let intent = HouseholdStore.shared.authenticationToken, submittedCurrent = current, submittedPIN = pin, repeatedPIN = confirmation
                current = ""; pin = ""; confirmation = ""; busy = true
                operation = Task { @MainActor in
                    busy = true; defer { busy = false }
                    do { try await HouseholdStore.shared.changeAdminPINAsync(current: submittedCurrent, pin: submittedPIN, confirmation: repeatedPIN, intent: intent) }
                    catch is CancellationError { }
                    catch { self.error = error.localizedDescription; current = "" }
                }
            }.disabled(!HouseholdPIN.valid(current) || !HouseholdPIN.valid(pin) || !HouseholdPIN.valid(confirmation))
            if let error { Text(error).foregroundStyle(.red) }
        }.disabled(busy).overlay { if busy { ProgressView("Saving securely…") } }.onDisappear { operation?.cancel() }.navigationTitle("Change Admin PIN")
    }
}

struct HouseholdProfileEditor: View {
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State var profile: HouseholdProfile
    @ObservedObject private var household = HouseholdStore.shared
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MediaSource.name) private var sources: [MediaSource]
    @State private var changePIN = false
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var adminPIN = ""
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Viewer name", text: $profile.name).accessibilityIdentifier("household-viewer-name")
                Toggle(profile.pin == nil ? "Set a viewer PIN" : "Change or remove viewer PIN", isOn: $changePIN)
                if changePIN {
                    SecureField("Six-digit PIN (empty removes it)", text: $pin).keyboardType(.numberPad)
                    SecureField("Confirm viewer PIN", text: $confirmation).keyboardType(.numberPad)
                }
            }
            Section {
                Picker("US movie ratings", selection: Binding(get: { profile.maximumMovieRating ?? "" }, set: { profile.maximumMovieRating = $0.isEmpty ? nil : $0 })) {
                    Text("All ratings, including unrated").tag("")
                    ForEach(HouseholdPolicy.movieRatings, id: \.self) { Text("Up to \($0)").tag($0) }
                }
                Picker("US TV series ratings", selection: Binding(get: { profile.maximumTVRating ?? "" }, set: { profile.maximumTVRating = $0.isEmpty ? nil : $0 })) {
                    Text("All ratings, including unrated").tag("")
                    ForEach(HouseholdPolicy.tvRatings, id: \.self) { Text("Up to \($0)").tag($0) }
                }
                if let maximum = profile.maximumTVRating, let index = HouseholdPolicy.tvRatings.firstIndex(of: maximum) {
                    Text("Includes: \(HouseholdPolicy.tvRatings.prefix(index + 1).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Age ratings") } footer: {
                Text("With a rating limit, unknown or unrated videos stay hidden until TMDB supplies a US rating. TV limits use the show’s rating; individual episodes can differ. Photos and music follow folder access only.")
            }
            Section {
                if sources.isEmpty { Text("Add a NAS source first, then choose folders for this viewer.") }
                ForEach(sources) { source in
                    NavigationLink("Choose folders in \(source.name)") {
                        HouseholdFolderChooser(source: source, allowed: $profile.allowedFolders)
                    }
                }
                if profile.allowedFolders.isEmpty { Text("No folders allowed. This viewer’s library will be empty.").foregroundStyle(.secondary) }
                ForEach(profile.allowedFolders) { folder in
                    let name = sources.first { $0.id == folder.sourceID }?.name ?? "Unavailable source"
                    Button("Remove access: \(name) / \(folder.path.isEmpty ? "Entire source" : folder.path)", role: .destructive) {
                        profile.allowedFolders.removeAll { $0.id == folder.id }
                    }
                }
            } header: { Text("Allowed folders").accessibilityIdentifier("household-folder-permissions") } footer: {
                Text("Allowed folders include their subfolders. New NAS sources are hidden until you allow them. These choices never move or delete files.")
            }
            Section {
                SecureField("Confirm Admin PIN to save changes", text: $adminPIN).keyboardType(.numberPad)
                    .accessibilityIdentifier("household-authorize-pin")
                Button("Save profile") {
                    let intent = household.authenticationToken, submittedAdmin = adminPIN, submittedPIN = changePIN ? pin : nil, repeatedPIN = confirmation
                    let draft = profile
                    adminPIN = ""; pin = ""; confirmation = ""; busy = true
                    operation = Task { @MainActor in
                        busy = true; defer { busy = false }
                        do {
                            try await household.saveViewer(draft, newPIN: submittedPIN, confirmation: repeatedPIN, adminPIN: submittedAdmin, intent: intent)
                            adminPIN = ""; pin = ""; confirmation = ""; dismiss()
                        } catch is CancellationError { }
                        catch { self.error = error.localizedDescription; adminPIN = "" }
                    }
                }.disabled(!HouseholdPIN.valid(adminPIN)).accessibilityIdentifier("household-save-profile")
                if household.profiles.contains(where: { $0.id == profile.id }) {
                    Button("Delete profile", role: .destructive) { confirmDelete = true }.disabled(!HouseholdPIN.valid(adminPIN))
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button("Back") { dismiss() }
            }
        }.disabled(busy).overlay { if busy { ProgressView("Saving securely…") } }.onDisappear { operation?.cancel() }.navigationTitle(profile.name.isEmpty ? "New viewer" : profile.name)
            .confirmationDialog("Delete this viewer and their viewing history?", isPresented: $confirmDelete) {
                Button("Delete profile", role: .destructive) {
                    let intent = household.authenticationToken, submittedAdmin = adminPIN
                    adminPIN = ""; busy = true
                    operation = Task { @MainActor in
                        busy = true; defer { busy = false }
                        do { try await household.deleteViewer(profile.id, adminPIN: submittedAdmin, intent: intent); dismiss() }
                        catch is CancellationError { }
                        catch { self.error = error.localizedDescription; adminPIN = "" }
                    }
                }
            }
    }
}

private struct HouseholdFolderChooser: View {
    let source: MediaSource
    @Binding var allowed: [HouseholdFolder]
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: SourceConfig?
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Text(source.isPlex ? "Allow this Plex library. The viewer’s rating limits still apply."
                     : "Allow all current and future folders in this source, or browse to choose a smaller folder.").font(.caption)
                Button("Allow entire source: \(source.name)") { add(source.rootPath) }
                if let configuration, !source.isJellyfin && !source.isPlex {
                    NavigationLink("Browse folders") {
                        NASPathPicker(configuration: configuration, mode: .household) { path, _ in add(path) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button("Back") { dismiss() }
            }
        }.navigationTitle(source.name)
            .onAppear {
                guard HouseholdStore.shared.isAdmin else { dismiss(); return }
                do { configuration = try source.config() } catch { self.error = error.localizedDescription }
            }
    }
    private func add(_ path: String) {
        guard HouseholdStore.shared.isAdmin else { return }
        let folder = HouseholdFolder(sourceID: source.id, path: path, caseSensitive: (source.caseSensitivePaths || source.isPlex) ? true : nil)
        if !allowed.contains(where: { $0.id == folder.id }) { allowed.append(folder) }
        dismiss()
    }
}

struct HouseholdViewerSettings: View {
    @ObservedObject private var household = HouseholdStore.shared
    var body: some View {
        Form {
            Section {
                Text(household.current?.name ?? "Viewer").font(.title2)
                Text("Your Watchlist and viewing progress are saved for this profile.")
                Button("Switch profile") { household.lock() }
            }
            Section {
                Text("Admin manages NAS sources, subtitles, metadata and household permissions.").foregroundStyle(.secondary)
                Button("Enter Admin") { household.lock() }
                NavigationLink("Media Guide & Help") { MediaGuideView() }
                #if os(iOS)
                PhonePrivacyPolicyLink()
                #endif
            }
        }.navigationTitle("Your profile")
    }
}
