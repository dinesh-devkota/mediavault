import AVKit
import Combine
import SwiftUI

struct WebVideoView: View {
    @State private var address = ""
    @State private var stream: Stream?
    @State private var message: String?

    private struct Stream: Identifiable {
        let id = UUID()
        let player: AVPlayer
        let item: AVPlayerItem

        init(url: URL) {
            item = AVPlayerItem(url: url)
            player = AVPlayer(playerItem: item)
        }
    }

    var body: some View {
        Form {
            Section("Play a direct video link") {
                TextField("HTTPS stream or video address", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: address) { _, _ in message = nil }
                Button("Play on Apple TV", action: play)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let message { Text(message).focusable() }
            }
            Section("Watch YouTube and other websites") {
                Text("Open the video in Brave on your iPhone, iPad, or Mac. On the same Wi-Fi network, open Control Center, choose Screen Mirroring, then select this Apple TV. Control the video in Brave.")
                    .focusable()
            }
        }
        .navigationTitle("Web Video")
        .fullScreenCover(item: $stream) { current in
            VideoPlayer(player: current.player)
                .ignoresSafeArea()
                .onAppear { current.player.play() }
                .onDisappear { current.player.pause() }
                .onReceive(current.item.publisher(for: \.status)) { status in
                    if status == .failed { playbackFailed(current) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime,
                                                                 object: current.item)) { _ in
                    playbackFailed(current)
                }
        }
    }

    private func play() {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: input), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty, url.user == nil else {
            message = "Enter a full HTTPS link to a video file or HLS stream."
            return
        }
        if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") {
            message = "Use Screen Mirroring to watch a YouTube page. The steps are below."
            return
        }
        message = nil
        stream = Stream(url: url)
    }

    private func playbackFailed(_ current: Stream) {
        guard stream?.id == current.id else { return }
        stream = nil
        message = "Apple TV couldn’t play this link. Use a direct video file or HLS stream, or mirror the page from Brave."
    }
}
