#if os(iOS)
import Core
import SwiftUI

/// The hub on a wide screen — the open iPhone Duo's inner display, regular
/// width both ways: the Mac Overview's live cards in a grid instead of the
/// phone's list, which stretched eight one-line rows across 950pt with each
/// chevron a hand-span from its name.
///
/// The cards are the modules' own `overviewCard(…)`, fed by HomeView's
/// queries and laid out by `OverviewCardRows`; HomeView picks this or the
/// list by size class, so folding the phone shut puts the list back.
struct HubDashboard<Card: View, MenuItems: View>: View {
    let modules: [SelectedModule]
    /// Whether a module's card needs the taller row as of the given moment.
    let isTall: (SelectedModule, Date) -> Bool
    @ViewBuilder let card: (SelectedModule, Date) -> Card
    /// A card's long-press menu: the list row's, so Fuel's cars and Finance's
    /// Add Transaction are still a press away.
    @ViewBuilder let menu: (SelectedModule) -> MenuItems

    var body: some View {
        // Re-read once a minute, as the Mac's Overview is: the cards read
        // `.now` only when a query changed.
        TimelineView(.everyMinute) { context in
            GeometryReader { proxy in
                ScrollView {
                    OverviewCardRows(width: proxy.size.width, modules: modules, now: context.date, isTall: isTall) { module, now in
                        card(module, now)
                            // The grouped cell colour, which the card's own
                            // `.background` resolves to: the plain background
                            // drew pure black cards on the black page in dark
                            // mode, outlined by nothing but their hairline.
                            .backgroundStyle(Color(.secondarySystemGroupedBackground))
                            // Lifted off the wash behind them; on the Mac they
                            // sit flat on the window.
                            .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
                            .contextMenu { menu(module) }
                    }
                }
            }
            .background { HubBackdrop(colors: modules.map(\.accent.color)) }
            .hubSubtitle(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        }
    }
}

/// A wash of the visible trackers' own colours behind the cards, fading out
/// two thirds of the way down so the lower rows sit on plain grouped grey.
private struct HubBackdrop: View {
    let colors: [Color]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            if !colors.isEmpty {
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: [
                        [0, 0], [0.5, 0], [1, 0],
                        [0, 0.5], [0.62, 0.42], [1, 0.5],
                        [0, 1], [0.5, 1], [1, 1],
                    ],
                    colors: (0..<9).map { colors[$0 % colors.count] }
                )
                .opacity(colorScheme == .dark ? 0.32 : 0.42)
                .mask {
                    LinearGradient(
                        stops: [.init(color: .black, location: 0), .init(color: .clear, location: 0.68)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        }
        .ignoresSafeArea()
    }
}

private extension View {
    /// Today's date under "Trackers", where the system has a subtitle line.
    @ViewBuilder
    func hubSubtitle(_ text: String) -> some View {
        if #available(iOS 26, *) {
            navigationSubtitle(text)
        } else {
            self
        }
    }
}
#endif
