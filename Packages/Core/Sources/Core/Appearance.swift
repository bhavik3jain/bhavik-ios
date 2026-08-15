import SwiftUI

/// Light or dark, or whatever the device is set to.
public enum Appearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Nil follows the device, which is what `preferredColorScheme` expects.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    public static let defaultsKey = "appearance"

    /// Reads a stored value, falling back to following the device for anything
    /// unrecognised — including the empty string a fresh install starts with.
    public static func stored(_ raw: String) -> Appearance {
        Appearance(rawValue: raw) ?? .system
    }
}
