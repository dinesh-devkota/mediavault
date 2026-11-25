import CineVaultCore
import UIKit
import XCTest
@testable import CineVault

@MainActor
final class AlternativePlaybackIntegrationTests: XCTestCase {
    func testCommonContainersDecodeAndSeekOverGuardedSMB() async throws {
        for ext in ["mkv", "avi", "webm"] {
            let config = SourceConfig(id: UUID(), host: "127.0.0.1", port: 1445, share: "FORMATPLAYBACK",
                                      rootPath: "", username: "cinevault", password: "fixture-only")
            let path = "Feature." + ext
            let relay = try MediaByteRelay(fileExtension: ext, reader: .init(
                size: { try await SMBService.shared.fileSize(config, path: path) },
                read: { offset, length in try await SMBService.shared.read(config, path: path, offset: offset, length: length) }
            ), authorize: { true })
            let engine = AlternativePlayback(relay: relay)
            let drawable = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
            engine.engine.drawable = drawable
            do {
                let url = try await relay.start()
                try await engine.prepare(url: url)
                XCTAssertTrue(engine.ready, ext)
                XCTAssertGreaterThan(engine.duration, 10, ext)
                engine.play()
                try await wait(engine, description: ext + " begins") { engine.playing && engine.position > 0.5 }
                engine.seek(to: 7)
                try await wait(engine, description: ext + " seeks") { engine.playing && engine.position > 7.5 }
                XCTAssertFalse(engine.audioTracks.isEmpty, "The fixture must expose its audio track")
                engine.pause()
                XCTAssertFalse(engine.playing)
                engine.play()
                try await wait(engine, description: ext + " completes") { engine.ended }
                XCTAssertNil(engine.failure)
            } catch { engine.stop(); await SMBService.shared.reset(config); throw error }
            engine.stop(); await SMBService.shared.reset(config)
            withExtendedLifetime(drawable) { }
        }
    }

    func testCandidatePolicyRejectsCodePhotosAndDiscImages() {
        for path in ["fetch.d.ts", "node_modules/module/index.ts", "Photo.jpg", "Disc.iso", "list.m3u", "stream.url"] {
            XCTAssertFalse(AlternativePlayback.supports(path: path), path)
        }
        for path in ["Movie.mkv", "Movie.webm", "Movie.avi", "Music.flac"] {
            XCTAssertTrue(AlternativePlayback.supports(path: path), path)
        }
    }

    private func wait(_ engine: AlternativePlayback, description: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(35)
        while Date() < deadline {
            if let error = engine.failure { throw NSError(domain: "AlternativePlaybackTests", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Timed out: \(description), position \(engine.position), engine state \(engine.engine.state.rawValue)")
        throw NSError(domain: "AlternativePlaybackTests", code: 2)
    }
}
