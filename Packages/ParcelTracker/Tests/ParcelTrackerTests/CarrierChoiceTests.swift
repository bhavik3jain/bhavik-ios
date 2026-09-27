import Foundation
import Testing
@testable import ParcelTracker

@Test func carrierFollowsTheNumberUntilSomeoneChooses() {
    let choice = CarrierChoice()
    #expect(choice.resolved(for: "") == .other)
    #expect(choice.resolved(for: "111111111111") == .fedex)
    #expect(choice.resolved(for: "1ZR0Y0651268323735") == .ups, "Detection keeps up as the number changes")
    #expect(!choice.isManual)
}

@Test func aChosenCarrierOutranksDetection() {
    var choice = CarrierChoice()
    choice.choose(.usps, whileShowing: choice.resolved(for: "1ZR0Y0651268323735"))

    #expect(choice.isManual)
    #expect(choice.resolved(for: "1ZR0Y0651268323735") == .usps)
    #expect(choice.resolved(for: "111111111111") == .usps, "The choice sticks even as the number changes")
}

@Test func anEchoOfTheShownCarrierIsNotAChoice() {
    // SwiftUI writes back through a Picker's binding during layout, not only
    // when tapped. Treating that echo as a choice froze the carrier on .other
    // and stopped detection for the rest of the screen.
    var choice = CarrierChoice()
    let shown = choice.resolved(for: "")
    #expect(shown == .other)

    choice.choose(.other, whileShowing: shown)

    #expect(!choice.isManual, "An echo must not count as choosing")
    #expect(choice.resolved(for: "1ZR0Y0651268323735") == .ups, "Detection still works afterwards")
}

@Test func echoesAfterARealChoiceLeaveItAlone() {
    var choice = CarrierChoice()
    choice.choose(.usps, whileShowing: .ups)
    choice.choose(.usps, whileShowing: .usps)  // Echo of the new value.

    #expect(choice.resolved(for: "1ZR0Y0651268323735") == .usps)
}

@Test func realWorldUPSNumberFillsTheCarrierIn() {
    // The number that surfaced the bug on device.
    let choice = CarrierChoice()
    #expect(choice.resolved(for: "1ZR0Y0651268323735") == .ups)
    #expect(choice.resolved(for: "1zr0y0651268323735") == .ups)
}
