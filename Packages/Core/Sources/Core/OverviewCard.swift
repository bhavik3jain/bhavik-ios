import SwiftUI

/// One tracker's card on the Mac's Overview: the icon tile and name, then
/// whatever the module has to say.
///
/// The frame is shared here, as `ModulePeekCard`'s is, so eight cards drawn by
/// eight packages read as one dashboard. Unlike a peek it is a real button —
/// the whole card opens its tracker — so anything inside that wants a click
/// of its own (Trips' nearby-ideas tile) has to be a button itself.
///
/// Every card reads the same way top to bottom: the header, one headline
/// figure (`OverviewValue`), one grey line saying what it is
/// (`OverviewCaption`), then the module's own picture pinned to the bottom.
/// An empty tracker says so quietly with `OverviewEmptyState` rather than in
/// the headline's 26pt bold.
public struct OverviewCard<Content: View>: View {
    let accent: ModuleAccent
    let icon: String
    let detail: String
    let open: () -> Void
    let content: Content

    public init(
        accent: ModuleAccent,
        icon: String,
        detail: String = "",
        open: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.accent = accent
        self.icon = icon
        self.detail = detail
        self.open = open
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ModuleIconTile(color: accent.color, symbol: icon, size: 24)
                    Text(accent.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                // `minHeight: 0` so the row's height is the card's, whatever
                // the module draws. Without it a card whose content ran long —
                // Fuel with three cars — grew past the row and stood 5pt taller
                // than its neighbours; clipped, it stays in line.
                content
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .background(.background, in: shape)
            .overlay(shape.strokeBorder(.separator.opacity(0.7)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(accent.name)")
    }
}

/// The headline number on an Overview card: "30.9 mpg", "582 episodes ready".
/// The figure in the value, the words in the unit, so every card's number
/// sits at the same size on the same baseline.
public struct OverviewValue: View {
    let value: String
    let unit: String

    public init(_ value: String, unit: String = "") {
        self.value = value
        self.unit = unit
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(.system(size: 26, weight: .bold))
                .monospacedDigit()
                .tracking(-0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The grey line under a card's headline: what the number is, or the one
/// fact beside it. One line, truncated at the end.
public struct OverviewCaption: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// A short coloured line at the foot of a card — "↗ +$1,204 since August",
/// "2 accounts expiring soon".
public struct OverviewFootnote: View {
    let text: String
    let symbol: String?
    let tint: Color

    public init(_ text: String, symbol: String? = nil, tint: Color) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(tint)
    }
}

/// What an empty tracker's card says: a plain title and a hint at how to
/// start. The headline style shouted "No months yet" at the size of a net
/// worth, so the emptiest card on the Overview was the loudest.
public struct OverviewEmptyState: View {
    let title: String
    let message: String

    public init(_ title: String, message: String = "") {
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }
}

/// A tracker's symbol, white on its accent in a rounded square — the Mac
/// sidebar's 22pt tile and the Overview's 24pt one.
public struct ModuleIconTile: View {
    let color: Color
    let symbol: String
    let size: CGFloat

    public init(color: Color, symbol: String, size: CGFloat = 22) {
        self.color = color
        self.symbol = symbol
        self.size = size
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}
