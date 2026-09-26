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
/// script made from it.
struct MonthExchangeView: View {
    let months: [SharedFinanceMonth]
    let household: SharedFinanceHousehold?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container
    @Environment(\.financeCanCreateHousehold) private var canCreateHousehold

    @State private var selectedMonth: String?
    @State private var exportFile: FinanceJSONFile?
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var resultTitle = ""
    @State private var resultMessage: String?

    private var chosen: SharedFinanceMonth? {
        let newestFirst = months.sorted { $0.yearMonth > $1.yearMonth }
        return newestFirst.first(where: { $0.yearMonth == selectedMonth }) ?? newestFirst.first
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
                        Button("Export \(chosen?.title ?? "")", systemImage: "square.and.arrow.up", action: export)
                            .disabled(chosen == nil)
                    }
                } header: {
                    Text("Export")
                } footer: {
                    Text("Save it to iCloud Drive › Multitrack › Finance. Then on the Mac, run `uv run --with numbers-parser scripts/finance/export_numbers.py` to write it into the Numbers sheet.")
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

    private func export() {
        guard let chosen else { return }
        do {
            exportFile = FinanceJSONFile(data: try FinanceMonthExchange.encode(FinanceMonthDocument(month: chosen)))
            showingExporter = true
        } catch {
            show("Export failed", error.localizedDescription)
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
