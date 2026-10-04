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
public struct ReportReviewCache: Sendable {
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
        public var savedAt: Date
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
        let url = fileURL(scope: brief.scope, owner: brief.ownerLabel)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.fingerprint == brief.fingerprint,
              entry.writer == writer
        else { return nil }
        return entry
    }

    /// The cached review for `brief`, rebuilt against `findings`; nil on a
    /// miss, or when nothing in it is still the model's.
    public func review(for brief: ReportBrief, findings: [ReportFinding], writer: String? = nil) -> ReportReview? {
        guard let entry = entry(for: brief, writer: writer) else { return nil }
        let draft = ReportReviewDraft(
            headline: entry.headline,
            notes: entry.notes.map { note in
                ReportReviewDraft.Note(fact: note.fact, group: brief.fact(numbered: note.fact)?.group, message: note.message)
            },
            isComplete: true
        )
        let review = ReportReview(findings: findings, scope: brief.scope, brief: brief, draft: draft)
        return review.isWrittenByModel ? review : nil
    }

    /// Keeps what the model wrote that survived the checks — the headline
    /// only if it was the model's, and the model's notes.
    public func save(_ review: ReportReview, for brief: ReportBrief, writer: String? = nil, asOf now: Date = .now) {
        guard review.isWrittenByModel else { return }
        let entry = Entry(
            fingerprint: brief.fingerprint,
            writer: writer,
            headline: review.isHeadlineWrittenByModel ? review.headline : nil,
            notes: review.allItems.filter(\.isWrittenByModel).compactMap { item in
                brief.fact(findingID: item.findingID).map { Entry.Note(fact: $0.number, message: item.text) }
            },
            savedAt: now
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: fileURL(scope: brief.scope, owner: brief.ownerLabel), options: .atomic)
        } catch {
            // A cache: a review that can't be kept is written again next time.
        }
    }

    public func remove(for brief: ReportBrief) {
        try? FileManager.default.removeItem(at: fileURL(scope: brief.scope, owner: brief.ownerLabel))
    }
}
