import SwiftUI

struct PlaybackAcknowledgementsView: View {
    private var license: String {
        guard let url = Bundle.main.url(forResource: "VLCKit-LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The license is available at github.com/videolan/vlckit in the COPYING file."
        }
        return text
    }

    var body: some View {
        List {
            Section("VideoLAN VLCKit") {
                Text("MediaVault uses the open-source VLCKit playback library from VideoLAN for additional media formats.")
                Text("VLCKit is licensed under the GNU Lesser General Public License, version 2.1 or later. It is supplied without warranty.")
                Text("Source and build instructions: github.com/videolan/vlckit")
                Text("Pinned source: 7f98c70f9f0c11fbdf828220890bd6280361ae99")
                    .font(.caption)
            }
            Section("License") {
                ForEach(Array(license.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).font(.caption)
                        #if os(tvOS)
                        .focusable()
                        #else
                        .textSelection(.enabled)
                        #endif
                }
            }
        }
        .navigationTitle("Playback library")
    }
}
