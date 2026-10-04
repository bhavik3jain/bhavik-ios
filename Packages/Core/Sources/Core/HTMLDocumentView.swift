import SwiftUI
import WebKit

/// Shows a self-contained HTML document the app generated — Finance's month
/// report — inside the app.
///
/// A `WKWebView` wrapper, not iOS 26's SwiftUI `WebView`: the app deploys to
/// iOS 18 and macOS 15. Not `SafariView` / `WebPage` either: those open a URL,
/// and this document has no URL — it's a string built on the device from the
/// household's figures, and it must never be fetched from or posted anywhere.
///
/// - The page is loaded with no base URL into a non-persistent data store, so
///   it has no origin to reach and leaves no cookies or caches behind.
/// - Navigation is limited to the initial load and in-page `#anchor` jumps
///   (`HTMLDocumentNavigation`); a tapped web link opens in the system
///   browser, and anything else is cancelled.
/// - The view itself paints nothing until the page has loaded, so the page's
///   own background shows — light or dark per its `prefers-color-scheme`,
///   which follows the app's appearance — with no white flash first.
/// - Text selection works as in any web page.
/// - When `html` changes the page is reloaded in place and put back at the
///   same scroll position.
///
/// Set `scrollTarget` to an element id to scroll that element to the top; the
/// view sets it back to `nil` once it has tried, so setting the same id again
/// scrolls again. An id set before the page has finished loading is applied
/// as soon as it has. A page that wants its headings clear of a translucent
/// bar should give them `scroll-margin-top`.
///
/// No network requests are blocked at the resource level — the navigation
/// policy only governs page loads — so the HTML is expected to be
/// self-contained (inline CSS and SVG, no external images or fonts), which a
/// generated report is anyway.
public struct HTMLDocumentView: View {
    private let html: String
    @Binding private var scrollTarget: String?

    public init(html: String, scrollTarget: Binding<String?> = .constant(nil)) {
        self.html = html
        _scrollTarget = scrollTarget
    }

    public var body: some View {
        HTMLWebViewRepresentable(html: html, scrollTarget: $scrollTarget)
    }
}

// MARK: - Web view configuration shared with the exporter

@MainActor
enum HTMLWebViewFactory {
    /// A web view set up the way every generated document is shown or
    /// exported: no persistent storage, no link previews, no back/forward
    /// gestures.
    static func makeWebView(frame: CGRect = .zero) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true
        #if os(iOS)
        configuration.dataDetectorTypes = []
        #endif

        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        // A long-press preview would load the linked website inside the app,
        // which is exactly what the navigation policy is there to prevent.
        webView.allowsLinkPreview = false
        return webView
    }

    /// Maps WebKit's navigation type onto the policy's.
    static func trigger(for type: WKNavigationType) -> HTMLDocumentNavigation.Trigger {
        switch type {
        case .linkActivated: .linkActivated
        case .formSubmitted, .formResubmitted: .formSubmitted
        case .reload: .reload
        case .backForward: .backForward
        case .other: .other
        @unknown default: .other
        }
    }
}

// MARK: - Coordinator

