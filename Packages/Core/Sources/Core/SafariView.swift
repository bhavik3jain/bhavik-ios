import SafariServices
import SwiftUI

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

/// A URL that can be presented as a sheet.
public struct WebPage: Identifiable {
    public let url: URL
    public var id: URL { url }

    public init(url: URL) {
        self.url = url
    }
}

public extension View {
    /// Presents a page in an in-app browser.
    func webSheet(_ page: Binding<WebPage?>, tint: Color = .accentColor) -> some View {
        sheet(item: page) { page in
            SafariView(url: page.url, tint: tint)
                .ignoresSafeArea()
        }
    }
}
