import Foundation
import WebKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Why exporting or printing a generated document failed.
public enum HTMLDocumentExportError: Error, Equatable, Sendable {
    /// WebKit couldn't load the HTML (or its page process died while it did).
    case loadFailed
    /// The page never finished loading.
    case timedOut
    /// The page loaded but produced no PDF.
    case renderFailed
}

/// Turns a generated HTML document into the things a Share or ••• menu offers:
/// a PDF, a temporary `.html`/`.pdf` file for `ShareLink`, and a print job.
///
/// Every operation loads the HTML into its own offscreen web view, configured
/// like `HTMLDocumentView`'s (no base URL, nothing persisted, the same
/// navigation policy), so an export never depends on a view being on screen.
///
/// PDFs and print jobs are rendered **light**, whatever the app's appearance:
/// a dark report on paper is a page of black ink, and a PDF sent to someone
/// else shouldn't depend on the sender's settings. They use print media, so a
/// page's `@media print` rules apply, and backgrounds and fills only print
/// where the page asks for `print-color-adjust: exact`.
@MainActor
public enum HTMLDocumentExport {
    /// US Letter, in points.
    nonisolated public static let pageSize = CGSize(width: 612, height: 792)
    /// Half an inch all round.
    nonisolated public static let pageMargin: CGFloat = 36

    /// How long a load may take before giving up. A generated report is a
    /// few hundred kilobytes of inline markup and loads in well under a
    /// second; this only stops a wedged page process from hanging the menu.
    static let loadTimeout: Duration = .seconds(20)

    nonisolated static var printableWidth: CGFloat { pageSize.width - pageMargin * 2 }

    // MARK: - PDF

    /// The document as a paginated US Letter PDF, split where WebKit's print
    /// layout splits it (so `break-inside: avoid` on a card keeps it whole).
    ///
    /// If pagination produces nothing — it shouldn't, but it goes through
    /// print machinery whose failures are silent — this falls back to
    /// `WKWebView.createPDF`'s single page as tall as the document, which is
    /// still a faithful copy, just not one that prints well.
    public static func pdf(html: String) async throws -> Data {
        let loader = OffscreenHTMLLoader()
        try await loader.load(html)
        if let paged = await loader.paginatedPDF(), !paged.isEmpty {
            return paged
        }
        return try await loader.singlePagePDF()
    }

    // MARK: - Temporary files

    /// Writes `contents` to a fresh temporary file called `name`, for
    /// `ShareLink` or a share sheet, and returns its URL.
    ///
    /// Each file gets its own folder so the name the recipient sees stays
    /// exactly `name` ("September 2026 Report.html") even when the same
    /// report is shared twice. Folders from earlier exports are cleared once
    /// they're an hour old — long enough for any share sheet to have
    /// finished reading them.
    public static func writeTemporaryFile(named name: String, contents: String) throws -> URL {
        try writeTemporaryFile(named: name, data: Data(contents.utf8))
    }

    /// `writeTemporaryFile(named:contents:)` for bytes — a PDF.
    public static func writeTemporaryFile(named name: String, data: Data) throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("HTMLDocumentExport", isDirectory: true)
        removeStaleExports(in: root)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(sanitizedFileName(name), isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// `name` made safe to use as a single path component: no slashes or
    /// colons (a month title like "9/2026" would otherwise become folders),
    /// no leading dot (a hidden file a share sheet won't show), never empty.
    nonisolated static func sanitizedFileName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.newlines)
        var cleaned = name.unicodeScalars
            .map { forbidden.contains($0) ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "Document" : cleaned
    }

    private static func removeStaleExports(in root: URL) {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        let cutoff = Date.now.addingTimeInterval(-3_600)
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? fileManager.removeItem(at: folder) }
        }
    }

    // MARK: - Printing

    /// Shows the system print dialog for the document. Returns whether a job
    /// was sent (false when the reader cancelled).
    ///
    /// On iOS it's `UIPrintInteractionController` with the web view's own
    /// print formatter; on the Mac, the web view's `NSPrintOperation` as a
    /// sheet on the key window.
    @discardableResult
    public static func print(html: String, jobName: String) async throws -> Bool {
        let loader = OffscreenHTMLLoader()
        try await loader.load(html)
        return await loader.presentPrintDialog(jobName: jobName)
    }
}

// MARK: - Offscreen loader

