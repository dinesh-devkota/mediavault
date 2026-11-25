#if os(iOS)
import SwiftUI

struct PhonePrivacyPolicyLink: View {
    private static let url = URL(string: "https://github.com/dinesh-devkota/mediavault/blob/main/docs/PRIVACY.md")!

    var body: some View {
        Link("Privacy policy", destination: Self.url)
    }
}
#endif
