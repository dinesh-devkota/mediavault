import Combine
import CommonCrypto
import CryptoKit
import CineVaultCore
import Foundation
import Security

struct HouseholdFolder: Codable, Equatable, Identifiable {
    var sourceID: UUID
    /// Share-relative path. Empty explicitly allows this source's complete scan root.
    var path: String
    var caseSensitive: Bool?
    var id: String { "\(sourceID.uuidString)/\(caseSensitive == true ? Data(path.utf8).base64EncodedString() : path.lowercased())" }
}

struct HouseholdPIN: Codable, Equatable {
    let salt: Data
    let digest: Data
    static let iterations: UInt32 = 210_000

    static func valid(_ pin: String) -> Bool { pin.utf8.count == 6 && pin.utf8.allSatisfy { (48...57).contains($0) } }
    init(_ pin: String) throws {
        guard Self.valid(pin) else { throw HouseholdError.invalidPIN }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw HouseholdError.storage }
        salt = Data(bytes)
        digest = try Self.derive(pin, salt: salt)
    }
    private static func derive(_ pin: String, salt: Data) throws -> Data {
        var result = [UInt8](repeating: 0, count: 32)
        let status = pin.withCString { password in
            salt.withUnsafeBytes { bytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, pin.utf8.count,
                    bytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &result, 32)
            }
        }
        guard status == kCCSuccess else { throw HouseholdError.storage }
        return Data(result)
    }
    func matches(_ pin: String) -> Bool {
        guard Self.valid(pin), salt.count == 32, digest.count == 32,
              let candidate = try? Self.derive(pin, salt: salt), candidate.count == digest.count else { return false }
        return zip(candidate, digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct HouseholdProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var isAdmin = false
    var pin: HouseholdPIN?
    var allowedFolders: [HouseholdFolder] = []
    var maximumMovieRating: String?
    var maximumTVRating: String?
    var failures = 0
    var retryAfter: Date?
}

enum HouseholdError: LocalizedError {
    case invalidPIN, mismatch, denied, storage, invalidProfile, cooldown(Date)
    var errorDescription: String? {
        switch self {
        case .invalidPIN: return "Use exactly six numbers for the PIN."
        case .mismatch: return "The PINs do not match. Try again."
        case .denied: return "That PIN did not match. Try again."
        case .storage: return "Household controls could not be read or saved securely. The library remains locked. Retry on this device."
        case .invalidProfile: return "Choose a unique profile name and valid permissions."
        case .cooldown(let date): return "Too many attempts. Try again after \(date.formatted(date: .omitted, time: .standard))."
        }
    }
}

/// Pure policy, also used at file access. Paths match complete components, never prefixes.
enum HouseholdPolicy {
    static let movieRatings = ["G", "PG", "PG-13", "R", "NC-17"]
    static let tvRatings = ["TV-Y", "TV-G", "TV-Y7", "TV-PG", "TV-14", "TV-MA"]
    static func allowsPath(profile: HouseholdProfile, sourceID: UUID?, path: String, caseSensitive: Bool = false) -> Bool {
        if profile.isAdmin { return true }
        if caseSensitive {
            return profile.allowedFolders.contains {
                $0.sourceID == sourceID && $0.caseSensitive == true && WebDAVAddress.contains(path, within: $0.path)
            }
        }
        guard let sourceID, let file = ScanExclusions.normalizeFile(path: path)?.lowercased() else { return false }
        return profile.allowedFolders.contains {
            guard $0.sourceID == sourceID else { return false }
            if $0.path.isEmpty { return true }
            guard let folder = ScanExclusions.normalizeFolder(path: $0.path)?.lowercased() else { return false }
            return file.hasPrefix(folder + "/")
        }
    }
    static func allowsRating(_ rating: String?, maximum: String?, values: [String]) -> Bool {
        guard let maximum else { return true }
        guard let limit = values.firstIndex(of: maximum), let rating,
              let value = values.firstIndex(of: rating) else { return false }
        return value <= limit
    }
}

/// Configuration and retry counters share one atomic Keychain record. Active authorization is never persisted.
/// The marker makes lost/unreadable credentials fail closed rather than silently disable protections.
final class HouseholdStore: ObservableObject {
    static let shared: HouseholdStore = {
        #if DEBUG
        if HouseholdPreview.isEnabled { return HouseholdPreview.store }
        #endif
        return HouseholdStore()
    }()
    static let willLock = Notification.Name("MediaVault.householdWillLock")
    private struct Record: Codable { var version = 1; var enabled: Bool? = true; var profiles: [HouseholdProfile] }
    private let mutex = NSRecursiveLock()
    private let defaults: UserDefaults
    private let read: () throws -> String?
    private let write: (String) throws -> Void
    private let erase: () throws -> Void
    private let pinMatches: (HouseholdPIN, String) async -> Bool
    private var record: Record?
    private var authenticationGeneration = UUID()
    private var foreground = true
    @Published private(set) var configured = false
    @Published private(set) var storageFailure = false
    @Published private(set) var activeID: UUID?
    @Published private(set) var generation = UUID()
    @Published private(set) var historyRevision = 0
    private var history: [String: HouseholdProgress] = [:]
    private static let marker = "household.configured.v1"
    private static let historyKey = "household.progress.v1"

    init(defaults: UserDefaults = .standard,
         read: @escaping () throws -> String? = { try Keychain.get("household-controls-v1") },
         write: @escaping (String) throws -> Void = { try Keychain.set($0, for: "household-controls-v1") },
         erase: @escaping () throws -> Void = { try Keychain.delete("household-controls-v1") },
         pinMatches: @escaping (HouseholdPIN, String) async -> Bool = { verifier, pin in
             await Task.detached(priority: .userInitiated) { verifier.matches(pin) }.value
         }) {
        self.defaults = defaults; self.read = read; self.write = write; self.erase = erase
        self.pinMatches = pinMatches
        if let data = defaults.data(forKey: Self.historyKey), let saved = try? JSONDecoder().decode([String: HouseholdProgress].self, from: data) { history = saved }
        reload()
    }
    private func synced<T>(_ action: () throws -> T) rethrows -> T { mutex.lock(); defer { mutex.unlock() }; return try action() }
    var profiles: [HouseholdProfile] { synced { record?.profiles ?? [] } }
    var current: HouseholdProfile? { synced { record?.profiles.first { $0.id == activeID } } }
    var isAdmin: Bool { synced { !configured && !storageFailure || current?.isAdmin == true } }
    var isLocked: Bool { synced { storageFailure || configured && current == nil } }
    var viewerID: UUID? { synced { current.flatMap { $0.isAdmin ? nil : $0.id } } }
    var hasSavedProfiles: Bool { synced { record != nil } }
    var sessionToken: UUID { synced { generation } }
    var authenticationToken: UUID { synced { authenticationGeneration } }
    var preferenceDefaults: UserDefaults { viewerID.flatMap { UserDefaults(suiteName: "mediavault.viewer.\($0.uuidString)") } ?? defaults }

    func reload() {
        synced {
            do {
                if let value = try read() {
                    let decoded = try JSONDecoder().decode(Record.self, from: Data(value.utf8))
                    guard decoded.version == 1, decoded.profiles.filter(\.isAdmin).count == 1,
                          decoded.profiles.first(where: \.isAdmin)?.pin != nil,
                          Set(decoded.profiles.map(\.id)).count == decoded.profiles.count,
                          decoded.profiles.allSatisfy({ profile in
                              !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && profile.name.count <= 30 &&
                              (0...30).contains(profile.failures) &&
                              (profile.pin.map { $0.salt.count == 32 && $0.digest.count == 32 } ?? true) &&
                              (profile.maximumMovieRating.map(HouseholdPolicy.movieRatings.contains) ?? true) &&
                              (profile.maximumTVRating.map(HouseholdPolicy.tvRatings.contains) ?? true) &&
                              profile.allowedFolders.allSatisfy { $0.path.isEmpty || ScanExclusions.normalizeFolder(path: $0.path) != nil }
                          }) else { throw HouseholdError.storage }
                    record = decoded; configured = decoded.enabled != false; defaults.set(configured, forKey: Self.marker); storageFailure = false
                } else {
                    record = nil; configured = defaults.bool(forKey: Self.marker); storageFailure = configured
                }
            } catch { configured = true; storageFailure = true; record = nil }
            activeID = nil; generation = UUID()
        }
    }
    private func persist(_ next: Record) throws {
        mutex.lock(); defer { mutex.unlock() }
        do {
            let data = try JSONEncoder().encode(next)
            guard let value = String(data: data, encoding: .utf8) else { throw HouseholdError.storage }
            try write(value); record = next; defaults.set(next.enabled != false, forKey: Self.marker)
        } catch { lock(); storageFailure = true; throw HouseholdError.storage }
    }
    func setup(pin: String, confirmation: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard foreground, !configured, !storageFailure else { throw HouseholdError.denied }
        guard pin == confirmation else { throw HouseholdError.mismatch }
        if let admin = record?.profiles.first(where: \.isAdmin) {
            try verify(admin.id, pin: pin, now: Date())
            guard var next = record else { throw HouseholdError.storage }
            next.enabled = true; try persist(next); configured = true; lock(); return
        }
        let admin = HouseholdProfile(name: "Admin", isAdmin: true, pin: try HouseholdPIN(pin))
        try persist(Record(profiles: [admin])); configured = true
        // Setup never implicitly unlocks Admin: entering it always requires a PIN.
        lock()
    }
    private func verify(_ id: UUID, pin: String, now: Date) throws {
        guard let profile = profiles.first(where: { $0.id == id }) else { throw HouseholdError.storage }
        if let retry = profile.retryAfter, retry > now { throw HouseholdError.cooldown(retry) }
        try verifyResult(id, matches: profile.pin?.matches(pin) ?? true, now: now)
    }
    private func verifyResult(_ id: UUID, matches: Bool, now: Date) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !storageFailure, var next = record, let index = next.profiles.firstIndex(where: { $0.id == id }) else { throw HouseholdError.storage }
        if let retry = next.profiles[index].retryAfter, retry > now { throw HouseholdError.cooldown(retry) }
        if !matches {
            next.profiles[index].failures = min(30, next.profiles[index].failures + 1)
            if next.profiles[index].failures >= 5 {
                let delay = min(3600.0, 30 * pow(2.0, Double(next.profiles[index].failures - 5)))
                next.profiles[index].retryAfter = now.addingTimeInterval(delay)
            }
            try persist(next)
            if let retry = next.profiles[index].retryAfter, retry > now { throw HouseholdError.cooldown(retry) }
            throw HouseholdError.denied
        }
        next.profiles[index].failures = 0; next.profiles[index].retryAfter = nil
        try persist(next)
    }
    func unlock(_ id: UUID, pin: String, now: Date = Date()) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard foreground else { throw HouseholdError.denied }
        try verify(id, pin: pin, now: now)
        lock(); activeID = id; generation = UUID()
    }
    func authorizeAdmin(pin: String, now: Date = Date()) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard isAdmin, let admin = record?.profiles.first(where: \.isAdmin) else { throw HouseholdError.denied }
        try verify(admin.id, pin: pin, now: now)
    }
    func changeAdminPIN(current: String, pin: String, confirmation: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        try authorizeAdmin(pin: current)
        guard pin == confirmation else { throw HouseholdError.mismatch }
        guard var next = record, let index = next.profiles.firstIndex(where: \.isAdmin) else { throw HouseholdError.storage }
        next.profiles[index].pin = try HouseholdPIN(pin)
        try persist(next); lock()
    }
    func lock() {
        synced {
            authenticationGeneration = UUID()
            guard configured || storageFailure else { return }
            NotificationCenter.default.post(name: Self.willLock, object: self)
            activeID = nil; generation = UUID()
        }
    }
    func setActive(_ active: Bool) {
        synced {
            foreground = active
            if !active { lock() }
        }
    }
    private func saveViewerVerified(_ draft: HouseholdProfile, replacementPIN: HouseholdPIN??) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard isAdmin, configured, var next = record, !draft.isAdmin,
              !next.profiles.contains(where: { $0.id == draft.id && $0.isAdmin }) else { throw HouseholdError.denied }
        var profile = draft
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty, profile.name.count <= 30,
              !next.profiles.contains(where: { $0.id != profile.id && $0.name.caseInsensitiveCompare(profile.name) == .orderedSame }),
              profile.maximumMovieRating.map(HouseholdPolicy.movieRatings.contains) ?? true,
              profile.maximumTVRating.map(HouseholdPolicy.tvRatings.contains) ?? true,
              profile.allowedFolders.allSatisfy({ $0.path.isEmpty || ScanExclusions.normalizeFolder(path: $0.path) != nil }) else { throw HouseholdError.invalidProfile }
        if let replacementPIN { profile.pin = replacementPIN }
        if let index = next.profiles.firstIndex(where: { $0.id == profile.id }) {
            if replacementPIN != nil {
                // A freshly authorized Admin PIN change/removal replaces the old credential and its lockout.
                profile.failures = 0; profile.retryAfter = nil
            } else {
                profile.failures = next.profiles[index].failures; profile.retryAfter = next.profiles[index].retryAfter
            }
            next.profiles[index] = profile
        } else { next.profiles.append(profile) }
        try persist(next)
    }
    private func deleteViewerVerified(_ id: UUID) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard isAdmin, var next = record, next.profiles.contains(where: { $0.id == id && !$0.isAdmin }) else { throw HouseholdError.denied }
        next.profiles.removeAll { $0.id == id }; try persist(next)
        history = history.filter { !$0.key.hasPrefix(id.uuidString + "/") }; saveHistory()
    }
    func disable(adminPIN: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        try authorizeAdmin(pin: adminPIN)
        try disableVerified()
    }
    private func disableVerified() throws {
        mutex.lock(); defer { mutex.unlock() }
        guard isAdmin, var next = record else { throw HouseholdError.storage }
        lock()
        next.enabled = false; try persist(next); configured = false; storageFailure = false
    }
    /// Expensive derivation stays off the UI thread. A lock while it runs invalidates the result.
    @MainActor
    private func checkPIN(_ id: UUID, pin: String, intent: UUID, now: Date = Date()) async throws {
        guard synced({ foreground && intent == authenticationGeneration }) else { throw HouseholdError.denied }
        let token = synced { authenticationGeneration }
        guard let profile = profiles.first(where: { $0.id == id }), !storageFailure else { throw HouseholdError.storage }
        if let retry = profile.retryAfter, retry > now { throw HouseholdError.cooldown(retry) }
        let matched: Bool
        if let verifier = profile.pin { matched = await pinMatches(verifier, pin) }
        else { matched = true }
        try Task.checkCancellation()
        guard synced({ foreground && token == authenticationGeneration }), profiles.first(where: { $0.id == id })?.pin == profile.pin else { throw CancellationError() }
        try verifyResult(id, matches: matched, now: now)
    }
    @MainActor
    func unlockAsync(_ id: UUID, pin: String, intent: UUID) async throws {
        try await checkPIN(id, pin: pin, intent: intent)
        synced { lock(); activeID = id; generation = UUID() }
    }
    @MainActor
    func setupAsync(pin: String, confirmation: String, intent: UUID) async throws {
        guard synced({ foreground && intent == authenticationGeneration }), !configured, !storageFailure else { throw HouseholdError.denied }
        guard pin == confirmation else { throw HouseholdError.mismatch }
        if let admin = profiles.first(where: \.isAdmin) {
            try await checkPIN(admin.id, pin: pin, intent: intent)
            try synced {
                guard var next = record else { throw HouseholdError.storage }
                next.enabled = true; try persist(next); configured = true; lock()
            }
            return
        }
        let token = synced { authenticationGeneration }
        let verifier = try await Task.detached(priority: .userInitiated) { try HouseholdPIN(pin) }.value
        try Task.checkCancellation()
        try synced {
            guard foreground && token == authenticationGeneration, !configured, !storageFailure else { throw CancellationError() }
            let admin = HouseholdProfile(name: "Admin", isAdmin: true, pin: verifier)
            try persist(Record(profiles: [admin])); configured = true; lock()
        }
    }
    @MainActor
    private func checkAdmin(_ pin: String, intent: UUID) async throws {
        guard isAdmin, let admin = profiles.first(where: \.isAdmin) else { throw HouseholdError.denied }
        try await checkPIN(admin.id, pin: pin, intent: intent)
        guard isAdmin else { throw HouseholdError.denied }
    }
    @MainActor
    func saveViewer(_ draft: HouseholdProfile, newPIN: String?, confirmation: String, adminPIN: String, intent: UUID) async throws {
        try await checkAdmin(adminPIN, intent: intent)
        let token = sessionToken
        var replacement: HouseholdPIN?? = nil
        if let newPIN {
            guard newPIN == confirmation else { throw HouseholdError.mismatch }
            if newPIN.isEmpty { replacement = .some(nil) }
            else {
                let verifier = try await Task.detached(priority: .userInitiated) { try HouseholdPIN(newPIN) }.value
                replacement = .some(verifier)
            }
        }
        try Task.checkCancellation()
        guard token == sessionToken else { throw CancellationError() }
        try saveViewerVerified(draft, replacementPIN: replacement)
    }
    @MainActor
    func deleteViewer(_ id: UUID, adminPIN: String, intent: UUID) async throws {
        try await checkAdmin(adminPIN, intent: intent)
        try deleteViewerVerified(id)
    }
    @MainActor
    func disableAsync(adminPIN: String, intent: UUID) async throws {
        try await checkAdmin(adminPIN, intent: intent)
        try disableVerified()
    }
    @MainActor
    func changeAdminPINAsync(current: String, pin: String, confirmation: String, intent: UUID) async throws {
        try await checkAdmin(current, intent: intent)
        guard pin == confirmation else { throw HouseholdError.mismatch }
        let token = sessionToken
        let verifier = try await Task.detached(priority: .userInitiated) { try HouseholdPIN(pin) }.value
        try Task.checkCancellation()
        try synced {
            guard token == generation, var next = record, let index = next.profiles.firstIndex(where: \.isAdmin) else { throw CancellationError() }
            next.profiles[index].pin = verifier
            try persist(next); lock()
        }
    }
    func allowsPath(sourceID: UUID?, path: String, caseSensitive: Bool = false) -> Bool {
        synced {
            guard !storageFailure else { return false }
            guard configured else { return true }
            guard let current else { return false }
            return HouseholdPolicy.allowsPath(profile: current, sourceID: sourceID, path: path, caseSensitive: caseSensitive)
        }
    }
    func allows(_ movie: Movie) -> Bool {
        synced {
            guard allowsPath(sourceID: movie.source?.id, path: movie.filePath, caseSensitive: movie.source.map { $0.isWebDAV || $0.isJellyfin } == true) else { return false }
            guard let current, !current.isAdmin else { return !isLocked }
            guard !movie.isHidden else { return false }
            if MediaFile.isAudio(path: movie.filePath) || MediaFile.isPhoto(path: movie.filePath) { return true }
            return HouseholdPolicy.allowsRating(movie.usContentRating,
                maximum: movie.episodeInfo == nil ? current.maximumMovieRating : current.maximumTVRating,
                values: movie.episodeInfo == nil ? HouseholdPolicy.movieRatings : HouseholdPolicy.tvRatings)
        }
    }
    func sessionIsCurrent(_ token: UUID) -> Bool { synced { token == generation && !isLocked } }
    func playbackID(_ movieID: UUID) -> String { synced { viewerID.map { "profile:\($0.uuidString):\(movieID.uuidString)" } ?? movieID.uuidString } }
    func progress(_ movieID: UUID) -> HouseholdProgress? {
        synced {
            if isLocked { return HouseholdProgress() }
            return viewerID.map { history["\($0.uuidString)/\(movieID.uuidString)"] ?? HouseholdProgress() }
        }
    }
    func updateProgress(_ movieID: UUID, _ update: (inout HouseholdProgress) -> Void) {
        synced {
            guard let viewerID, !isLocked else { return }
            let key = "\(viewerID.uuidString)/\(movieID.uuidString)"
            var value = history[key] ?? HouseholdProgress(); update(&value); history[key] = value
            saveHistory(); historyRevision &+= 1
        }
    }
    private func saveHistory() { if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Self.historyKey) } }
}

