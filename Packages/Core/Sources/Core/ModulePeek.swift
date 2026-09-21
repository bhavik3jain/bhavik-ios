import SwiftUI

/// The card a module shows when its row on the home screen is long-pressed.
///
/// Every module draws its own content, but the frame is shared here so the four
/// peeks read as one feature rather than four. The card is a context-menu
/// preview, which never forwards taps — so nothing inside may be interactive,
/// and on a Mac, where previews are not shown at all, every action has to live
/// in the menu beneath it.
public struct ModulePeekCard<Content: View>: View {
    let accent: ModuleAccent
    let icon: String
    let subtitle: String
    let content: Content

    public init(accent: ModuleAccent, icon: String, subtitle: String = "", @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.icon = icon
        self.subtitle = subtitle
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(accent.color, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(accent.name)
                        .font(.headline)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }
}

/// One line inside a peek: a leading label block and an optional trailing value.
public struct PeekRow: View {
    let title: String
    let detail: String
    let value: String
    let tint: Color?

    public init(_ title: String, detail: String = "", value: String = "", tint: Color? = nil) {
        self.title = title
        self.detail = detail
        self.value = value
        self.tint = tint
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !value.isEmpty {
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                    .lineLimit(1)
            }
        }
    }
}

/// The quiet line a peek shows when there is nothing to report.
public struct PeekEmpty: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}
