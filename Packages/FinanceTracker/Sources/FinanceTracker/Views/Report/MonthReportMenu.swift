import Core
import SwiftUI

/// "Report" on a month's own screen — the phone's month entry and the Mac's
/// grid: View Report, and Write Review Again where Apple Intelligence can
/// write one. Changing a month happens there, and the month had no way to
/// its report at all: the person went back to Months, or to the Summary, to
/// see whether the review had caught up.
struct MonthReportMenu: View {
    let scope: ReportScope
    /// Puts `scope`'s report on screen (`presentsReport`).
    let open: (ReportScope) -> Void

    @Environment(\.financeAdvisor) private var advisor
    @Environment(\.financeAdvisorEnabled) private var isEnabled

    var body: some View {
        Menu {
            Button("View Report", systemImage: "doc.text") { open(scope) }
            // Hidden where the model can't run: the plain check is worked out
            // from the store each time it's shown, so there's nothing to redo.
            if advisor.availability(isEnabled: isEnabled) == .available {
                Button("Write Review Again", systemImage: "arrow.clockwise") {
                    ReportReviewModel.writeReviewsAgain(of: scope, advisor: advisor, enabled: isEnabled)
                    open(scope)
                }
            }
        } label: {
            Label("Report", systemImage: "doc.text")
        }
        .help("The month's report, and writing its review again")
    }
}
