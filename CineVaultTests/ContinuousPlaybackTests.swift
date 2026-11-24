import AVFoundation
import XCTest
@testable import CineVault

#if !CINEVAULT_COMMERCIAL
@MainActor
final class ContinuousPlaybackTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() {
        super.setUp()
        suite = "continuous-playback-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func episodes() -> [Movie] {
        let source = MediaSource(name: "Fixture", host: "fixture.invalid", share: "Media", rootPath: "TV", username: "")
        return [1, 2, 4].map { Movie(filePath: "TV/Show/Show.S01E0\($0).mp4", fileSize: 100, source: source) }
    }
    private func controller(_ movie: Movie) throws -> PlaybackController {
        try XCTUnwrap(PlaybackController(movie: movie, resume: false, services: PlaybackServices()))
    }
    private func end(_ controller: PlaybackController) {
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: controller.player.currentItem)
    }

    func testDefaultOffAndNearEndProgressDoNotOfferAutoplay() throws {
        let items = episodes(), controller = try controller(items[0])
        let flow = ContinuousPlayback(controller: controller, services: PlaybackServices(), defaults: defaults, library: { items })
        defer { flow.stop() }
        XCTAssertFalse(defaults.bool(forKey: ContinuousPlayback.enabledKey))
        controller.record(time: 100)
        flow.offerNext(startTimer: false)
        XCTAssertNil(flow.next)
        end(controller); flow.offerNext(startTimer: false)
        XCTAssertNil(flow.next)
    }

    func testNaturalEndOffersNextAndCancelNeverRestartsSameEpisode() throws {
        defaults.set(true, forKey: ContinuousPlayback.enabledKey)
        let items = episodes(), controller = try controller(items[0])
        let flow = ContinuousPlayback(controller: controller, services: PlaybackServices(), defaults: defaults, library: { items })
        defer { flow.stop() }
        end(controller); flow.offerNext(startTimer: false)
        XCTAssertEqual(flow.next?.movie.id, items[1].id)
        flow.tick(); XCTAssertEqual(flow.secondsRemaining, 9)
        flow.cancel(); flow.offerNext(startTimer: false)
        XCTAssertNil(flow.next)
        flow.tick(); XCTAssertFalse(flow.preparing)
    }

    func testTrialBoundaryErrorStoppedPlaybackAndMovieNeverContinue() throws {
        defaults.set(true, forKey: ContinuousPlayback.enabledKey)
        for reason in ["trial", "error", "stopped", "movie"] {
            let items = episodes()
            if reason == "movie" { items[0].filePath = "TV/Film.mp4" }
            let controller = try controller(items[0])
            let flow = ContinuousPlayback(controller: controller, services: PlaybackServices(), defaults: defaults, library: { items })
            if reason == "trial" { controller.player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: 10, preferredTimescale: 600) }
            if reason == "error" { NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: controller.player.currentItem) }
            if reason == "stopped" { controller.stop(saveProgress: false) }
            end(controller); flow.offerNext(startTimer: false)
            XCTAssertNil(flow.next, reason)
            flow.stop()
        }
    }

    func testAppBackgroundAndSubtitleSheetCancelAndSuppressCountdown() throws {
        defaults.set(true, forKey: ContinuousPlayback.enabledKey)
        let items = episodes(), controller = try controller(items[0])
        let flow = ContinuousPlayback(controller: controller, services: PlaybackServices(), defaults: defaults, library: { items })
        defer { flow.stop() }
        controller.subtitles.presented = true
        end(controller); flow.offerNext(startTimer: false)
        XCTAssertNil(flow.next)
        controller.subtitles.presented = false
        flow.offerNext(startTimer: false)
        XCTAssertNotNil(flow.next)
        flow.setActive(false)
        XCTAssertNil(flow.next)
        flow.tick(); flow.setActive(true)
        flow.offerNext(startTimer: false)
        XCTAssertNil(flow.next)
    }

    func testSubtitleSheetDisappearanceKeepsPlaybackAliveButExitStopsIt() throws {
        for reason in ["subtitle sheet", "actual disappearance", "explicit close"] {
            let items = episodes(), controller = try controller(items[0])
            let flow = ContinuousPlayback(controller: controller, services: PlaybackServices(), defaults: defaults, library: { items })
            controller.subtitles.presented = reason != "actual disappearance"
            if reason == "explicit close" { flow.stop() }
            else { flow.viewDisappeared() }
            end(controller)
            XCTAssertEqual(controller.didEndNaturally, reason == "subtitle sheet", reason)
            flow.stop()
        }
    }

    func testLaunchRevalidatesMissingAndIgnoredNextEpisode() throws {
        defaults.set(true, forKey: ContinuousPlayback.enabledKey)
        let items = episodes(), controller = try controller(items[0])
        let flow = ContinuousPlayback(controller: controller, services: PlaybackServices(), defaults: defaults, library: { items }, prepare: { _, _, _ in
            XCTFail("A stale target must not prepare"); return nil
        })
        defer { flow.stop() }
        end(controller); flow.offerNext(startTimer: false)
        items[1].isMissing = true
        flow.playNow()
        XCTAssertNil(flow.next)
        XCTAssertFalse(flow.preparing)
    }

    func testLatePreparationAfterCancelCannotReplacePlayer() async throws {
        defaults.set(true, forKey: ContinuousPlayback.enabledKey)
        let items = episodes(), original = try controller(items[0])
        let entered = expectation(description: "Preparation started")
        let completed = expectation(description: "Preparation returned")
        var release: CheckedContinuation<Void, Never>?
        var candidate: PlaybackController?
        let flow = ContinuousPlayback(controller: original, services: PlaybackServices(), defaults: defaults, library: { items }, prepare: { movie, _, _ in
            await withCheckedContinuation { release = $0; entered.fulfill() }
            candidate = try self.controller(movie)
            completed.fulfill()
            return candidate
        })
        defer { flow.stop(); candidate?.stop(saveProgress: false) }
        end(original); flow.offerNext(startTimer: false); flow.playNow()
        await fulfillment(of: [entered], timeout: 2)
        flow.cancel(); release?.resume()
        await fulfillment(of: [completed], timeout: 2)
        await Task.yield()
        XCTAssertTrue(flow.controller === original)
        XCTAssertNil(flow.next)
        XCTAssertFalse(flow.preparing)
        XCTAssertEqual(items[1].playbackPosition, 0)
        XCTAssertFalse(items[1].isWatched)
    }
}
#endif
