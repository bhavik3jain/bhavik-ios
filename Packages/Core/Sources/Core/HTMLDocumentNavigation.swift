import Foundation

/// What `HTMLDocumentView` lets a generated page do, decided without WebKit so
/// it can be tested.
///
/// The documents shown this way (Finance's month report) are built from the
/// household's own figures and loaded as a string with no base URL, so the
/// page's address is `about:blank` and an in-page link resolves to
/// `about:blank#section`. Nothing else is ever a legitimate destination inside
/// the view: a website loaded in place of the report would leave the reader in
/// a chromeless browser with no way back to the figures, and a `data:` or
/// `file:` URL is the classic way a page escapes its sandbox. So the view
/// allows its own load and in-page jumps, hands a tapped web link to the
/// system browser, and cancels everything else.
public enum HTMLDocumentNavigation {
    /// What started a navigation — `WKNavigationType`, minus WebKit.
    public enum Trigger: Sendable, Equatable {
        /// The reader tapped or clicked a link.
        case linkActivated
        /// A form was submitted or resubmitted.
        case formSubmitted
        /// The view's own reload, or the web view's context-menu Reload.
        case reload
        /// Back or forward through the web view's history.
        case backForward
        /// Anything else: the view's own `loadHTMLString`, or a script setting
        /// `location`.
        case other
    }

    public enum Decision: Sendable, Equatable {
        case allow
        /// Cancel it here and open the URL in the system browser (or mail, or
        /// the phone) instead.
        case openExternally(URL)
        case cancel
    }

    /// Schemes a tapped link may hand to the system. Only ever on a tap: a
    /// script redirecting the page must not be able to open a browser window.
    static let externalSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    public static func decide(url: URL?, trigger: Trigger, isMainFrame: Bool) -> Decision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }

        if scheme == "about" {
            // Only the document itself, in the main frame. An `about:srcdoc`
            // or blank subframe has no business in a report.
            guard isMainFrame, isBlankDocument(url) else { return .cancel }
            switch trigger {
            case .other:
                // The view's own load (no fragment), or a script moving to an
                // anchor (`location.hash = …`).
                return .allow
            case .linkActivated:
                // `<a href="#mix">` arrives as `about:blank#mix`. A tap on a
                // bare `about:blank` (an `href=""`) would replace the report
                // with an empty page, so only a jump to an anchor is allowed.
                return url.fragment == nil ? .cancel : .allow
            case .reload, .backForward, .formSubmitted:
                // Reloading `about:blank` — the Mac's context-menu Reload —
                // can come back as an empty page rather than the string that
                // was loaded; history entries only point at older copies of
                // the report. The view reloads by loading the string again.
                return .cancel
            }
        }

        if externalSchemes.contains(scheme) {
            return trigger == .linkActivated ? .openExternally(url) : .cancel
        }
        return .cancel
    }

    /// `about:blank`, with or without a fragment.
    private static func isBlankDocument(_ url: URL) -> Bool {
        let address = url.absoluteString.lowercased()
        return address == "about:blank" || address.hasPrefix("about:blank#")
    }
}

/// The scripts `HTMLDocumentView` runs in its page, as strings so the escaping
/// can be tested.
enum HTMLDocumentScript {
    /// Scrolls the element with this `id` to the top of the view. Evaluates to
    /// `true` if it was found.
    ///
    /// The id is written as a JSON string literal, never spliced in raw: a
    /// section id is a developer's constant today, but a quote or a newline in
    /// one would otherwise be a script error at best and script injection at
    /// worst.
    static func scrollIntoView(elementID: String, animated: Bool) -> String {
        let behavior = animated ? "smooth" : "auto"
        return """
        (function () {
          var element = document.getElementById(\(javaScriptStringLiteral(elementID)));
          if (!element) { return false; }
          element.scrollIntoView({ behavior: "\(behavior)", block: "start" });
          return true;
        })();
        """
    }

    /// Reads the vertical scroll position before a reload.
    static let scrollPosition = "window.scrollY"

    /// Puts the scroll position back after a reload.
    static func scroll(toY y: Double) -> String {
        // `y` came back from the page; a non-finite value would print as
        // `nan` and be a script error.
        let safe = y.isFinite ? max(0, y) : 0
        return "window.scrollTo(0, \(safe));"
    }

    static func javaScriptStringLiteral(_ text: String) -> String {
        // A JSON string is a valid JavaScript string literal. `.fragmentsAllowed`
        // lets a bare string be the top-level value.
        guard
            let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
            let literal = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        // U+2028/U+2029 are legal in JSON but ended a string literal in
        // JavaScript before ES2019; escaping them costs nothing.
        return literal
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
