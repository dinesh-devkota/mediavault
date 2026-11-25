import Foundation
import XCTest
@testable import CineVault

@MainActor
final class HouseholdProfilesTests: XCTestCase {
    private final class MemoryCredentials {
        var value: String?
        var fails = false
        func read() throws -> String? { if fails { throw HouseholdError.storage }; return value }
        func write(_ value: String) throws { if fails { throw HouseholdError.storage }; self.value = value }
    }
    private let adminPIN = "328614"
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }
    private func fixture(_ credentials: MemoryCredentials = MemoryCredentials()) -> (HouseholdStore, MemoryCredentials, UserDefaults) {
        let suite = "MediaVault.HouseholdTests.\(UUID())"; suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let store = HouseholdStore(defaults: defaults, read: credentials.read, write: credentials.write, erase: { credentials.value = nil })
        return (store, credentials, defaults)
    }
    private func enable(_ store: HouseholdStore) async throws -> UUID {
        try await store.setupAsync(pin: adminPIN, confirmation: adminPIN)
        XCTAssertTrue(store.isLocked)
        let id = try XCTUnwrap(store.profiles.first(where: \.isAdmin)?.id)
        try await store.unlockAsync(id, pin: adminPIN)
        return id
    }
    func testOptInPreservesUnconfiguredAccessAndAdminRequiresPINAfterSetupAndRestart() async throws {
        let (store, credentials, defaults) = fixture()
        XCTAssertFalse(store.configured); XCTAssertTrue(store.isAdmin)
        XCTAssertTrue(store.allowsPath(sourceID: nil, path: "video.mp4"))
        let admin = try await enable(store)
        let token = store.sessionToken
        store.lock()
        XCTAssertTrue(store.isLocked); XCTAssertFalse(store.sessionIsCurrent(token))
        XCTAssertFalse(store.allowsPath(sourceID: UUID(), path: "video.mp4"))
        let restarted = HouseholdStore(defaults: defaults, read: credentials.read, write: credentials.write)
        XCTAssertTrue(restarted.isLocked); XCTAssertFalse(restarted.isAdmin)
        do { try await restarted.unlockAsync(admin, pin: "000000"); XCTFail("Wrong PIN unlocked Admin") }
        catch { XCTAssertTrue(restarted.isLocked) }
        try await restarted.unlockAsync(admin, pin: adminPIN)
        XCTAssertTrue(restarted.isAdmin)
        XCTAssertFalse(try XCTUnwrap(credentials.value).contains(adminPIN))
    }
    func testPerProfileCooldownPersistsAndCannotBeSkippedByRestart() async throws {
        let (store, credentials, defaults) = fixture()
        let admin = try await enable(store); store.lock()
        let now = Date(timeIntervalSince1970: 10_000)
        for _ in 0..<5 { XCTAssertThrowsError(try store.unlock(admin, pin: "000000", now: now)) }
        let restarted = HouseholdStore(defaults: defaults, read: credentials.read, write: credentials.write)
        XCTAssertThrowsError(try restarted.unlock(admin, pin: adminPIN, now: now.addingTimeInterval(29)))
        XCTAssertNoThrow(try restarted.unlock(admin, pin: adminPIN, now: now.addingTimeInterval(31)))
    }
    func testMissingAndMalformedConfiguredCredentialsFailClosed() async throws {
        let (store, credentials, defaults) = fixture(); _ = try await enable(store)
        credentials.value = nil
        let missing = HouseholdStore(defaults: defaults, read: credentials.read, write: credentials.write)
        XCTAssertTrue(missing.isLocked); XCTAssertTrue(missing.storageFailure); XCTAssertFalse(missing.isAdmin)
        credentials.value = "invalid secure record"
        let corrupt = HouseholdStore(defaults: defaults, read: credentials.read, write: credentials.write)
        XCTAssertTrue(corrupt.isLocked); XCTAssertFalse(corrupt.allowsPath(sourceID: UUID(), path: "Photos/photo.jpg"))
        do { try await corrupt.setupAsync(pin: adminPIN, confirmation: adminPIN); XCTFail("Overwrote configured controls") } catch { }
    }
    func testAllowlistStartsEmptyAndMatchesOnlySelectedSourceAndFolderComponents() async throws {
        let (store, _, _) = fixture(); let admin = try await enable(store)
        let source = UUID()
        var viewer = HouseholdProfile(name: "Viewer")
        try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN)
        try await store.unlockAsync(viewer.id, pin: "")
        XCTAssertFalse(store.allowsPath(sourceID: source, path: "Media/movie.mp4"))
        try await store.unlockAsync(admin, pin: adminPIN)
        viewer.allowedFolders = [HouseholdFolder(sourceID: source, path: "Media/Kids")]
        try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN)
        try await store.unlockAsync(viewer.id, pin: "")
        XCTAssertTrue(store.allowsPath(sourceID: source, path: "media/KIDS/Season 1/episode.mp4"))
        XCTAssertFalse(store.allowsPath(sourceID: source, path: "Media/Kids Adult/movie.mp4"))
        XCTAssertFalse(store.allowsPath(sourceID: source, path: "Media/Kids/../Adult/movie.mp4"))
        XCTAssertFalse(store.allowsPath(sourceID: UUID(), path: "Media/Kids/movie.mp4"))
        XCTAssertFalse(store.allowsPath(sourceID: nil, path: "Media/Kids/movie.mp4"))
    }
    func testRatingLimitsUseUSCertificationAndNeverVotesOrFilenameGuesses() async throws {
        let (store, _, _) = fixture(); _ = try await enable(store)
        let source = MediaSource(name: "Fixture", host: "fixture.invalid", share: "Media", rootPath: "", username: "")
        var viewer = HouseholdProfile(name: "Child")
        viewer.allowedFolders = [HouseholdFolder(sourceID: source.id, path: "")]
        viewer.maximumMovieRating = "PG"; viewer.maximumTVRating = "TV-G"
        try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN)
        try await store.unlockAsync(viewer.id, pin: "")
        let movie = Movie(filePath: "Family Cartoon.mp4", fileSize: 1, source: source)
        movie.rating = 10; movie.genres = ["Family"]
        XCTAssertFalse(store.allows(movie), "Vote average and family title are not age ratings")
        movie.usContentRating = "PG"; XCTAssertTrue(store.allows(movie))
        movie.usContentRating = "PG-13"; XCTAssertFalse(store.allows(movie))
        movie.usContentRating = "NR"; XCTAssertFalse(store.allows(movie))
        let episode = Movie(filePath: "Series/Series.S01E01.mp4", fileSize: 1, source: source)
        episode.usContentRating = "TV-Y7"; XCTAssertFalse(store.allows(episode))
        episode.usContentRating = "TV-G"; XCTAssertTrue(store.allows(episode))
        let photo = Movie(filePath: "Photos/photo.jpg", fileSize: 1, source: source)
        let song = Movie(filePath: "Music/song.mp3", fileSize: 1, source: source)
        XCTAssertTrue(store.allows(photo)); XCTAssertTrue(store.allows(song))
    }
    func testViewerPINCannotBeBypassedAndViewerCannotChangePermissionsOrReplaceAdmin() async throws {
        let (store, _, _) = fixture(); let admin = try await enable(store)
        var viewer = HouseholdProfile(name: "Teen")
        try await store.saveViewer(viewer, newPIN: "537902", confirmation: "537902", adminPIN: adminPIN)
        store.lock()
        do { try await store.unlockAsync(viewer.id, pin: ""); XCTFail("PIN bypassed") } catch { }
        try await store.unlockAsync(viewer.id, pin: "537902")
        do { try await store.saveViewer(viewer, newPIN: "", confirmation: "", adminPIN: adminPIN); XCTFail("Viewer changed permissions") } catch { }
        try await store.unlockAsync(admin, pin: adminPIN)
        viewer.id = admin
        do { try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN); XCTFail("Admin overwritten") } catch { }
        XCTAssertEqual(store.profiles.filter(\.isAdmin).count, 1)
    }
    func testViewerHistoryAndCommercialResumeIDsAreIsolatedAndAdminIDUnchanged() async throws {
        let (store, _, _) = fixture(); let admin = try await enable(store)
        let first = HouseholdProfile(name: "First"), second = HouseholdProfile(name: "Second"), movie = UUID()
        for viewer in [first, second] { try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN) }
        XCTAssertEqual(store.playbackID(movie), movie.uuidString); XCTAssertNil(store.progress(movie))
        try await store.unlockAsync(first.id, pin: "")
        store.updateProgress(movie) { $0.watched = true; $0.watchlisted = true; $0.position = 120 }
        let firstID = store.playbackID(movie)
        try await store.unlockAsync(second.id, pin: "")
        XCTAssertEqual(store.progress(movie)?.position, 0); XCTAssertEqual(store.progress(movie)?.watchlisted, false)
        XCTAssertNotEqual(firstID, store.playbackID(movie))
        try await store.unlockAsync(first.id, pin: "")
        XCTAssertEqual(store.progress(movie)?.position, 120); XCTAssertEqual(store.progress(movie)?.watched, true)
        try await store.unlockAsync(admin, pin: adminPIN)
        XCTAssertEqual(store.playbackID(movie), movie.uuidString); XCTAssertNil(store.progress(movie))
    }
    func testDisablingAndReenablingPreservesProfilesAndHistoryAndRequiresExistingPIN() async throws {
        let (store, _, _) = fixture(); let admin = try await enable(store)
        let viewer = HouseholdProfile(name: "Viewer"), movie = UUID()
        try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN)
        try await store.unlockAsync(viewer.id, pin: ""); store.updateProgress(movie) { $0.position = 45 }
        try await store.unlockAsync(admin, pin: adminPIN)
        try await store.disableAsync(adminPIN: adminPIN)
        XCTAssertFalse(store.configured); XCTAssertTrue(store.isAdmin); XCTAssertTrue(store.hasSavedProfiles)
        do { try await store.setupAsync(pin: "111111", confirmation: "111111"); XCTFail("Changed saved Admin PIN") } catch { }
        try await store.setupAsync(pin: adminPIN, confirmation: adminPIN)
        XCTAssertTrue(store.isLocked)
        try await store.unlockAsync(viewer.id, pin: "")
        XCTAssertEqual(store.progress(movie)?.position, 45)
    }
    func testBackgroundDuringDerivationCannotUnlockLater() async throws {
        let (initial, credentials, defaults) = fixture(); let admin = try await enable(initial); initial.lock()
        let started = expectation(description: "PIN derivation began")
        var resume: CheckedContinuation<Bool, Never>?
        let store = HouseholdStore(defaults: defaults, read: credentials.read, write: credentials.write,
            pinMatches: { _, _ in await withCheckedContinuation { resume = $0; started.fulfill() } })
        let request = Task { try await store.unlockAsync(admin, pin: adminPIN) }
        await fulfillment(of: [started], timeout: 2)
        store.lock(); resume?.resume(returning: true)
        do { try await request.value; XCTFail("Late PIN result reopened the library") } catch { }
        XCTAssertTrue(store.isLocked)
    }
    func testPhotoCacheAndDelayedReadsAreDeniedAfterProfileLock() async throws {
        let (store, _, _) = fixture(); _ = try await enable(store)
        let data = try PhotoImageLoaderTests.fixture("01.jpg")
        let config = SourceConfig(id: UUID(), host: "fixture.invalid", share: "Photos", rootPath: "", username: "", password: "")
        let loader = PhotoImageLoader(fileSize: { _, _ in Int64(data.count) }, read: { _, _, offset, length in
            data.subdata(in: Int(offset)..<min(data.count, Int(offset) + length))
        }, household: store)
        _ = try await loader.image(config: config, path: "photo.jpg", knownSize: Int64(data.count), maxPixelSize: 64)
        store.lock()
        do { _ = try await loader.image(config: config, path: "photo.jpg", knownSize: Int64(data.count), maxPixelSize: 64); XCTFail("Cache leaked a locked photo") } catch { }
        let admin = try XCTUnwrap(store.profiles.first(where: \.isAdmin)?.id)
        try await store.unlockAsync(admin, pin: adminPIN)
        let started = expectation(description: "Photo read began")
        let gate = PhotoReadGate()
        let delayed = PhotoImageLoader(fileSize: { _, _ in Int64(data.count) }, read: { _, _, _, _ in
            started.fulfill(); await gate.wait(); return data
        }, household: store)
        let request = Task { try await delayed.image(config: config, path: "photo.jpg", knownSize: Int64(data.count), maxPixelSize: 64) }
        await fulfillment(of: [started], timeout: 2)
        store.lock(); await gate.release()
        do { _ = try await request.value; XCTFail("A late read leaked a photo after locking") } catch { }
    }
    func testPINValidationAndSaltedVerifiers() throws {
        XCTAssertFalse(HouseholdPIN.valid("１２３４５６")); XCTAssertFalse(HouseholdPIN.valid("12345")); XCTAssertFalse(HouseholdPIN.valid("1234567"))
        let first = try HouseholdPIN(adminPIN), second = try HouseholdPIN(adminPIN)
        XCTAssertNotEqual(first.salt, second.salt); XCTAssertNotEqual(first.digest, second.digest)
        XCTAssertTrue(first.matches(adminPIN)); XCTAssertFalse(first.matches("000000"))
    }
}

private actor PhotoReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
