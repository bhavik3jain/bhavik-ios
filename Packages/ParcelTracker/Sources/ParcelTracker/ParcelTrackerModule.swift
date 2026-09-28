import SwiftData
import SwiftUI
import Core

public enum ParcelTrackerModule {
    public static let accent = ModuleAccent(name: "Orders", color: Color(red: 0.90, green: 0.49, blue: 0.13))

    /// The white-on-accent symbol on the hub row, the Mac sidebar tile and
    /// its Overview card.
    public static let symbolName = "shippingbox.fill"

    /// Its tabs on the phone and, in the same order, the rows nested under it
    /// in the Mac sidebar. The first is where the module opens.
    public static let sections = [
        ModuleSection("parcels", title: "Orders", systemImage: "shippingbox"),
        ModuleSection("settings", title: "Settings", systemImage: "gear", isSettings: true),
    ]

    /// Carrier credentials live in user defaults rather than the source tree,
    /// so they never reach version control.
    public static let fedExKeyDefaultsKey = "fedex.apiKey"
    public static let fedExSecretDefaultsKey = "fedex.apiSecret"

    public static var models: [any PersistentModel.Type] {
        [Parcel.self, ParcelEvent.self]
    }

    /// `section` is the Mac sidebar's selection, which picks the section in
    /// place of a tab bar; leave it nil on the phone.
    @MainActor
    /// Orders' settings on their own, for the Mac's Settings window — see
    /// `ModuleSection.isSettings`.
    public static func settingsView() -> some View {
        ParcelSettingsView()
            .tint(accent.color)
    }

    public static func rootView(section: Binding<String>? = nil) -> some View {
        ParcelRootView(section: section)
    }
}
