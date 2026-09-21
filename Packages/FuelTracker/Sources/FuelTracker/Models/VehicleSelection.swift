import Foundation

/// Which vehicle the module opens on.
public enum VehicleSelection {
    /// The stored vehicle if it still exists, otherwise the most recently
    /// filled one.
    ///
    /// Two defects are recorded here. The module used to fall back to
    /// `vehicles.first` — creation order, which for an imported garage is the
    /// order the names appeared in the Fuelly CSV — so it opened on whichever
    /// car happened to be typed first rather than the one being driven. And the
    /// choice lived in `@State` on a view rebuilt by `fullScreenCover`, so
    /// picking a car and going back to the hub threw the choice away: it reset
    /// on every *open*, not merely every launch.
    ///
    /// `summaries` is expected in `VehicleSummary.fleet` order, which is most
    /// recently filled first, so the fallback is simply the first element.
    public static func resolve(storedName: String?, among summaries: [VehicleSummary]) -> VehicleSummary? {
        if let storedName, let match = summaries.first(where: { $0.name == storedName }) {
            return match
        }
        return summaries.first
    }
}