struct HouseholdProgress: Codable {
    var watched = false
    var position: Double = 0
    var lastPlayed: Date?
    var watchlisted = false
}

extension Movie {
    /// One durable write per playback checkpoint; Admin's existing SwiftData fields remain unchanged in shape.
    func recordHouseholdProgress(watched: Bool, position: Double, at date: Date,
                                 household: HouseholdStore = .shared, session: UUID) {
        guard household.sessionIsCurrent(session), household.allows(self) else { return }
        if household.viewerID != nil {
            household.updateProgress(id) { $0.watched = watched; $0.position = position; $0.lastPlayed = date }
        } else {
            isWatched = watched; playbackPosition = position; lastPlayedAt = date
        }
        householdRevision &+= 1
    }
    var householdWatched: Bool {
        get { _ = householdRevision; return HouseholdStore.shared.progress(id)?.watched ?? isWatched }
        set {
            guard HouseholdStore.shared.allows(self) else { return }
            if HouseholdStore.shared.viewerID != nil { HouseholdStore.shared.updateProgress(id) { $0.watched = newValue } }
            else { isWatched = newValue }
            householdRevision &+= 1
        }
    }
    var householdPosition: Double {
        get { _ = householdRevision; return HouseholdStore.shared.progress(id)?.position ?? playbackPosition }
        set {
            guard HouseholdStore.shared.allows(self) else { return }
            if HouseholdStore.shared.viewerID != nil { HouseholdStore.shared.updateProgress(id) { $0.position = newValue } }
            else { playbackPosition = newValue }
            householdRevision &+= 1
        }
    }
    var householdLastPlayed: Date? {
        get {
            _ = householdRevision
            if let progress = HouseholdStore.shared.progress(id) { return progress.lastPlayed }
            return lastPlayedAt
        }
        set {
            guard HouseholdStore.shared.allows(self) else { return }
            if HouseholdStore.shared.viewerID != nil { HouseholdStore.shared.updateProgress(id) { $0.lastPlayed = newValue } }
            else { lastPlayedAt = newValue }
            householdRevision &+= 1
        }
    }
    var householdWatchlisted: Bool {
        get { _ = householdRevision; return HouseholdStore.shared.progress(id)?.watchlisted ?? isWatchlisted }
        set {
            guard HouseholdStore.shared.allows(self) else { return }
            if HouseholdStore.shared.viewerID != nil { HouseholdStore.shared.updateProgress(id) { $0.watchlisted = newValue } }
            else { isWatchlisted = newValue }
            householdRevision &+= 1
        }
    }
}
