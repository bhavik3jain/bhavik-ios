import Core
import CoreData
import SwiftUI
import UniformTypeIdentifiers

/// The JSON a month is exported as, wrapped for `.fileExporter`.
struct FinanceJSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw FinanceImportError.unreadableFile
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Export a month as JSON for the Numbers sheet, or import one the Mac
/// script made from it. On the Mac, also fill the Numbers sheet directly.
struct MonthExchangeView: View {
    let months: [SharedFinanceMonth]
    let household: SharedFinanceHousehold?
    /// The month the picker starts on: the Summary's reported month. It used to
    /// start on the newest, which is usually the open one, still half filled in
    /// (a new month starts every balance at zero), and that is the month an
    /// export to Numbers then got — with no transactions yet.
    var initialMonth: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container
    @Environment(\.financeCanCreateHousehold) private var canCreateHousehold
    @Environment(\.financeNumbersExporter) private var numbersExporter
    @Environment(\.openURL) private var openURL

    @State private var selectedMonth: String?
    @State private var exportFile: FinanceJSONFile?
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var resultTitle = ""
    @State private var resultMessage: String?
    /// The month being filled in Numbers, while it is.
    @State private var fillingMonth: String?
    @State private var numbersFile: URL?
    @State private var showingNumbersMover = false

    private var chosen: SharedFinanceMonth? {
        let newestFirst = months.sorted { $0.yearMonth > $1.yearMonth }
        return newestFirst.first(where: { $0.yearMonth == (selectedMonth ?? initialMonth) }) ?? newestFirst.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if months.isEmpty {
                        Text("No months to export yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Month", selection: Binding(
                            get: { chosen?.yearMonth ?? "" },
                            set: { selectedMonth = $0 }
                        )) {
                            ForEach(months.sorted { $0.yearMonth > $1.yearMonth }) { month in
                                Text(month.title).tag(month.yearMonth)
                            }
                        }
                        if numbersExporter != nil {
                            Button(action: exportToNumbers) {
                                if let fillingMonth {
                                    HStack {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Filling \(fillingMonth) in Numbers…")
                                    }
                                } else {
                                    Label("Export \(chosen?.title ?? "") to Numbers", systemImage: "tablecells")
                                }
                            }
                            .disabled(chosen == nil || fillingMonth != nil)
                        }
                        Button("Export \(chosen?.title ?? "") as JSON", systemImage: "square.and.arrow.up", action: export)
                            .disabled(chosen == nil)
                    }
                } header: {
                    Text("Export")
                } footer: {
                    if numbersExporter != nil {
                        Text("To Numbers fills a copy of the Finance template, growing every table to fit — it takes a minute or two, then asks where to save it. Like the sheet, a month holds the transactions entered since the month before it was closed. JSON is for the scripts in scripts/finance.")
                    } else {
                        Text("Save it to iCloud Drive › Multitrack › Finance. Then on your Mac, open Finance › Export in the Multitrack Mac app to make the Numbers file — or run “Export Finance to Numbers” in scripts/finance.")
                    }
                }

                Section {
                    Button("Import a Month…", systemImage: "square.and.arrow.down") {
                        showingImporter = true
                    }
                    // With no household yet, importing would create one —
                    // which waits for iCloud, see `financeCanCreateHousehold`.
                    .disabled(!canEdit(household, in: container) || (household == nil && !canCreateHousehold))
                } header: {
                    Text("Import")
                } footer: {
                    Text("Pick a JSON file made by scripts/finance/import_numbers.py from the Numbers sheet. Accounts, cards and metals are matched by name; transactions already here are skipped, so importing twice is safe.")
                }
            }
            .navigationTitle("Export & Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportFile,
                contentType: .json,
                defaultFilename: FinanceMonthDocument.fileStem(for: chosen?.yearMonth ?? "")
            ) { result in
                if case .failure(let error) = result {
                    show("Export failed", error.localizedDescription)
                }
            }
            .fileMover(isPresented: $showingNumbersMover, file: numbersFile) { result in
                switch result {
                case .success(let url):
                    openURL(url)
                case .failure(let error):
                    show("Couldn’t save the Numbers file", error.localizedDescription)
                }
                numbersFile = nil
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .alert(resultTitle, isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(resultMessage ?? "")
            }
        }
    }

    /// The month as the file carries it: an open latest month with the live
    /// prices it's being valued at, not the ones last stored in it.
    private func document(for month: SharedFinanceMonth) -> FinanceMonthDocument {
        var document = FinanceMonthDocument(month: month)
        let prices = MetalPriceFeed.shared.prices(for: month)
        document.metalPrices = FinanceMonthDocument.Prices(gold: prices.gold, silver: prices.silver)
        return document
    }

    private func export() {
        guard let chosen else { return }
        do {
            exportFile = FinanceJSONFile(data: try FinanceMonthExchange.encode(document(for: chosen)))
            showingExporter = true
        } catch {
            show("Export failed", error.localizedDescription)
        }
    }

    private func exportToNumbers() {
        guard let chosen, let numbersExporter else { return }
        let document = document(for: chosen)
        fillingMonth = chosen.title
        Task {
            defer { fillingMonth = nil }
            do {
                numbersFile = try await numbersExporter.fill(document)
                showingNumbersMover = true
            } catch {
                show("Export to Numbers failed", error.localizedDescription)
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let target = FinanceHouseholdResolver.forWriting(in: context, container: container)
            do {
                let summary = try FinanceMonthExchange.importFile(at: url, into: target)
                try context.saveIfNeeded()
                show("Import complete", summary.message)
            } catch {
                // Nothing half-imported is left to sync by the next save.
                context.rollback()
                show("Import failed", error.localizedDescription)
            }
        case .failure(let error):
            show("Import failed", error.localizedDescription)
        }
    }

    private func show(_ title: String, _ message: String) {
        resultTitle = title
        resultMessage = message
    }
}
