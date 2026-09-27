import SwiftUI

/// The way back to the hub from inside a module.
///
/// Modules are presented as full-screen covers, which carry no dismiss control
/// of their own, so each one puts a Home tab alongside its own tabs. Selecting
/// it closes the module rather than showing a screen, which is why it needs the
/// handling below rather than being an ordinary tab.
public enum ModuleTab {
    /// The value the Home tab carries. Unlikely to collide with a module's own
    /// tab names.
    public static let home = "module.home"
}

/// One of a module's own screens: a tab on iOS, a row nested under the
/// tracker in the Mac sidebar.
///
/// Declared once per module (`<Module>TrackerModule.sections`) and read by
/// both, so a tab and its sidebar row can't drift apart in name, symbol or
/// value.
public struct ModuleSection: Identifiable, Hashable, Sendable {
    /// The tab's selection value. Stored nowhere, so renaming one only moves
    /// which screen a module opens on.
    public let id: String
    public let title: String
    public let systemImage: String

    public init(_ id: String, title: String, systemImage: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }
}

/// How a module is being shown, set by whoever embeds it.
///
/// On the phone a module is a full-screen cover with its own tab bar and a
/// Home tab to leave by. On the Mac it sits in a split view's detail pane and
/// the sidebar already lists its sections, so a second row of tabs would be a
/// duplicate way to do the same thing — and its Home tab, whose whole job is
/// dismissing a cover, had nothing to dismiss and just bounced back.
///
/// An environment value rather than `#if os(macOS)` so the feature packages
/// stay free of platform conditionals: they ask how they are being shown, not
/// where they are running.
public enum ModuleLayout: Sendable {
    /// A tab bar with a Home tab — the iPhone and iPad hub.
    case tabs
    /// No tab bar; a sidebar outside the module picks the section. The Mac.
    case sidebar
}

public extension EnvironmentValues {
    /// See `ModuleLayout`. Defaults to `.tabs`, so nothing changes for a
    /// module that is never told otherwise.
    @Entry var moduleLayout: ModuleLayout = .tabs
}

/// A module's root: its sections as tabs behind a Home tab, or — in the
/// sidebar layout — just the selected section, full size.
///
/// Every module's root view goes through this, so the phone's chrome (Home
/// first with empty content, the minimising tab bar, dismissal on Home that
/// restores the module's own first tab) is built in one place and can't be
/// got wrong by a new module. `restoringTo:` is always the first section,
/// never Home, or the module would reopen blank.
public struct ModuleTabView<Content: View>: View {
    @Binding var selection: String
    let sections: [ModuleSection]
    let content: (ModuleSection) -> Content

    @Environment(\.moduleLayout) private var layout

    public init(
        selection: Binding<String>,
        sections: [ModuleSection],
        @ViewBuilder content: @escaping (ModuleSection) -> Content
    ) {
        precondition(!sections.isEmpty, "A module needs at least one section to open on.")
        _selection = selection
        self.sections = sections
        self.content = content
    }

    private var current: ModuleSection {
        sections.first { $0.id == selection } ?? sections[0]
    }

    public var body: some View {
        switch layout {
        case .sidebar:
            content(current)
                // A fresh identity per section, as a tab switch gives each
                // tab its own, so one screen's scroll position and pushed
                // detail don't carry over into the next.
                .id(current.id)
        case .tabs:
            TabView(selection: $selection) {
                Tab("Home", systemImage: "house", value: ModuleTab.home) {
                    Color.clear
                }
                ForEach(sections) { section in
                    Tab(section.title, systemImage: section.systemImage, value: section.id) {
                        content(section)
                    }
                }
            }
            .minimizesTabBarOnScroll()
            .dismissesOnHomeTab($selection, restoringTo: sections[0].id)
        }
    }
}

private struct HomeTabDismissal: ViewModifier {
    @Binding var selection: String
    let fallback: String
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.onChange(of: selection) { _, current in
            guard current == ModuleTab.home else { return }
            // Put the selection back before leaving, so the module opens on its
            // own first tab next time rather than on the Home tab.
            selection = fallback
            dismiss()
        }
    }
}

private struct ModuleSubtitle: ViewModifier {
    let subtitle: String?
    @Environment(\.moduleLayout) private var layout

    func body(content: Content) -> some View {
        if layout == .sidebar, let subtitle, !subtitle.isEmpty, #available(iOS 26, macOS 11, *) {
            content.navigationSubtitle(subtitle)
        } else {
            content
        }
    }
}

public extension View {
    /// Closes the module when its Home tab is selected.
    ///
    /// - Parameters:
    ///   - selection: the `TabView`'s selection.
    ///   - fallback: the tab to restore before leaving.
    func dismissesOnHomeTab(_ selection: Binding<String>, restoringTo fallback: String) -> some View {
        modifier(HomeTabDismissal(selection: selection, fallback: fallback))
    }

    /// The grey line under a screen's title in the Mac's toolbar — "Italy ·
    /// 6–14 Jun · Day 3 of 9". Only in the sidebar layout: iOS 26 draws a
    /// subtitle under the navigation bar's title too, and the phone screens
    /// already say the same thing in their own headers.
    func moduleSubtitle(_ subtitle: String?) -> some View {
        modifier(ModuleSubtitle(subtitle: subtitle))
    }
}
