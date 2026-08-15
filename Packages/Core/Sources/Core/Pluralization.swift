import Foundation

/// Counts written out for people: "1 parcel", "3 parcels".
///
/// SwiftUI's `^[…](inflect: true)` markup only applies when the literal reaches
/// `Text` directly. Building the sentence in a `String` first — which is what
/// any computed summary does — leaves the markup on screen verbatim, so text
/// assembled outside a view uses this instead.
public func counted(_ count: Int, _ singular: String, plural: String? = nil) -> String {
    "\(count) \(count == 1 ? singular : plural ?? singular + "s")"
}
