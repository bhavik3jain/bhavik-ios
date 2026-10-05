import Foundation

/// What a review on screen was written from, as far as keeping it goes: the
/// report it's of, whose figures, the facts the model was shown, and — while
/// the month is open — the live gold and silver prices those figures were
/// valued at.
public struct ReportReviewBasis: Equatable, Sendable {
    public let scope: ReportScope
    public let ownerLabel: String
    /// `ReportBrief.fingerprint`: every fact the model was shown, worded.
    public let fingerprint: String
    /// The prices the report's figures are valued at when they're today's
    /// live ones (`FinanceReportData.Header.pricesAreLive`); nil when every
    /// month in it is at its own saved prices.
    public let livePrices: MetalPrices?

    public init(scope: ReportScope, ownerLabel: String, fingerprint: String, livePrices: MetalPrices?) {
        self.scope = scope
        self.ownerLabel = ownerLabel
        self.fingerprint = fingerprint
        self.livePrices = livePrices
    }

    public init(data: FinanceReportData, brief: ReportBrief) {
        self.init(scope: data.scope, ownerLabel: brief.ownerLabel, fingerprint: brief.fingerprint, livePrices: data.livePrices)
    }
}

extension FinanceReportData {
    /// The live gold and silver prices the open month is valued at, when
    /// it's in this report and they've been fetched; nil when every month
    /// here is at its own saved prices.
    public var livePrices: MetalPrices? {
        header.pricesAreLive ? metals.prices : nil
    }
}

/// Whether the review a screen holds can stay with a freshly built report,
/// or another must be written — decided once here, so the Summary's card,
/// the review sheet, the report viewer and the Mac's report window agree.
///
/// A review is kept whenever what the model was shown is unchanged, even if
/// the report around it moved: a partner's edit to an unrelated account
/// rebuilt the report, and with it a model that wrote the whole review again.
/// But the model is always handed the new report (`ReportReviewModel.update`):
/// the Summary used to keep its model whenever the findings matched, model
/// figures and all, so Ask answered from figures already changed.
public enum ReportReviewRenewal: Equatable, Sendable {
    /// The same facts: the review stands, and the model takes the new report
    /// for everything around it — Ask's figures, findings past the brief's
    /// cap, the months the fixes open.
    case keep
    /// The same report with only the gold and silver prices it's valued at
    /// moved: the review stands, its notes carried onto the new figures, any
    /// that quoted a figure the prices moved falling back to the check's own
    /// words. Prices are fetched again whenever Finance or a month opens on
    /// prices over a quarter of an hour old, and an open month is valued at
    /// them everywhere, so each fetch changed the net worth, the brief and
    /// its fingerprint — and the model wrote the whole review again, every
    /// time, for a few dollars of silver.
    case carryOver
    /// What the review was written from changed — another month, another
    /// person, a figure the model was shown: a model for the new figures,
    /// which looks in the cache and otherwise writes the review again.
    case replace

    /// - Parameters:
    ///   - current: what the review on screen was written from; nil with none.
    ///   - next: the report just built.
    ///   - fingerprintAtPrices: the fingerprint of the report just built, had
    ///     its open month been valued at the given live prices — nil: at its
    ///     own saved ones. Asked only when the two are valued differently.
    public static func decide(
        current: ReportReviewBasis?,
        next: ReportReviewBasis,
        fingerprintAtPrices: (MetalPrices?) -> String?
    ) -> ReportReviewRenewal {
        guard let current, current.scope == next.scope, current.ownerLabel == next.ownerLabel else { return .replace }
        if current.fingerprint == next.fingerprint { return .keep }
        // The first fetch counts too: until it lands the open month is at its
        // saved prices, so every launch moved the figures a second after the
        // review was shown. Rebuilt at what the review was written at, only a
        // report that then tells the very same facts carries it — an edit
        // made alongside a tick is new figures, and written again.
        if current.livePrices != next.livePrices,
           fingerprintAtPrices(current.livePrices) == current.fingerprint {
            return .carryOver
        }
        return .replace
    }
}

extension ReportReviewDraft {
    /// This draft's notes, numbered for `written` — the brief the model was
    /// shown — renumbered for `current`: unchanged when the two tell the same
    /// facts, else by finding, since a price tick can re-rank them. A note
    /// whose fact `current` no longer has is dropped; one whose figures moved
    /// is kept for `ReportReview.isFaithful` to drop, so the check's own
    /// words stand in for it.
    ///
    /// Finding ids can carry a Core Data object URI, which is why the cache
    /// files notes by fact number. Both briefs here are this launch's — a
    /// cached review is first renumbered from its report rebuilt at its
    /// prices — so their ids agree, and a pair that didn't (an object saved
    /// for the first time in between) would only lose its note to the
    /// check's words.
    public func carried(from written: ReportBrief, to current: ReportBrief) -> ReportReviewDraft {
        guard written.fingerprint != current.fingerprint else { return self }
        var draft = self
        draft.notes = notes.compactMap { note in
            guard let findingID = written.fact(numbered: note.fact)?.findingID,
                  let fact = current.fact(findingID: findingID)
            else { return nil }
            return Note(fact: fact.number, group: fact.group, message: note.message)
        }
        return draft
    }
}
