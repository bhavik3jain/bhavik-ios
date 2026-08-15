import Foundation

/// Guesses the carrier from a tracking number.
///
/// Some formats identify a carrier outright — UPS numbers start with `1Z` and
/// nothing else does. Bare numeric formats overlap between carriers, so a USPS
/// check digit is used to break the tie where one exists. The result is still a
/// guess, so callers should let the reader correct it.
public enum CarrierDetector {
    public struct Guess: Equatable, Sendable {
        public let carrier: Carrier
        /// True when the format identifies the carrier on its own, rather than
        /// being the likeliest of several candidates.
        public let isCertain: Bool

        public init(carrier: Carrier, isCertain: Bool) {
            self.carrier = carrier
            self.isCertain = isCertain
        }
    }

    /// Strips the spaces and dashes people paste along with a number.
    public static func normalize(_ input: String) -> String {
        input.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func detect(_ input: String) -> Guess {
        let number = normalize(input)
        guard !number.isEmpty else { return Guess(carrier: .other, isCertain: false) }

        // UPS: 1Z, a 6-character shipper, 2-digit service, 7-digit package.
        if number.hasPrefix("1Z"), number.count == 18 {
            return Guess(carrier: .ups, isCertain: true)
        }

        // Anything else with letters is an international or regional service
        // this app doesn't follow.
        guard number.allSatisfy(\.isNumber) else {
            return Guess(carrier: .other, isCertain: false)
        }

        switch number.count {
        case 22, 26, 30, 34:
            // USPS Intelligent Mail, optionally behind a routing block.
            if USPSNumber.hasServicePrefix(number) {
                return Guess(carrier: .usps, isCertain: USPSNumber.isChecksumValid(number))
            }
            return Guess(carrier: .other, isCertain: false)

        case 20:
            // Shared shape: USPS certified/registered mail, and some FedEx
            // numbers. A passing USPS check digit tips it toward USPS.
            if USPSNumber.isChecksumValid(number) {
                return Guess(carrier: .usps, isCertain: false)
            }
            return Guess(carrier: .fedex, isCertain: false)

        case 12:
            return Guess(carrier: .fedex, isCertain: true)

        case 15:
            return Guess(carrier: .fedex, isCertain: false)

        default:
            return Guess(carrier: .other, isCertain: false)
        }
    }
}

/// USPS number structure.
///
/// Numbers may carry a `420` + ZIP routing block that shipping software
/// prepends for sortation, and 34-digit labels add a further 4-digit routing
/// number. The mod-10 check digit covers only the serial number that follows,
/// so the routing block has to come off before validating.
enum USPSNumber {
    static let servicePrefixes = [
        "92", "93", "94", "95", "96", "97", "98",  // Intelligent Mail
        "70", "71", "73", "77"                     // certified, insured, registered
    ]

    /// Drops the routing block, leaving the serial number and its check digit.
    static func serial(_ digits: String) -> String {
        guard digits.hasPrefix("420") else { return digits }
        let routingWidth = digits.count == 34 ? 12 : 8  // 420+ZIP5, plus routing4 on 34s.
        guard digits.count > routingWidth else { return digits }
        return String(digits.dropFirst(routingWidth))
    }

    static func hasServicePrefix(_ digits: String) -> Bool {
        let core = serial(digits)
        return servicePrefixes.contains { core.hasPrefix($0) }
    }

    /// Mod 10, weighting digits 3 and 1 from the left of the serial number.
    static func isChecksumValid(_ digits: String) -> Bool {
        let core = serial(digits)
        let values = core.compactMap { $0.wholeNumberValue }
        guard values.count == core.count, values.count >= 2 else { return false }

        let check = values[values.count - 1]
        let sum = values.dropLast().enumerated().reduce(0) { total, pair in
            total + pair.element * (pair.offset.isMultiple(of: 2) ? 3 : 1)
        }
        return (10 - sum % 10) % 10 == check
    }
}
