import SwiftUI

struct MediaPrivacyPolicyView: View {
    private let paragraphs: [String] = {
        guard let url = Bundle.main.url(forResource: "PRIVACY", withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return markdown.components(separatedBy: "\n\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }()

    var body: some View {
        Form {
            if paragraphs.isEmpty {
                Text("The bundled policy is unavailable. Visit github.com/dinesh-devkota/mediavault and open docs/PRIVACY.md.")
                    .focusable()
            }
            ForEach(paragraphs.indices, id: \.self) { index in
                let paragraph = paragraphs[index]
                if paragraph.hasPrefix("## ") {
                    Text(String(paragraph.dropFirst(3)))
                        .font(.headline).accessibilityAddTraits(.isHeader).focusable()
                } else {
                    Text(formatted(paragraph))
                        .foregroundStyle(.secondary).focusable()
                }
            }
        }
        .navigationTitle("Privacy policy")
    }

    private func formatted(_ paragraph: String) -> AttributedString {
        let text = paragraph.replacingOccurrences(of: "\n", with: " ")
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
