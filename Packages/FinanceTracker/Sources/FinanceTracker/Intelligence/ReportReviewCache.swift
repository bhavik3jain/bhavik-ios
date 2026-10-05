import CryptoKit
import Foundation

/// The last review the model wrote for each report, kept on this device only
/// so reopening a month shows it at once instead of writing it again.
///
/// **Never in Core Data or iCloud.** The Finance store is shared with the
/// household and syncs: a review saved there would upload, and iCloud's zone
/// alert subscriptions fire on any change, so every review written would
/// alert the partner — the same reason `MetalPriceFeed` doesn't save live
/// prices as they arrive. Each device writes its own; a file in Application
/// Support goes nowhere.
///
/// One file per scope and owner, holding the brief's fingerprint: when any
/// figure the review was written from changes, the fingerprint does, and the
/// old review is a miss rather than a review of numbers no longer there.
/// What's stored is the model's words by fact number, never a finished
/// `ReportReview`: reading it back runs `ReportReview.isFaithful` again
/// against the current brief.
///
/// By fact number, not finding id: some finding ids carry a Core Data object
/// URI ("debtPaidDown:x-coredata://…/p275"), which is a temporary id until
/// the object is first saved and differs from store to store, so a review
/// filed by id lost its notes once the month entry saved. A matching
/// fingerprint already means the same facts in the same order, so the number
/// is exact.
///
/// Months' "Write Review Again" forgets a scope's reviews for every owner at
/// once (`removeAll(for:)`), so the next one opened is written fresh.
public struct ReportReviewCache: Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public struct Note: Codable, Sendable, Equatable {
            /// `ReportBrief.Fact.number` in the brief the fingerprint names.
            public var fact: Int
            public var message: String
        }

        public var fingerprint: String
        /// Which advisor wrote it (`FinanceAdvising.cacheIdentity`). Without
        /// it a Debug run under `-FinanceAdvisorStub YES` left "Stub: …"
        /// reviews that the real model's launches then served from the cache:
        /// a reinstall keeps Application Support, and the seed's figures —
        /// so the fingerprint — never change.
        public var writer: String?
        public var headline: String?
        public var notes: [Note]
        /// When the model finished it — the review's "Written today at 9:14"
        /// (`ReviewWrittenNote`), so a review kept since before the figures it
        /// talks about were last looked at is plain to see.
        public var savedAt: Date
        /// The live gold and silver prices the report was valued at when the
        /// model wrote it; nil when every month in it was at its own saved
        /// prices (and for a review kept before this was). An open month is
        /// valued at whatever was fetched last, so its fingerprint moved with
        /// every fetch, and every launch missed the review and wrote it again;
        /// with these the review is told apart from one about other figures
        /// (`ReportReviewModel`, `ReportReviewRenewal`).
        public var livePrices: MetalPrices?

        /// The model's words as it wrote them, against `brief` — the brief
        /// whose fingerprint this entry holds.
        public func draft(in brief: ReportBrief) -> ReportReviewDraft {
            ReportReviewDraft(
                headline: headline,
                notes: notes.map { note in
                    ReportReviewDraft.Note(fact: note.fact, group: brief.fact(numbered: note.fact)?.group, message: note.message)
                },
                isComplete: true
            )
        }
    }

    public let directory: URL

    /// Application Support/FinanceReviews.
    public static let shared = ReportReviewCache(
        directory: (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("FinanceReviews", isDirectory: true)
    )

    public init(directory: URL) {
        self.directory = directory
    }

    /// The file for `scope` and `owner`: "2026-09-<hash>.json", the owner
    /// hashed so a name never becomes a file name.
    func fileURL(scope: ReportScope, owner: String) -> URL {
        let hash = SHA256.hash(data: Data(owner.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(scope.rawValue)-\(hash).json")
    }

    /// The key a review is filed under: scope, owner and fingerprint. Two
    /// briefs share it only when the model would be shown the same text.
    public static func key(for brief: ReportBrief) -> String {
        "\(brief.scope.rawValue)|\(brief.ownerLabel)|\(brief.fingerprint)"
    }

    public func entry(for brief: ReportBrief, writer: String? = nil) -> Entry? {
        guard let entry = latestEntry(scope: brief.scope, owner: brief.ownerLabel, writer: writer),
              entry.fingerprint == brief.fingerprint
        else { return nil }
        return entry
    }

    /// Whatever review is kept for `scope` and `owner` by `writer`, about
    /// whichever figures — for telling one written at other gold and silver
    /// prices from one about other figures. `entry(for:writer:)` is the one
    /// for these very facts.
    public func latestEntry(scope: ReportScope, owner: String, writer: String? = nil) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL(scope: scope, owner: owner)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.writer == writer
        else { return nil }
        return entry
    }

    /// The cached review for `brief`, rebuilt against `findings`; nil on a
    /// miss, or when nothing in it is still the model's.
    public func review(for brief: ReportBrief, findings: [ReportFinding], writer: String? = nil) -> ReportReview? {
        guard let entry = entry(for: brief, writer: writer) else { return nil }
        let review = ReportReview(findings: findings, scope: brief.scope, brief: brief, draft: entry.draft(in: brief))
        return review.isWrittenByModel ? review : nil
    }

    /// Keeps what the model wrote that survived the checks — the headline
    /// only if it was the model's, and the model's notes.
    ///
    /// - Parameters:
    ///   - livePrices: the live prices the report was valued at, if it was
    ///     (`Entry.livePrices`).
    ///   - startedAt: when the run that wrote it began. A review saved for
    ///     the same scope and owner since then is newer and stays: a run that
    ///     went on writing about figures already replaced (its "Write Again"
    ///     isn't cancelled when its sheet closes) finished after the run for
    ///     the new figures, and filed the old figures' review over theirs —
    ///     the next open then missed and wrote it all again.
    public func save(
        _ review: ReportReview,
        for brief: ReportBrief,
        writer: String? = nil,
        livePrices: MetalPrices? = nil,
        startedAt: Date? = nil,
        asOf now: Date = .now
    ) {
        guard review.isWrittenByModel else { return }
        let url = fileURL(scope: brief.scope, owner: brief.ownerLabel)
        if let startedAt,
           let data = try? Data(contentsOf: url),
           let existing = try? JSONDecoder().decode(Entry.self, from: data),
           existing.savedAt > startedAt {
            return
        }
        let entry = Entry(
            fingerprint: brief.fingerprint,
            writer: writer,
            headline: review.isHeadlineWrittenByModel ? review.headline : nil,
            notes: review.allItems.filter(\.isWrittenByModel).compactMap { item in
                brief.fact(findingID: item.findingID).map { Entry.Note(fact: $0.number, message: item.text) }
            },
            savedAt: now,
            livePrices: livePrices
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: url, options: .atomic)
        } catch {
            // A cache: a review that can't be kept is written again next time.
        }
    }

    public func remove(for brief: ReportBrief) {
        try? FileManager.default.removeItem(at: fileURL(scope: brief.scope, owner: brief.ownerLabel))
    }

    /// Forgets `scope`'s review for every owner — Months' "Write Review
    /// Again", which is about the month, not whose figures were last shown.
    /// A year's file is never taken for one of its months', or the reverse.
    public func removeAll(for scope: ReportScope) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where Self.scope(ofFileNamed: name) == scope {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// The scope a file here was written for, read back off its name
    /// ("2026-09-<12 hex>.json", "2026-<12 hex>.json"); nil for anything else.
    /// Read from the end, so the year's "2026-" never matches a month's
    /// "2026-09-…".
    static func scope(ofFileNamed name: String) -> ReportScope? {
        guard name.hasSuffix(".json") else { return nil }
        let stem = name.dropLast(".json".count)
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        let hash = stem[stem.index(after: dash)...]
        guard hash.count == 12, hash.allSatisfy(\.isHexDigit) else { return nil }
        return ReportScope(rawValue: String(stem[..<dash]))
    }
}
