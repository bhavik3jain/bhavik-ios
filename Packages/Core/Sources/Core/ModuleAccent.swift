import SwiftUI

/// Identifies a sub-app module and its distinguishing accent color, used
/// consistently across the home hub and the module's own screens.
public struct ModuleAccent: Sendable {
    public let name: String
    public let color: Color

    public init(name: String, color: Color) {
        self.name = name
        self.color = color
    }
}
