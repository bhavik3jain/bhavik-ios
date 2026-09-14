#if os(iOS)
import SafariServices
#endif
import SwiftUI

#if os(iOS)
/// Opens a web page inside the app.
///
/// `SFSafariViewController` rather than a bare web view: it brings Safari's
/// reader, sharing and cookie jar with it, so a carrier's tracking page behaves
/// the way it would in Safari without pushing the reader out of the app.
public struct SafariView: UIViewControllerRepresentable {
    private let url: URL
    private let tint: Color

    public init(url: URL, tint: Color = .accentColor) {
        self.url = url
        self.tint = tint
    }

    public func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = true

        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.preferredControlTintColor = UIColor(tint)
        controller.dismissButtonStyle = .close
        return controller
    }

    public func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif

/// A URL that can be presented as a sheet.
public struct WebPage: Identifiable {
    public let url: URL
    public var id: URL { url }

    public init(url: URL) {
        self.url = url
    }
}

#if !os(iOS)
/// Hands the page to the user's default browser.
///
/// A sheet is the right shape on a phone, where leaving the app is a context
/// switch. On a Mac the browser is already one window away and carries the
/// user's session and extensions, so a cramped embedded web view would be a
/// downgrade rather than a convenience.
private struct ExternalBrowserOpener: ViewModifier {
    @Binding var page: WebPage?
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.onChange(of: page?.url) { _, url in
            guard let url else { return }
            openURL(url)
            // Clear the binding straight away: nothing is presented, so the
            // caller would otherwise be stuck holding a page that can never
            // be dismissed.
            page = nil
        }
    }
}
#endif

public extension View {
    /// Presents a page in an in-app browser, or in the default browser on
    /// platforms that have no in-app one.
    func webSheet(_ page: Binding<WebPage?>, tint: Color = .accentColor) -> some View {
        #if os(iOS)
        sheet(item: page) { page in
            SafariView(url: page.url, tint: tint)
                .ignoresSafeArea()
        }
        #else
        modifier(ExternalBrowserOpener(page: page))
        #endif
    }
}
