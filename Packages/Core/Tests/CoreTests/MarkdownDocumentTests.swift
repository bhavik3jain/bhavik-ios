import Foundation
import Testing
@testable import Core

@Test func markdownReadsTitleHeadingsParagraphsAndBullets() {
    let document = MarkdownDocument("""
    # Multitrack Privacy Policy

    Effective October 12, 2026

    ## Where your information is kept

    - **On your devices**, in the app's own storage.
    - **In your iCloud account**, so it syncs.

    ### Smaller heading
    """)
    #expect(document.blocks == [
        .title("Multitrack Privacy Policy"),
        .paragraph("Effective October 12, 2026"),
        .heading("Where your information is kept"),
        .bullet("**On your devices**, in the app's own storage."),
        .bullet("**In your iCloud account**, so it syncs."),
        .heading("Smaller heading"),
    ])
}

@Test func markdownJoinsWrappedLinesOfAParagraphAndABullet() {
    let document = MarkdownDocument("""
    One paragraph
    over two lines.

    - A bullet
      that wraps.
    Still the bullet.

    Next paragraph.
    """)
    #expect(document.blocks == [
        .paragraph("One paragraph over two lines."),
        .bullet("A bullet that wraps. Still the bullet."),
        .paragraph("Next paragraph."),
    ])
}

@Test func markdownKeepsInlineSyntaxForTheView() {
    let document = MarkdownDocument("Write to [us](mailto:someone@example.com) *any* time.")
    #expect(document.blocks == [.paragraph("Write to [us](mailto:someone@example.com) *any* time.")])
}

@Test func markdownReadsWindowsLineEndingsLikeUnix() {
    // "\r\n" is a single Character in Swift, so a split on "\n" alone would
    // never match it and read the whole file as one line — the same trap
    // CSVParser's `case "\r\n"` guards against.
    let unix = MarkdownDocument("# Title\n\nFirst.\n\n- Bullet\n")
    let windows = MarkdownDocument("# Title\r\n\r\nFirst.\r\n\r\n- Bullet\r\n")
    #expect(windows == unix)
    #expect(unix.blocks == [.title("Title"), .paragraph("First."), .bullet("Bullet")])
}

@Test func aHashWithoutASpaceIsText() {
    #expect(MarkdownDocument("#hashtag").blocks == [.paragraph("#hashtag")])
}

@Test func theBundledPrivacyPolicyParsesIntoSections() throws {
    // The file Settings shows and App Store Connect links to. A heading lost
    // to a formatting slip would run two sections together on screen.
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // Core
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root
        .appending(path: "docs/app-store/privacy-policy.md")
    let text = try String(contentsOf: url, encoding: .utf8)
    let blocks = MarkdownDocument(text).blocks
    #expect(blocks.first == .title("Multitrack Privacy Policy"))
    let headings = blocks.compactMap { block -> String? in
        if case .heading(let text) = block { text } else { nil }
    }
    #expect(headings.contains("Your API keys"))
    #expect(headings.contains("Contact"))
    #expect(text.contains("multitrack@thebhavikjain.com"))
}
