import Core
import SwiftUI

/// When the review on screen was written — "Written today at 9:14" — under
/// its headline in the review sheet and the Mac's inspector, and over "Write
/// Review Again" in the report's menus. A review is kept until its figures
/// change, so one written weeks ago about a month since looked at again
/// looked exactly like one written a minute ago.
enum ReviewWrittenNote {
    /// "Written today at 9:14", "Written yesterday at 18:02", "Written on
    /// 2 October at 9:14" — with the year once it's another one. The time is
    /// in the person's own style, 12- or 24-hour.
    static func text(
        writtenAt: Date,
        asOf now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = timeText(writtenAt, calendar: calendar, locale: locale)
        // A clock set back since is still "today", not a date in the future.
        if writtenAt > now || calendar.isDate(writtenAt, inSameDayAs: now) {
            return "Written today at \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(writtenAt, inSameDayAs: yesterday) {
            return "Written yesterday at \(time)"
        }
        var day = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.wide)
        if calendar.component(.year, from: writtenAt) != calendar.component(.year, from: now) {
            day = day.year()
        }
        return "Written on \(writtenAt.formatted(day)) at \(time)"
    }

    /// "9:14", "09:14" or "9:14 AM" — the person's own short time, which is
    /// the system's to spell: the iOS 27 simulator writes en_GB's as "9:14"
    /// where a test expected "09:14", so tests ask this rather than assume.
    static func timeText(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }

    /// Under the time when only the gold and silver prices have moved since
    /// (`ReportReviewModel.isCarriedOver`): a note or two may be in the
    /// check's own words, and writing it again words today's figures.
    static let pricesMoved = "Gold and silver have moved since, so a note or two may be in the check's own words until it's written again."

    /// The line for a review model: what it's doing, or when the review it
    /// shows was written; nil for the plain check, which is worked out from
    /// the figures each time it's shown.
    @MainActor
    static func status(of model: ReportReviewModel, asOf now: Date = .now) -> String? {
        if model.isWriting { return "Writing the review…" }
        guard model.isReady, let writtenAt = model.writtenAt else { return nil }
        return text(writtenAt: writtenAt, asOf: now)
    }
}

/// "Write Review Again", with when the review was written over it, for the
/// report viewer's ••• menu, the Mac report window's More menu and the
/// Summary card's menu. Only where Apple Intelligence can write one: the
/// plain check is rebuilt from the store whenever it changes, and has
/// nothing to write again.
struct WriteReviewAgainSection: View {
    let model: ReportReviewModel?

    @Environment(\.financeAdvisor) private var advisor
    @Environment(\.financeAdvisorEnabled) private var isEnabled

    var body: some View {
        if let model, advisor.availability(isEnabled: isEnabled) == .available {
            Section {
                Button("Write Review Again", systemImage: "arrow.clockwise") {
                    // Not tied to the menu, which is gone the moment it's
                    // tapped: the review is written, and kept, either way.
                    Task { await model.writeAgain(advisor: advisor, enabled: isEnabled) }
                }
                .disabled(model.isWriting)
            } header: {
                if let status = ReviewWrittenNote.status(of: model) {
                    Text(status)
                }
            }
        }
    }
}

/// "Written today at 9:14" under a review's headline, or nothing for the
/// plain check and while it's being written ("Writing from 14 figures…"
/// stands there then).
struct ReviewWrittenLabel: View {
    let model: ReportReviewModel

    var body: some View {
        if model.isReady, let writtenAt = model.writtenAt {
            VStack(alignment: .leading, spacing: 2) {
                Text(ReviewWrittenNote.text(writtenAt: writtenAt))
                if model.isCarriedOver {
                    Text(ReviewWrittenNote.pricesMoved)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}
