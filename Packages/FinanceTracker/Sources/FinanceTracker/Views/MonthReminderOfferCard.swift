import SwiftUI

/// The Summary's one-time offer of the monthly reminder, shown while
/// `FinanceMonthReminder.offersReminder` holds. Turn On is what asks for
/// notification permission, so the system prompt comes right after a line
/// saying what it's for — opening Finance used to ask with no explanation.
struct MonthReminderOfferCard: View {
    /// Hides the card: after either button the offer no longer applies
    /// (permission was answered, or the offer turned down).
    var onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Get a reminder on the 1st", systemImage: "calendar.badge.clock")
                .font(.headline)
            Text("A notification at 9 AM on the 1st of each month, to fill in that month's balances. You can turn it off any time in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Turn On") {
                    Task {
                        await FinanceMonthReminder.askPermissionAndReschedule()
                        onFinish()
                    }
                }
                .buttonStyle(.borderedProminent)
                // Bordered, both: in a list row a plain button turns the
                // whole row into one tap target (as on TV's Up Next offer).
                Button("Not Now") {
                    FinanceMonthReminder.dismissOffer()
                    onFinish()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