/// One offscreen web view, loaded once, and the platform's ways of turning it
/// into paper.
@MainActor
private final class OffscreenHTMLLoader: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?
    #if os(macOS)
    /// AppKit's print operation renders a view that's in a window; this one
    /// is never shown.
    private let window: NSWindow
    #endif

    override init() {
        let frame = CGRect(
            x: 0, y: 0,
            width: HTMLDocumentExport.printableWidth,
            height: HTMLDocumentExport.pageSize.height
        )
        webView = HTMLWebViewFactory.makeWebView(frame: frame)
        #if os(iOS)
        webView.overrideUserInterfaceStyle = .light
        #elseif os(macOS)
        webView.appearance = NSAppearance(named: .aqua)
        window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        #endif
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ html: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: HTMLDocumentExport.loadTimeout)
                self?.finish(.failure(HTMLDocumentExportError.timedOut))
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // Same policy as the on-screen view, except nothing is ever opened:
        // a script in an exported page has no reader to have tapped anything.
        let decision = HTMLDocumentNavigation.decide(
            url: navigationAction.request.url,
            trigger: HTMLWebViewFactory.trigger(for: navigationAction.navigationType),
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true
        )
        decisionHandler(decision == .allow ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(HTMLDocumentExportError.loadFailed))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(HTMLDocumentExportError.loadFailed))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(HTMLDocumentExportError.loadFailed))
    }

    // MARK: Single-page PDF

    func singlePagePDF() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                switch result {
                case .success(let data) where !data.isEmpty: continuation.resume(returning: data)
                default: continuation.resume(throwing: HTMLDocumentExportError.renderFailed)
                }
            }
        }
    }

    // MARK: Paginated PDF and printing

    #if os(iOS)
    func paginatedPDF() async -> Data? {
        let renderer = LetterPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        let paper = renderer.paperRect
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, nil)
        let pages = renderer.numberOfPages
        if pages > 0 {
            renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
            for page in 0..<pages {
                UIGraphicsBeginPDFPage()
                renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
            }
        }
        UIGraphicsEndPDFContext()
        return pages > 0 ? data as Data : nil
    }

    func presentPrintDialog(jobName: String) async -> Bool {
        let info = UIPrintInfo.printInfo()
        info.jobName = jobName
        info.outputType = .general
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = webView.viewPrintFormatter()
        // `self` (and with it the web view) stays alive until the dialog
        // finishes: the formatter draws from the web view on demand.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            controller.present(animated: true) { _, completed, _ in
                continuation.resume(returning: completed)
            }
        }
    }
    #elseif os(macOS)
    func paginatedPDF() async -> Data? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLDocumentExport-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let info = Self.letterPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard await run(operation, sheetOn: window) else { return nil }
        return try? Data(contentsOf: url)
    }

    func presentPrintDialog(jobName: String) async -> Bool {
        let info = Self.letterPrintInfo()
        let operation = webView.printOperation(with: info)
        operation.jobTitle = jobName
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        guard let host = NSApp.keyWindow ?? NSApp.mainWindow else {
            // No window to attach a sheet to (a menu command with every
            // window closed): an app-modal panel instead. A sheet on the
            // offscreen window would be a print panel nobody can see.
            operation.view?.frame = webView.bounds
            return operation.run()
        }
        return await run(operation, sheetOn: host)
    }

    /// Letter paper with half-inch margins, scaled to fit across and split
    /// down. A fresh copy, never `NSPrintInfo.shared` itself: changing that
    /// would change the next Print in every other part of the app.
    private static func letterPrintInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.paperSize = HTMLDocumentExport.pageSize
        let margin = HTMLDocumentExport.pageMargin
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    /// Runs a web view's print operation the only way that renders it.
    ///
    /// `NSPrintOperation.run()` on a `WKWebView`'s operation produces blank
    /// pages: the printing view it returns has no frame until something lays
    /// it out, and only the document-modal path waits for WebKit to draw.
    private func run(_ operation: NSPrintOperation, sheetOn host: NSWindow) async -> Bool {
        operation.view?.frame = webView.bounds
        let delegate = PrintRunDelegate()
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            delegate.setContinuation(continuation)
            operation.runModal(
                for: host,
                delegate: delegate,
                didRun: #selector(PrintRunDelegate.printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        }
        // AppKit doesn't retain a modal delegate; keep it until it has called back.
        withExtendedLifetime(delegate) {}
        return success
    }
    #endif
}

#if os(iOS)
/// A print renderer fixed to US Letter with half-inch margins. Subclassing is
/// the supported way to set them; the properties are read-only otherwise.
private final class LetterPageRenderer: UIPrintPageRenderer {
    override var paperRect: CGRect {
        CGRect(origin: .zero, size: HTMLDocumentExport.pageSize)
    }

    override var printableRect: CGRect {
        paperRect.insetBy(dx: HTMLDocumentExport.pageMargin, dy: HTMLDocumentExport.pageMargin)
    }
}
#elseif os(macOS)
/// Receives `runModal`'s Objective-C completion selector.
///
/// Not main-actor: with no print panel AppKit finishes the operation on a
/// thread of its own and calls back there. Main-actor isolated, the callback
/// tripped Swift's executor check and killed the app with a trap at the end
/// of every Save as PDF.
private final class PrintRunDelegate: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    func setContinuation(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    @objc nonisolated func printOperationDidRun(
        _ operation: NSPrintOperation,
        success: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: success)
    }
}
#endif
