import Core
import SwiftUI

/// The privacy policy, read from `docs/app-store/privacy-policy.md`, which
/// project.yml bundles into both apps. It's the same file the App Store
/// listing's privacy policy URL is made from, so the copy in the app can't
/// fall behind it. App Review wants the policy reachable inside the app as
/// well as linked from the listing (guideline 5.1.1(i)).
struct PrivacyPolicyView: View {
    /// Read and parsed once per launch. Nonisolated, as both are `Sendable`
    /// and touch nothing on the main actor.
    nonisolated private static let document = MarkdownDocument(markdown)

    var body: some View {
        ScrollView {
            MarkdownDocumentView(Self.document)
                .padding()
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    nonisolated private static var markdown: String {
        guard let url = Bundle.main.url(forResource: "privacy-policy", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "The privacy policy is missing from this build. Multitrack collects nothing: your information stays on your devices and in your own iCloud account."
        }
        return text
    }
}
