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
        try await store.setupAsync(pin: adminPIN, confirmation: adminPIN, intent: store.authenticationToken)
        XCTAssertTrue(store.isLocked)
        let id = try XCTUnwrap(store.profiles.first(where: \.isAdmin)?.id)
        try await store.unlockAsync(id, pin: adminPIN, intent: store.authenticationToken)
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
        do { try await restarted.unlockAsync(admin, pin: "000000", intent: restarted.authenticationToken); XCTFail("Wrong PIN unlocked Admin") }
        catch { XCTAssertTrue(restarted.isLocked) }
        try await restarted.unlockAsync(admin, pin: adminPIN, intent: restarted.authenticationToken)
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
        do { try await corrupt.setupAsync(pin: adminPIN, confirmation: adminPIN, intent: corrupt.authenticationToken); XCTFail("Overwrote configured controls") } catch { }
    }
    func testAllowlistStartsEmptyAndMatchesOnlySelectedSourceAndFolderComponents() async throws {
        let (store, _, _) = fixture(); let admin = try await enable(store)
        let source = UUID()
        var viewer = HouseholdProfile(name: "Viewer")
        try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN, intent: store.authenticationToken)
        try await store.unlockAsync(viewer.id, pin: "", intent: store.authenticationToken)
        XCTAssertFalse(store.allowsPath(sourceID: source, path: "Media/movie.mp4"))
        try await store.unlockAsync(admin, pin: adminPIN, intent: store.authenticationToken)
        viewer.allowedFolders = [HouseholdFolder(sourceID: source, path: "Media/Kids")]
        try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN, intent: store.authenticationToken)
        try await store.unlockAsync(viewer.id, pin: "", intent: store.authenticationToken)
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
        try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN, intent: store.authenticationToken)
        try await store.unlockAsync(viewer.id, pin: "", intent: store.authenticationToken)
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
        try await store.saveViewer(viewer, newPIN: "537902", confirmation: "537902", adminPIN: adminPIN, intent: store.authenticationToken)
        store.lock()
        do { try await store.unlockAsync(viewer.id, pin: "", intent: store.authenticationToken); XCTFail("PIN bypassed") } catch { }
        try await store.unlockAsync(viewer.id, pin: "537902", intent: store.authenticationToken)
        do { try await store.saveViewer(viewer, newPIN: "", confirmation: "", adminPIN: adminPIN, intent: store.authenticationToken); XCTFail("Viewer changed permissions") } catch { }
        store.lock()
        for _ in 0..<5 { XCTAssertThrowsError(try store.unlock(viewer.id, pin: "000000")) }
        try await store.unlockAsync(admin, pin: adminPIN, intent: store.authenticationToken)
        try await store.saveViewer(viewer, newPIN: "", confirmation: "", adminPIN: adminPIN, intent: store.authenticationToken)
        try await store.unlockAsync(viewer.id, pin: "", intent: store.authenticationToken)
        XCTAssertEqual(store.current?.id, viewer.id, "An Admin-authorized PIN removal must clear the old credential's cooldown")
        try await store.unlockAsync(admin, pin: adminPIN, intent: store.authenticationToken)
        viewer.id = admin
        do { try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN, intent: store.authenticationToken); XCTFail("Admin overwritten") } catch { }
        XCTAssertEqual(store.profiles.filter(\.isAdmin).count, 1)
    }
    func testViewerHistoryAndCommercialResumeIDsAreIsolatedAndAdminIDUnchanged() async throws {
        let (store, _, _) = fixture(); let admin = try await enable(store)
        let first = HouseholdProfile(name: "First"), second = HouseholdProfile(name: "Second"), movie = UUID()
        for viewer in [first, second] { try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN, intent: store.authenticationToken) }
        XCTAssertEqual(store.playbackID(movie), movie.uuidString); XCTAssertNil(store.progress(movie))
        try await store.unlockAsync(first.id, pin: "", intent: store.authenticationToken)
        store.updateProgress(movie) { $0.watched = true; $0.watchlisted = true; $0.position = 120 }
        let firstID = store.playbackID(movie)
        try await store.unlockAsync(second.id, pin: "", intent: store.authenticationToken)
        XCTAssertEqual(store.progress(movie)?.position, 0); XCTAssertEqual(store.progress(movie)?.watchlisted, false)
        XCTAssertNotEqual(firstID, store.playbackID(movie))
        try await store.unlockAsync(first.id, pin: "", intent: store.authenticationToken)
        XCTAssertEqual(store.progress(movie)?.position, 120); XCTAssertEqual(store.progress(movie)?.watched, true)
        try await store.unlockAsync(admin, pin: adminPIN, intent: store.authenticationToken)
        XCTAssertEqual(store.playbackID(movie), movie.uuidString); XCTAssertNil(store.progress(movie))
    }
    func testDisablingAndReenablingPreservesProfilesAndHistoryAndRequiresExistingPIN() async throws {
        let (store, _, _) = fixture(); let admin = try await enable(store)
        let viewer = HouseholdProfile(name: "Viewer"), movie = UUID()
        try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN, intent: store.authenticationToken)
        try await store.unlockAsync(viewer.id, pin: "", intent: store.authenticationToken); store.updateProgress(movie) { $0.position = 45 }
        try await store.unlockAsync(admin, pin: adminPIN, intent: store.authenticationToken)
        try await store.disableAsync(adminPIN: adminPIN, intent: store.authenticationToken)
        XCTAssertFalse(store.configured); XCTAssertTrue(store.isAdmin); XCTAssertTrue(store.hasSavedProfiles)
        do { try await store.setupAsync(pin: "111111", confirmation: "111111", intent: store.authenticationToken); XCTFail("Changed saved Admin PIN") } catch { }
        try await store.setupAsync(pin: adminPIN, confirmation: adminPIN, intent: store.authenticationToken)
        XCTAssertTrue(store.isLocked)
        try await store.unlockAsync(viewer.id, pin: "", intent: store.authenticationToken)
        XCTAssertEqual(store.progress(movie)?.position, 45)
    }
    func testBackgroundDuringDerivationCannotUnlockLater() async throws {
        let (initial, credentials, defaults) = fixture(); let admin = try await enable(initial); initial.lock()
        let started = expectation(description: "PIN derivation began")
        var resume: CheckedContinuation<Bool, Never>?
        let store = HouseholdStore(defaults: defaults, read: credentials.read, write: credentials.write,
            pinMatches: { _, _ in await withCheckedContinuation { resume = $0; started.fulfill() } })
        let request = Task { try await store.unlockAsync(admin, pin: adminPIN, intent: store.authenticationToken) }
        await fulfillment(of: [started], timeout: 2)
        store.lock(); resume?.resume(returning: true)
        do { try await request.value; XCTFail("Late PIN result reopened the library") } catch { }
        XCTAssertTrue(store.isLocked)
    }
    func testAuthenticationQueuedUntilAfterBackgroundCannotUnlock() async throws {
        let (store, _, _) = fixture(); let admin = try await enable(store)
        let viewer = HouseholdProfile(name: "Viewer")
        try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN, intent: store.authenticationToken)
        store.setActive(false)
        for (id, pin) in [(admin, adminPIN), (viewer.id, "")] {
            do { try await store.unlockAsync(id, pin: pin, intent: store.authenticationToken); XCTFail("Background authentication succeeded") } catch { }
        }
        store.setActive(true)
        XCTAssertTrue(store.isLocked, "Foreground must remain at the picker")
        try await store.unlockAsync(admin, pin: adminPIN, intent: store.authenticationToken)
        XCTAssertTrue(store.isAdmin)
    }
    func testOldButtonIntentCannotAuthenticateAfterBackgroundAndForegroundCycle() async throws {
        let (store, _, _) = fixture(); let admin = try await enable(store)
        let viewer = HouseholdProfile(name: "Viewer")
        try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN, intent: store.authenticationToken)
        let intent = store.authenticationToken
        store.setActive(false); store.setActive(true)
        for (id, pin) in [(admin, adminPIN), (viewer.id, "")] {
            do { try await store.unlockAsync(id, pin: pin, intent: intent); XCTFail("A stale button press unlocked after returning") } catch { }
        }
        XCTAssertTrue(store.isLocked)
        let (unconfigured, _, _) = fixture()
        let setupIntent = unconfigured.authenticationToken
        unconfigured.setActive(false); unconfigured.setActive(true)
        do {
            try await unconfigured.setupAsync(pin: adminPIN, confirmation: adminPIN, intent: setupIntent)
            XCTFail("A stale setup submission changed controls after returning")
        } catch { }
        XCTAssertFalse(unconfigured.configured)
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
        try await store.unlockAsync(admin, pin: adminPIN, intent: store.authenticationToken)
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
    func testEmbyPhotoDoesNotReachTheImageEndpointWithoutALibraryGrant() async throws {
        let (store, _, _) = fixture(); _ = try await enable(store)
        let config = SourceConfig(id: UUID(), host: "https://emby.fixture.invalid", share: "photos", rootPath: "",
                                  username: "owner", password: "fixture-token", isEmby: true)
        let viewer = HouseholdProfile(name: "Viewer", allowedFolders: [HouseholdFolder(sourceID: config.id, path: "emby-photos")])
        let allowed = HouseholdProfile(name: "Allowed viewer", allowedFolders: [HouseholdFolder(sourceID: config.id, path: "")])
        for profile in [viewer, allowed] {
            try await store.saveViewer(profile, newPIN: nil, confirmation: "", adminPIN: adminPIN, intent: store.authenticationToken)
        }
        let path = EmbySourceConnection.photoPath("Photo")
        let bytes = try PhotoImageLoaderTests.fixture("01.jpg")
        let requested = expectation(description: "Only the explicitly granted profile can reach Emby")
        requested.assertForOverFulfill = true
        let loader = PhotoImageLoader(readEmby: { _, item, width in
            XCTAssertEqual(item, "Photo")
            XCTAssertEqual(width, 64)
            requested.fulfill()
            return bytes
        }, household: store)
        try await store.unlockAsync(viewer.id, pin: "", intent: store.authenticationToken)
        do {
            _ = try await loader.image(config: config, path: path, knownSize: 0, maxPixelSize: 64)
            XCTFail("Folder grant allowed a provider photo read")
        } catch PhotoLoadingError.unavailable {}
        try await store.unlockAsync(allowed.id, pin: "", intent: store.authenticationToken)
        _ = try await loader.image(config: config, path: path, knownSize: 0, maxPixelSize: 64)
        await fulfillment(of: [requested], timeout: 1)
        store.lock()
        do {
            _ = try await loader.image(config: config, path: path, knownSize: 0, maxPixelSize: 64)
            XCTFail("Cached provider photo escaped the locked profile")
        } catch PhotoLoadingError.unavailable {}
    }

    func testPINValidationAndSaltedVerifiers() throws {
        XCTAssertFalse(HouseholdPIN.valid("１２３４５６")); XCTAssertFalse(HouseholdPIN.valid("12345")); XCTAssertFalse(HouseholdPIN.valid("1234567"))
        let first = try HouseholdPIN(adminPIN), second = try HouseholdPIN(adminPIN)
        XCTAssertNotEqual(first.salt, second.salt); XCTAssertNotEqual(first.digest, second.digest)
        XCTAssertTrue(first.matches(adminPIN)); XCTAssertFalse(first.matches("000000"))
    }
    func testDirectPlayerRejectsDeniedMediaAndLockDuringPreparation() async throws {
        let (store, _, _) = fixture(); let admin = try await enable(store)
        let source = MediaSource(name: "Fixture", host: "fixture.invalid", share: "Media", rootPath: "", username: "")
        let movie = Movie(filePath: "Private/movie.mp4", fileSize: 1, source: source)
        movie.isWatched = true; movie.playbackPosition = 120
        let viewer = HouseholdProfile(name: "Empty viewer")
        try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN, intent: store.authenticationToken)
        try await store.unlockAsync(viewer.id, pin: "", intent: store.authenticationToken)
        do {
            _ = try await PlaybackController.prepare(movie: movie, resume: false, services: PlaybackServices(), loadPlayable: { _ in
                XCTFail("Denied media reached the player"); return true
            }, household: store)
            XCTFail("Denied media opened")
        } catch PlaybackPreparationError.fileUnavailable { }
        try await store.unlockAsync(admin, pin: adminPIN, intent: store.authenticationToken)
        do {
            _ = try await PlaybackController.prepare(movie: movie, resume: false, services: PlaybackServices(), loadPlayable: { _ in
                store.lock(); return true
            }, household: store)
            XCTFail("A late asset opened after locking")
        } catch PlaybackPreparationError.fileUnavailable { }
        XCTAssertTrue(movie.isWatched); XCTAssertEqual(movie.playbackPosition, 120)
    }
    func testLockStopsPlayerAndLateCheckpointsCannotChangeNextViewerHistory() async throws {
        let (store, _, _) = fixture(); let admin = try await enable(store)
        let source = MediaSource(name: "Fixture", host: "fixture.invalid", share: "Media", rootPath: "", username: "")
        let movie = Movie(filePath: "movie.mp4", fileSize: 1, source: source)
        movie.playbackPosition = 300
        var first = HouseholdProfile(name: "First"), second = HouseholdProfile(name: "Second")
        first.allowedFolders = [HouseholdFolder(sourceID: source.id, path: "")]; second.allowedFolders = first.allowedFolders
        for viewer in [first, second] { try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN, intent: store.authenticationToken) }
        try await store.unlockAsync(first.id, pin: "", intent: store.authenticationToken)
        let controller = try XCTUnwrap(PlaybackController(movie: movie, resume: false, services: PlaybackServices(), household: store))
        controller.record(time: 60)
        XCTAssertEqual(store.progress(movie.id)?.position, 60)
        try await store.unlockAsync(second.id, pin: "", intent: store.authenticationToken)
        XCTAssertNil(controller.player.currentItem, "Lock must clear the player and its metadata")
        controller.record(time: 200)
        XCTAssertEqual(store.progress(movie.id)?.position, 0)
        try await store.unlockAsync(first.id, pin: "", intent: store.authenticationToken)
        XCTAssertEqual(store.progress(movie.id)?.position, 60)
        try await store.unlockAsync(admin, pin: adminPIN, intent: store.authenticationToken)
        XCTAssertEqual(movie.playbackPosition, 300, "Viewer checkpoints must preserve legacy Admin progress")
    }
    func testMetadataRatingRevokesPausedPlaybackAndClearsSubtitleSheet() async throws {
        let (store, _, _) = fixture(); _ = try await enable(store)
        let source = MediaSource(name: "Fixture", host: "fixture.invalid", share: "Media", rootPath: "", username: "")
        let movie = Movie(filePath: "movie.mp4", fileSize: 1, source: source); movie.usContentRating = "PG"
        var viewer = HouseholdProfile(name: "Child")
        viewer.allowedFolders = [HouseholdFolder(sourceID: source.id, path: "")]; viewer.maximumMovieRating = "PG"
        try await store.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: adminPIN, intent: store.authenticationToken)
        try await store.unlockAsync(viewer.id, pin: "", intent: store.authenticationToken)
        let controller = try XCTUnwrap(PlaybackController(movie: movie, resume: false, services: PlaybackServices(), household: store))
        controller.subtitles.presented = true
        movie.usContentRating = "R"
        // Observation delivers after the model mutation; no playback tick or user action is required.
        for _ in 0..<10 where controller.player.currentItem != nil { await Task.yield() }
        XCTAssertNil(controller.player.currentItem)
        XCTAssertFalse(controller.subtitles.presented)
        XCTAssertFalse(controller.permitsContinuation)
        XCTAssertEqual(controller.playbackError, "This item is no longer available for this profile.")
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