/// Owns the web view's delegate duties on both platforms; the representables
/// below only create the view and forward SwiftUI updates.
@MainActor
final class HTMLDocumentCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    var scrollTarget: Binding<String?>
    var openURL: OpenURLAction
    var reduceMotion = false

    private weak var webView: WKWebView?
    private var loadedHTML: String?
    private var isLoaded = false
    /// Bumped on every load, so a scroll-position read that comes back after a
    /// newer load started is dropped instead of loading a stale string.
    private var generation = 0
    private var restoreY: Double?
    private var pendingTarget: String?
    /// The binding's value last time it was seen, so the updates SwiftUI
    /// sends before the binding has been cleared don't scroll again.
    private var deliveredTarget: String?

    init(scrollTarget: Binding<String?>, openURL: OpenURLAction) {
        self.scrollTarget = scrollTarget
        self.openURL = openURL
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    // MARK: Updates from SwiftUI

    func update(html: String, target: String?) {
        if html != loadedHTML {
            load(html)
        }
        guard target != deliveredTarget else { return }
        deliveredTarget = target
        if let target {
            pendingTarget = target
            // Clear the binding outside the view update that delivered it —
            // writing state during an update is undefined behaviour in
            // SwiftUI and logs a runtime warning.
            let binding = scrollTarget
            Task { @MainActor in
                if binding.wrappedValue == target { binding.wrappedValue = nil }
            }
            if isLoaded { applyPendingTarget() }
        }
    }

    private func load(_ html: String) {
        guard let webView else { return }
        let firstLoad = loadedHTML == nil
        loadedHTML = html
        generation += 1
        let thisLoad = generation

        guard !firstLoad, isLoaded else {
            isLoaded = false
            webView.loadHTMLString(html, baseURL: nil)
            return
        }
        // Reloading resets the page to the top; read where the reader was so
        // switching "Include Table Views" or the owner doesn't throw them back
        // to the header.
        webView.evaluateJavaScript(HTMLDocumentScript.scrollPosition) { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == thisLoad, let webView = self.webView else { return }
                self.restoreY = (value as? NSNumber)?.doubleValue
                self.isLoaded = false
                webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    private func applyPendingTarget() {
        guard let target = pendingTarget, let webView else { return }
        pendingTarget = nil
        webView.evaluateJavaScript(
            HTMLDocumentScript.scrollIntoView(elementID: target, animated: !reduceMotion),
            completionHandler: nil
        )
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let decision = HTMLDocumentNavigation.decide(
            url: navigationAction.request.url,
            trigger: HTMLWebViewFactory.trigger(for: navigationAction.navigationType),
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true
        )
        switch decision {
        case .allow:
            decisionHandler(.allow)
        case .openExternally(let url):
            decisionHandler(.cancel)
            openURL(url)
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        webView.revealAfterFirstLoad()
        if let y = restoreY {
            restoreY = nil
            webView.evaluateJavaScript(HTMLDocumentScript.scroll(toY: y), completionHandler: nil)
        }
        applyPendingTarget()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Show whatever did render rather than leaving the Mac's view
        // invisible forever.
        webView.revealAfterFirstLoad()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page's process was killed (memory pressure, usually while the
        // app was in the background). Without this the view stays blank until
        // the HTML changes; load the same string again.
        guard let html = loadedHTML else { return }
        isLoaded = false
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: WKUIDelegate

    /// A `target="_blank"` link, or the Mac's "Open Link in New Window". There
    /// is never a second window; a web link goes to the system browser.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if case .openExternally(let url) = HTMLDocumentNavigation.decide(
            url: navigationAction.request.url,
            trigger: .linkActivated,
            isMainFrame: true
        ) {
            openURL(url)
        }
        return nil
    }
}

// MARK: - Platform views

#if os(iOS)
private struct HTMLWebViewRepresentable: UIViewRepresentable {
    let html: String
    @Binding var scrollTarget: String?

    func makeCoordinator() -> HTMLDocumentCoordinator {
        HTMLDocumentCoordinator(scrollTarget: $scrollTarget, openURL: OpenURLAction { _ in .systemAction })
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = HTMLWebViewFactory.makeWebView()
        // Clear until the page paints its own background; an opaque web view
        // flashes white before the first load, which is glaring in dark mode.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.attach(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.scrollTarget = $scrollTarget
        coordinator.openURL = context.environment.openURL
        coordinator.reduceMotion = context.environment.accessibilityReduceMotion
        coordinator.update(html: html, target: scrollTarget)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: HTMLDocumentCoordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }
}

private extension WKWebView {
    /// Nothing to do on iOS: the view is transparent from the start.
    func revealAfterFirstLoad() {}
}
#elseif os(macOS)
private struct HTMLWebViewRepresentable: NSViewRepresentable {
    let html: String
    @Binding var scrollTarget: String?

    func makeCoordinator() -> HTMLDocumentCoordinator {
        HTMLDocumentCoordinator(scrollTarget: $scrollTarget, openURL: OpenURLAction { _ in .systemAction })
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = HTMLWebViewFactory.makeWebView()
        // AppKit's WKWebView has no public way to stop drawing its white
        // background, so it stays invisible until the page has painted its own
        // (`revealAfterFirstLoad`), and the window shows through meanwhile.
        webView.alphaValue = 0
        webView.underPageBackgroundColor = .clear
        context.coordinator.attach(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.scrollTarget = $scrollTarget
        coordinator.openURL = context.environment.openURL
        coordinator.reduceMotion = context.environment.accessibilityReduceMotion
        coordinator.update(html: html, target: scrollTarget)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: HTMLDocumentCoordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }
}

private extension WKWebView {
    func revealAfterFirstLoad() {
        if alphaValue < 1 { alphaValue = 1 }
    }
}
#endif
