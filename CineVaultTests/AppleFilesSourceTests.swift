#if os(iOS)
import AVFoundation
import Foundation
import XCTest
@testable import CineVault

final class AppleFilesSourceTests: XCTestCase {
    @MainActor
    func testFilesFolderImportsCaptionsAndPlaysAfterSeek() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Movies", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle(for: AppleFilesSourceTests.self).url(forResource: "playback", withExtension: "mp4"))
        try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent("Film.mp4"))
        try Data("1\n00:00:00,000 --> 00:00:02,000\nDrive caption\n".utf8).write(to: folder.appendingPathComponent("Film.en.srt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked"), withDestinationURL: folder)
        let selection = AppleFilesSelection(directory: true, entries: [.init(name: "Fixture", bookmark: Data())])
        let transport = AppleFilesSource.transport(selection, resolve: { _ in root }, acquire: { _ in true }, release: { _ in })
        let service = SMBService(cloudTransport: { _, _ in transport })
        let config = SourceConfig(id: UUID(), host: "", share: "", rootPath: "", username: "",
                                  password: "", cloudFileProvider: .appleFiles)
        let files = try await service.scanMedia(config) { _ in }
        XCTAssertEqual(files.map(\.path), ["Movies/Film.mp4"])
        let path = try XCTUnwrap(files.first?.path)
        let sidecars = try await LocalSubtitleService.discover(config: config, videoPath: path) {
            try await service.listEntries($0, directory: $1)
        }
        let caption = try XCTUnwrap(sidecars.first)
        let document = try await LocalSubtitleService.read(caption, config: config,
            size: { try await service.fileSize($0, path: $1) },
            read: { try await service.read($0, path: $1, offset: 0, length: $2) })
        XCTAssertEqual(document.cues.first?.text, "Drive caption")

        let loader = SMBResourceLoader(config: config, path: path, reader: .init(
            size: { try await service.fileSize(config, path: path) },
            read: { try await service.read(config, path: path, offset: $0, length: $1) }))
        let player = AVPlayer(playerItem: AVPlayerItem(asset: loader.makeAsset()))
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
            withExtendedLifetime(loader) {}
        }
        player.play()
        try await waitForPlayback(player, beyond: 0.3)
        let finished = expectation(description: "Files video seek")
        player.seek(to: CMTime(seconds: 8, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) {
            XCTAssertTrue($0)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 20)
        player.play()
        try await waitForPlayback(player, beyond: 8.3)
    }

    func testFilesNeverReadsAnUnselectedSiblingAndHandlesRevokedBookmarks() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("Selected.mp4")
        try Data("fixture".utf8).write(to: selected)
        try Data("private".utf8).write(to: root.appendingPathComponent("Private.mp4"))
        let selection = AppleFilesSelection(directory: false, entries: [.init(name: "Selected.mp4", bookmark: Data())])
        let transport = AppleFilesSource.transport(selection, resolve: { _ in selected }, acquire: { _ in true }, release: { _ in })
        let entries = try await transport.list("", check: {})
        XCTAssertEqual(entries.map(\.path), ["Selected.mp4"])
        let bytes = try await transport.read("Selected.mp4", offset: 1, length: 3, check: {})
        XCTAssertEqual(bytes, Data("ixt".utf8))
        for denied in ["Private.mp4", "selected.mp4", "../Private.mp4"] {
            do {
                _ = try await transport.read(denied, offset: 1, length: 3, check: {})
                XCTFail("Opened a file beyond the exact selection")
            } catch CloudFileError.invalidPath {}
        }
        let revoked = AppleFilesSource.transport(selection, resolve: { _ in selected }, acquire: { _ in false }, release: { _ in })
        do {
            _ = try await revoked.list("", check: {})
            XCTFail("Listed a file after access was revoked")
        } catch AppleFilesError.tryFilesAgain {}
    }

    func testFilesReconnectsOriginalSelectionAfterAFailedDisconnect() throws {
        enum SaveError: Error, Equatable { case failed }
        let id = UUID()
        defer { try? AppleFilesSource.remove(id) }
        let original = "file:///fixture-drive/Example.mp4"
        func selection(bookmark: UInt8, identity: String) -> AppleFilesSelection {
            AppleFilesSelection(directory: false, entries: [
                .init(name: "Example.mp4", bookmark: Data([bookmark]), identity: identity)
            ])
        }
        try AppleFilesSource.install(selection(bookmark: 1, identity: original), id: id, replacing: false)
        XCTAssertThrowsError(try AppleFilesSource.remove(id) { throw SaveError.failed }) {
            XCTAssertEqual($0 as? SaveError, .failed)
        }
        XCTAssertFalse(try AppleFilesSource.isDirectory(id))
        XCTAssertThrowsError(try AppleFilesSource.install(selection(bookmark: 2, identity: "file:///different/Example.mp4"),
                                                          id: id, replacing: true))
        try AppleFilesSource.install(selection(bookmark: 3, identity: original), id: id, replacing: true)
        try AppleFilesSource.remove(id)
        XCTAssertThrowsError(try AppleFilesSource.isDirectory(id))
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    private func waitForPlayback(_ player: AVPlayer, beyond time: Double) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while ContinuousClock.now < deadline {
            if player.currentTime().seconds > time { return }
            if let error = player.currentItem?.error ?? player.error { throw error }
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTFail("Files video did not reach \(time) seconds")
    }
}
#endif
