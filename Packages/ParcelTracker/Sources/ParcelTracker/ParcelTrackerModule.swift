import SwiftData
import SwiftUI
import Core

public enum ParcelTrackerModule {
    public static let accent = ModuleAccent(name: "Orders", color: Color(red: 0.90, green: 0.49, blue: 0.13))

    /// Carrier credentials live in user defaults rather than the source tree,
    /// so they never reach version control.
    public static let fedExKeyDefaultsKey = "fedex.apiKey"
    public static let fedExSecretDefaultsKey = "fedex.apiSecret"

    public static var models: [any PersistentModel.Type] {
        [Parcel.self, ParcelEvent.self]
    }

    @MainActor
    public static func rootView() -> some View {
        ParcelRootView()
    }
}
