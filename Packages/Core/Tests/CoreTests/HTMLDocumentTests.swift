import CoreGraphics
import Foundation
import Testing
@testable import Core

private func decide(
    _ address: String,
    _ trigger: HTMLDocumentNavigation.Trigger,
    mainFrame: Bool = true
) -> HTMLDocumentNavigation.Decision {
    HTMLDocumentNavigation.decide(url: URL(string: address), trigger: trigger, isMainFrame: mainFrame)
}

// MARK: - Navigation policy

@Test func theViewsOwnLoadIsAllowed() {
    // `loadHTMLString(_:baseURL: nil)` arrives as an `.other` navigation to about:blank.
    #expect(decide("about:blank", .other) == .allow)
}

@Test func inPageAnchorsAreAllowedWhetherTappedOrScripted() {
    #expect(decide("about:blank#mix", .linkActivated) == .allow)
    #expect(decide("about:blank#fixing", .other) == .allow)
}

@Test func tappingABareBlankLinkIsCancelled() {
    // An `href=""` would swap the report for an empty page.
    #expect(decide("about:blank", .linkActivated) == .cancel)
}

@Test func reloadAndHistoryAreCancelled() {
    #expect(decide("about:blank", .reload) == .cancel)
    #expect(decide("about:blank", .backForward) == .cancel)
    #expect(decide("about:blank#mix", .backForward) == .cancel)
}

@Test func aTappedWebLinkOpensExternally() throws {
    let url = try #require(URL(string: "https://www.apple.com/legal/"))
    #expect(decide(url.absoluteString, .linkActivated) == .openExternally(url))
    let mail = try #require(URL(string: "mailto:someone@example.com"))
    #expect(decide(mail.absoluteString, .linkActivated) == .openExternally(mail))
}

@Test func aScriptedRedirectToAWebsiteIsCancelledNotOpened() {
    #expect(decide("https://example.com", .other) == .cancel)
    #expect(decide("http://example.com", .formSubmitted) == .cancel)
}

@Test func everyOtherSchemeIsCancelled() {
    #expect(decide("file:///etc/hosts", .linkActivated) == .cancel)
    #expect(decide("data:text/html,<p>hi</p>", .other) == .cancel)
    #expect(decide("javascript:alert(1)", .linkActivated) == .cancel)
    #expect(decide("about:srcdoc", .other) == .cancel)
    #expect(HTMLDocumentNavigation.decide(url: nil, trigger: .other, isMainFrame: true) == .cancel)
}

@Test func subframesNeverLoad() {
    #expect(decide("about:blank", .other, mainFrame: false) == .cancel)
}

// MARK: - Scripts

@Test func scrollScriptQuotesTheElementID() {
    let script = HTMLDocumentScript.scrollIntoView(elementID: "a\"); alert(1); (\"", animated: false)
    #expect(script.contains(#"getElementById("a\"); alert(1); (\"")"#))
    #expect(script.contains(#"behavior: "auto""#))
    #expect(HTMLDocumentScript.scrollIntoView(elementID: "mix", animated: true).contains(#"behavior: "smooth""#))
}

@Test func lineSeparatorsAreEscapedInScriptLiterals() {
    let literal = HTMLDocumentScript.javaScriptStringLiteral("a\u{2028}b\nc")
    // Built with escapes so the source file never holds a raw U+2028.
    #expect(literal == "\"a" + "\\u2028" + "b" + "\\n" + "c\"")
}

@Test func restoringANonFiniteScrollPositionGoesToTheTop() {
    #expect(HTMLDocumentScript.scroll(toY: .nan) == "window.scrollTo(0, 0.0);")
    #expect(HTMLDocumentScript.scroll(toY: -40) == "window.scrollTo(0, 0.0);")
    #expect(HTMLDocumentScript.scroll(toY: 812.5) == "window.scrollTo(0, 812.5);")
}

// MARK: - Temporary files

@Test func fileNamesLoseSlashesColonsAndLeadingDots() {
    #expect(HTMLDocumentExport.sanitizedFileName("September 2026 Report.html") == "September 2026 Report.html")
    #expect(HTMLDocumentExport.sanitizedFileName("9/2026: Report.pdf") == "9-2026- Report.pdf")
    #expect(HTMLDocumentExport.sanitizedFileName("..hidden.html") == "hidden.html")
    #expect(HTMLDocumentExport.sanitizedFileName("  ") == "Document")
}

@MainActor
@Test func aTemporaryFileKeepsItsNameAndContents() throws {
    let first = try HTMLDocumentExport.writeTemporaryFile(named: "September 2026 Report.html", contents: "<p>one</p>")
    let second = try HTMLDocumentExport.writeTemporaryFile(named: "September 2026 Report.html", contents: "<p>two</p>")
    defer {
        try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
    }
    #expect(first.lastPathComponent == "September 2026 Report.html")
    #expect(first != second, "Sharing the same report twice mustn't overwrite the file being shared")
    #expect(try String(contentsOf: first, encoding: .utf8) == "<p>one</p>")
    #expect(try String(contentsOf: second, encoding: .utf8) == "<p>two</p>")
}

// MARK: - PDF

/// Runs real WebKit print layout. It is here because the Mac's version once
/// passed every build and then killed the process at the end of each export:
/// AppKit calls the print operation's completion selector on a thread of its
/// own, and a main-actor delegate trapped there.
@MainActor
@Test func aLongDocumentBecomesSeveralLetterPages() async throws {
    var body = """
    <style>
      body { font: 14px -apple-system, sans-serif; }
      .card { border: 1px solid #ccc; padding: 12px; margin: 8px 0; break-inside: avoid; }
    </style>
    <h1>Report</h1>
    """
    for card in 1...80 {
        body += "<div class=card>Card \(card): enough text to wrap across the line and make the document long.</div>"
    }
    let data = try await HTMLDocumentExport.pdf(html: "<!doctype html><html><body>\(body)</body></html>")

    let provider = try #require(CGDataProvider(data: data as CFData))
    let document = try #require(CGPDFDocument(provider))
    #expect(document.numberOfPages > 1, "Fell back to one tall page: pagination produced nothing")
    let page = try #require(document.page(at: 1))
    #expect(page.getBoxRect(.mediaBox).size == HTMLDocumentExport.pageSize)
}
