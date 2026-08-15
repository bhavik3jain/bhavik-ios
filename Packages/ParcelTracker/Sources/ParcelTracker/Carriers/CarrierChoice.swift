import Foundation

/// Which carrier an entry screen should show.
///
/// The carrier follows the tracking number as it is typed, until the reader
/// picks one themselves — after which their choice sticks. Holding that as a
/// derived value rather than a "has edited" flag matters: SwiftUI writes
/// through a Picker's binding during layout as well as on a real tap, and a
/// flag set by that write silently stops detection for the rest of the screen.
public struct CarrierChoice: Equatable, Sendable {
    private var manual: Carrier?

    public init(manual: Carrier? = nil) {
        self.manual = manual
    }

    public var isManual: Bool { manual != nil }

    public func resolved(for trackingNumber: String) -> Carrier {
        manual ?? CarrierDetector.detect(trackingNumber).carrier
    }

    /// Records a carrier the reader picked.
    ///
    /// A write matching what is already shown is ignored: choosing the value
    /// already on screen changes nothing, so it is indistinguishable from the
    /// echo SwiftUI sends back through the binding.
    public mutating func choose(_ carrier: Carrier, whileShowing shown: Carrier) {
        guard carrier != shown else { return }
        manual = carrier
    }
}
