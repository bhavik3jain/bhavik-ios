import SwiftUI

/// One tracker's card on the Mac's Overview: the icon tile and name, then
/// whatever the module has to say.
///
/// The frame is shared here, as `ModulePeekCard`'s is, so eight cards drawn by
/// eight packages read as one dashboard. Unlike a peek it is a real button —
/// the whole card opens its tracker — so anything inside that wants a click
/// of its own (Trips' nearby-ideas tile) has to be a button itself.
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ModuleIconTile(color: accent.color, symbol: icon, size: 24)
                    Text(accent.name)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background, in: shape)
            .overlay(shape.strokeBorder(.separator.opacity(0.7)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(accent.name)")
    }
}

/// The headline number on an Overview card: "30.9 mpg", "3 episodes ready".
public struct OverviewValue: View {
    let value: String
    let unit: String

    public init(_ value: String, unit: String = "") {
        self.value = value
        self.unit = unit
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
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
