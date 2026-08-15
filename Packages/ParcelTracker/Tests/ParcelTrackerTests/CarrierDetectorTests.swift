import Foundation
import Testing
@testable import ParcelTracker

// Numbers below come from jkeen/tracking_number_data, the shared dataset used
// for cross-platform tracking number detection, rather than being invented here.

@Test func normalizingStripsThePunctuationPeoplePaste() {
    #expect(CarrierDetector.normalize("9400 1112 0620 6406 2607 87") == "9400111206206406260787")
    #expect(CarrierDetector.normalize("1z999aa1-0123456784") == "1Z999AA10123456784")
    #expect(CarrierDetector.normalize("  ") == "")
}

@Test func upsNumbersAreIdentifiedOutright() {
    let guess = CarrierDetector.detect("1Z999AA10123456784")
    #expect(guess.carrier == .ups)
    #expect(guess.isCertain, "1Z is unique to UPS")
}

@Test func upsDetectionSurvivesLowercaseAndSpacing() {
    #expect(CarrierDetector.detect("1z 999 aa1 01 2345 6784").carrier == .ups)
}

@Test func aWrongLength1ZNumberIsNotTreatedAsUPS() {
    #expect(CarrierDetector.detect("1Z999AA1012345678").carrier != .ups)
}

@Test(arguments: [
    "9400111206206406260787",
    "9434611206206406227577",
    "9400111206206407628746",
    "420787459400111206206406260787"  // behind a 420 + ZIP routing block
])
func uspsIntelligentMailIsRecognised(number: String) {
    let guess = CarrierDetector.detect(number)
    #expect(guess.carrier == .usps, "\(number) should read as USPS")
}

@Test func uspsChecksumRejectsATamperedNumber() {
    // Same number as above with the final digit changed.
    #expect(!USPSNumber.isChecksumValid("9434611206206407667131"))
    #expect(USPSNumber.isChecksumValid("9434611206206407667136"))
}

@Test func uspsChecksumIgnoresTheRoutingBlock() {
    let bare = "9400111206206406260787"
    let routed = "420787459400111206206406260787"
    #expect(USPSNumber.isChecksumValid(bare))
    #expect(USPSNumber.isChecksumValid(routed), "The 420 + ZIP prefix is not part of the checksum")
}

@Test func twentyDigitCertifiedMailReadsAsUSPS() {
    // A 20-digit number is ambiguous by shape, so the check digit decides.
    let guess = CarrierDetector.detect("7112345678912345 6787")
    #expect(guess.carrier == .usps)
    #expect(!guess.isCertain, "A 20-digit number can't be pinned to one carrier")
}

@Test func twelveDigitNumbersReadAsFedEx() {
    let guess = CarrierDetector.detect("961234567890")
    #expect(guess.carrier == .fedex)
    #expect(guess.isCertain)
}

@Test func fifteenDigitFedExIsAGuessNotACertainty() {
    let guess = CarrierDetector.detect("123456789012345")
    #expect(guess.carrier == .fedex)
    #expect(!guess.isCertain)
}

@Test func unrecognisedFormatsFallBackToOther() {
    #expect(CarrierDetector.detect("RR123456789US").carrier == .other)  // International
    #expect(CarrierDetector.detect("12345").carrier == .other)
    #expect(CarrierDetector.detect("").carrier == .other)
}

// MARK: - Carrier capabilities

@Test func onlyFedExIsTrackedAutomaticallyForNow() {
    #expect(Carrier.fedex.supportsAutomaticTracking)
    #expect(!Carrier.ups.supportsAutomaticTracking, "UPS isn't wired up yet")
    #expect(!Carrier.usps.supportsAutomaticTracking, "USPS closed third-party tracking in April 2026")
    #expect(!Carrier.other.supportsAutomaticTracking)
}

@Test func carriersFollowedByHandExplainWhy() {
    // The screens show this text, so every manual carrier needs one and the
    // automatic one must not claim to need explaining.
    #expect(Carrier.ups.manualTrackingReason != nil)
    #expect(Carrier.usps.manualTrackingReason != nil)
    #expect(Carrier.fedex.manualTrackingReason == nil)

    for carrier in Carrier.allCases where !carrier.supportsAutomaticTracking && carrier != .other {
        #expect(carrier.manualTrackingReason?.isEmpty == false, "\(carrier.displayName) needs a reason")
        #expect(carrier.trackingURL(for: "123") != nil, "\(carrier.displayName) must be openable")
    }
}

@Test func everyTrackableCarrierOffersALinkToItsOwnSite() {
    let number = "9400111206206406260787"
    for carrier in [Carrier.usps, .ups, .fedex] {
        let url = carrier.trackingURL(for: number)
        #expect(url != nil, "\(carrier.displayName) should link out")
        #expect(url?.absoluteString.contains(number) == true)
    }
    #expect(Carrier.other.trackingURL(for: number) == nil)
}

@Test func detectionFollowsTextAsItIsTyped() {
    // The add screen re-runs detection on every keystroke, so partial numbers
    // must not settle on a carrier before the format is complete.
    #expect(CarrierDetector.detect("1111").carrier == .other)
    #expect(CarrierDetector.detect("11111111111").carrier == .other, "11 digits is not a FedEx length")
    #expect(CarrierDetector.detect("111111111111").carrier == .fedex, "12 digits is")
}

@Test func realWorldUPSNumberIsRecognised() {
    // A real label, including the lowercase and spacing a paste can carry.
    let guess = CarrierDetector.detect("1zr0y0651268323735")
    #expect(guess.carrier == .ups)
    #expect(guess.isCertain)

    let spaced = CarrierDetector.detect("1Z R0Y065 12 6832 3735")
    #expect(spaced.carrier == .ups)
    #expect(CarrierDetector.normalize("1z r0y065 12 6832 3735") == "1ZR0Y0651268323735")
}

@Test func upsNumbersLinkToUPSTracking() throws {
    let url = try #require(Carrier.ups.trackingURL(for: "1ZR0Y0651268323735"))
    #expect(url.absoluteString.contains("ups.com"))
    #expect(url.absoluteString.contains("1ZR0Y0651268323735"))
}
