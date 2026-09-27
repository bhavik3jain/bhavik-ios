import FinanceTracker
import Foundation

extension FinanceNumbersExporter {
    /// The Mac's Export to Numbers; nil on the phone, which can't script
    /// Numbers, so Finance's Export sheet offers only the JSON there.
    static var forThisPlatform: FinanceNumbersExporter? {
        #if os(macOS)
        MacFinanceNumbers.exporter
        #else
        nil
        #endif
    }
}

#if os(macOS)
import AppKit
import OSAKit

/// Fills a copy of the Finance template in Numbers, from inside the app —
/// what `scripts/finance/export_numbers.py` does, without Python or Terminal.
///
/// The template (`scripts/finance/Finance Template.numbers`) and the fill
/// script (`numbers_fill.js`) are copied into the Mac app's resources by
/// project.yml, so the app always fills the committed template. The script
/// runs in-process through OSAKit, so the Automation prompt names Multitrack.
/// That needs three things in App-macOS.entitlements / Info-macOS.plist:
/// the sandbox's Apple-events exception for Numbers, the hardened runtime's
/// apple-events entitlement, and NSAppleEventsUsageDescription. Without any
/// one of them every Apple event fails with -1743 and no prompt ever appears.
enum MacFinanceNumbers {
    static let numbersBundleID = "com.apple.Numbers"

    static let exporter = FinanceNumbersExporter { document in
        try await fill(document)
    }

