import Foundation

public extension FinanceReportHTML.ReviewBlock {
    /// The review sheet's review as the page's brief: the same headline and
    /// the same lines, model-written or the check's own, so the report and
    /// the sheet never word a month differently.
    init(_ review: ReportReview) {
        self.init(
            headline: review.headline,
            wentWell: review.wentWell.map(\.text),
            watch: review.watch.map(\.text),
            tryNext: review.tryNext.map(\.text),
            isModelWritten: review.isWrittenByModel,
            tryNextTitle: review.tryNextTitle
        )
    }
}

public extension FinanceReportHTML {
    /// The whole page, with the review (when there is one) as its brief.
    static func render(_ data: FinanceReportData, review: ReportReview?, options: Options = Options()) -> String {
        render(data, brief: review.map(ReviewBlock.init), options: options)
    }

    /// The page's sections in order for "Jump to Section" and the Mac
    /// sidebar: `data.sections`, less the brief when the page has none.
    static func sections(
        for data: FinanceReportData,
        review: ReportReview?,
        options: Options = Options()
    ) -> [FinanceReportData.ReportSection] {
        sections(for: data, brief: review.map(ReviewBlock.init), options: options)
    }
}