    enum ExportError: LocalizedError {
        case missingResource(String)
        case numbersNotInstalled
        case notAllowed
        case script(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                "This build of Multitrack is missing \(name)."
            case .numbersNotInstalled:
                "Numbers isn’t installed. Get it from the App Store, then try again."
            case .notAllowed:
                "Multitrack isn’t allowed to control Numbers. Turn it on in System Settings › Privacy & Security › Automation › Multitrack, then try again."
            case .script(let message):
                message
            }
        }
    }

    static func fill(_ document: FinanceMonthDocument) async throws -> URL {
        guard let template = Bundle.main.url(forResource: "Finance Template", withExtension: "numbers") else {
            throw ExportError.missingResource("the Finance template")
        }
        guard let scriptURL = Bundle.main.url(forResource: "numbers_fill", withExtension: "js") else {
            throw ExportError.missingResource("numbers_fill.js")
        }
        guard let numbers = NSWorkspace.shared.urlForApplication(withBundleIdentifier: numbersBundleID) else {
            throw ExportError.numbersNotInstalled
        }

        // A folder of its own, so the file can carry its final name for the
        // save panel and two exports never share a path.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NumbersExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("\(FinanceMonthDocument.fileStem(for: document.month)).numbers")
        let specURL = folder.appendingPathComponent("spec.json")
        do {
            try FileManager.default.copyItem(at: template, to: output)
            let spec = FinanceNumbersSpec(document: document, outputPath: output.resolvingSymlinksInPath().path)
            try JSONEncoder().encode(spec).write(to: specURL)
            let source = try String(contentsOf: scriptURL, encoding: .utf8)

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.open([output], withApplicationAt: numbers, configuration: configuration)

            try await run(source, argument: specURL.path)
            try? FileManager.default.removeItem(at: specURL)
            return output
        } catch {
            // A half-filled copy is worse than none.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Runs the fill script's `run(argv)` on a thread of its own: it takes a
    /// minute or two, and OSAKit blocks while it does.
    private static func run(_ source: String, argument: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let thread = Thread {
                let script = OSAScript(source: source, language: OSALanguage(forName: "JavaScript"))
                var errorInfo: NSDictionary?
                let result = script.executeHandler(withName: "run", arguments: [[argument]], error: &errorInfo)
                if result != nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: explain(errorInfo))
                }
            }
            thread.name = "Finance Numbers export"
            thread.start()
        }
    }

    private static func explain(_ info: NSDictionary?) -> ExportError {
        let number = info?[OSAScriptErrorNumberKey] as? Int
        let message = info?[OSAScriptErrorMessageKey] as? String ?? "Numbers stopped with an unknown error."
        // -1743: the user said no to (or was never asked about) Automation.
        if number == -1743 || message.contains("Not authorized") {
            return .notAllowed
        }
        return .script(message.replacingOccurrences(of: "Error: ", with: ""))
    }

    #if DEBUG
    /// `-FinanceNumbersExportProbe YES` fills the template with a made-up
    /// month at launch and prints where the result went: the whole sandboxed
    /// path (Launch Services, Automation, OSAKit) without clicking through
    /// Finance or touching real data. Made up here because nothing outside
    /// the sandbox can put a file where the app could read it.
    @MainActor
    static func runProbeIfRequested() {
        guard UserDefaults.standard.bool(forKey: "FinanceNumbersExportProbe") else { return }
        Task {
            do {
                let started = Date.now
                let output = try await fill(probeDocument)
                print("FinanceNumbersExportProbe: wrote \(output.path) in \(Int(Date.now.timeIntervalSince(started)))s")
                // Left open in Numbers: nothing outside the sandbox can read
                // the container's tmp folder to check the result any other way.
                NSWorkspace.shared.open(output)
            } catch {
                print("FinanceNumbersExportProbe: failed: \(error.localizedDescription)")
            }
        }
    }

    private static var probeDocument: FinanceMonthDocument {
        typealias D = FinanceMonthDocument
        return D(
            month: "2026-09",
            metalPrices: D.Prices(gold: 4_300, silver: 65),
            owners: ["Alex", "Sam", "Joint"],
            accounts: [
                D.AccountEntry(category: "cash", institution: "Test Bank", name: "Checking", owner: "Alex", balance: 1_234.56),
                D.AccountEntry(category: "cash", institution: "Test Bank", name: "Savings", owner: "Sam", balance: 2_000),
                D.AccountEntry(category: "cash", institution: "Other Bank", name: "Joint Checking", owner: "", balance: 300),
                D.AccountEntry(category: "cash", institution: "Other Bank", name: "Emergency", owner: "Sam", balance: 400),
                D.AccountEntry(category: "investments", institution: "Broker", name: "Brokerage", owner: "Alex", balance: 5_000),
                D.AccountEntry(category: "retirement", institution: "Plan", name: "401k", owner: "Sam", balance: 7_000),
                D.AccountEntry(category: "fixed", institution: "", name: "Car", owner: "", balance: 9_000),
                D.AccountEntry(category: "loan", institution: "Lender", name: "Car Loan", owner: "", balance: 3_000),
            ],
            cards: [
                D.CardEntry(institution: "Card Co", name: "Rewards", owner: "Alex", limit: 1_000, annualFee: 0),
                D.CardEntry(institution: "Card Co", name: "Travel", owner: "Sam", limit: 2_000, annualFee: 95),
            ],
            metals: [
                D.MetalEntry(name: "Test Bar", metal: "gold", grams: 31.1035, pricePaidPerOz: 2_000, purchaseValue: 0,
                             manualValue: nil, location: "Safe", owner: ""),
                D.MetalEntry(name: "Test Coin", metal: "silver", grams: 31.1035, pricePaidPerOz: 0, purchaseValue: 30,
                             manualValue: nil, location: "Safe", owner: ""),
                D.MetalEntry(name: "Test Ring", metal: "gold", grams: 5, pricePaidPerOz: 0, purchaseValue: 0,
                             manualValue: 800, location: "", owner: ""),
            ],
            transactions: (1...12).map { day in
                D.TransactionEntry(
                    date: String(format: "2026-09-%02d", day), cost: Double(10 + day), actualCost: Double(10 + day),
                    merchant: "Shop \(day)", category: "Food", expense: "Groceries", breakDown: "",
                    card: day.isMultiple(of: 2) ? "Card Co - Travel" : "Card Co - Rewards"
                )
            }
        )
    }
    #endif
}
#endif
