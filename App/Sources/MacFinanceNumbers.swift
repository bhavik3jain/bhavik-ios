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
        case timedOut
        case script(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                "This build of Multitrack is missing \(name)."
            case .numbersNotInstalled:
                "Numbers isn’t installed. Get it from the App Store, then try again."
            case .notAllowed:
                "Multitrack isn’t allowed to control Numbers. Turn it on in System Settings › Privacy & Security › Automation › Multitrack, then try again."
            case .timedOut:
                "Numbers took too long to answer. If it's busy with another document, wait for it and export again."
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

            // Asked for here, and waited for as long as the person takes: the
            // Automation prompt used to appear only when the script's first
            // Apple event reached Numbers, and that event gave up after about
            // a minute — the first export from a new build ended in a Numbers
            // timeout while the "Multitrack wants to control Numbers" prompt
            // was still waiting (or had opened behind other windows).
            try await askPermissionToControlNumbers()

            try await run(source, argument: specURL.path)
            try? FileManager.default.removeItem(at: specURL)
            return output
        } catch {
            // A half-filled copy is worse than none.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// macOS's Automation permission for Numbers, asking if it hasn't been
    /// asked: blocks until the person answers, so on a thread of its own.
    /// Numbers must be running, which opening the copy above sees to.
    private static func askPermissionToControlNumbers() async throws {
        let status: OSStatus = await withCheckedContinuation { continuation in
            let thread = Thread {
                var target = AEAddressDesc()
                let created = numbersBundleID.withCString { bytes in
                    AECreateDesc(DescType(typeApplicationBundleID), bytes, strlen(bytes), &target)
                }
                guard created == noErr else {
                    continuation.resume(returning: OSStatus(created))
                    return
                }
                defer { AEDisposeDesc(&target) }
                continuation.resume(returning: AEDeterminePermissionToAutomateTarget(
                    &target, AEEventClass(typeWildCard), AEEventID(typeWildCard), true
                ))
            }
            thread.name = "Finance Numbers permission"
            thread.start()
        }
        switch status {
        case noErr:
            return
        case OSStatus(errAEEventNotPermitted):
            throw ExportError.notAllowed
        default:
            // -600 (Numbers not running yet) and anything unexpected: carry
            // on, and let the script's own first event ask, as before.
            return
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
        // -1712: an Apple event Numbers didn't answer in time. Said plainly;
        // the raw "AppleEvent timed out" meant nothing to the person exporting.
        if number == -1712 || message.contains("timed out") {
            return .timedOut
        }
        return .script(message.replacingOccurrences(of: "Error: ", with: ""))
    }

    #if DEBUG
    /// `-FinanceNumbersExportProbe YES` fills the template with a made-up
    /// month at launch and prints where the result went (`big` instead of
    /// `YES`: a made-up month the size of a real one — 30 accounts, 15 cards,
    /// 33 metals, 116 transactions — the size that timed out): the whole sandboxed
    /// path (Launch Services, Automation, OSAKit) without clicking through
    /// Finance or touching real data. Made up here because nothing outside
    /// the sandbox can put a file where the app could read it.
    @MainActor
    static func runProbeIfRequested() {
        guard let size = UserDefaults.standard.string(forKey: "FinanceNumbersExportProbe"), size != "NO" else { return }
        Task {
            do {
                let started = Date.now
                let output = try await fill(size == "big" ? bigProbeDocument : probeDocument)
                print("FinanceNumbersExportProbe: wrote \(output.path) in \(Int(Date.now.timeIntervalSince(started)))s")
                // Left open in Numbers: nothing outside the sandbox can read
                // the container's tmp folder to check the result any other way.
                NSWorkspace.shared.open(output)
            } catch {
                print("FinanceNumbersExportProbe: failed: \(error.localizedDescription)")
            }
        }
    }

    /// Made up, at the size of the user's real month.
    private static var bigProbeDocument: FinanceMonthDocument {
        typealias D = FinanceMonthDocument
        let owners = ["Alex", "Sam", ""]
        let categories = ["cash", "cash", "investments", "retirement", "cash", "fixed", "loan"]
        let cards = (1...15).map { index in
            D.CardEntry(institution: "Card Co \(index)", name: "Card \(index)", owner: owners[index % 3], limit: Double(1_000 * index), annualFee: index.isMultiple(of: 3) ? 95 : 0)
        }
        return D(
            month: "2026-09",
            metalPrices: D.Prices(gold: 4_300, silver: 65),
            owners: ["Alex", "Sam", "Joint"],
            accounts: (1...30).map { index in
                D.AccountEntry(category: categories[index % categories.count], institution: "Bank \(index % 6)", name: "Account \(index)",
                               owner: owners[index % 3], balance: Double(100 * index) + 0.25)
            },
            cards: cards,
            metals: (1...33).map { index in
                D.MetalEntry(name: "Item \(index)", metal: index <= 28 ? "gold" : "silver", grams: Double(index) * 2.5,
                             pricePaidPerOz: index.isMultiple(of: 4) ? 1_800 : 0, purchaseValue: 0,
                             manualValue: index.isMultiple(of: 16) ? 500 : nil, location: index.isMultiple(of: 2) ? "Safe" : "Box", owner: "")
            },
            transactions: (1...116).map { index in
                D.TransactionEntry(
                    date: String(format: "2026-09-%02d", 1 + index % 28), cost: Double(5 + index % 40), actualCost: Double(5 + index % 40),
                    merchant: "Shop \(index)", category: ["Food", "Travel", "Home"][index % 3], expense: "Expense \(index % 7)", breakDown: "",
                    card: "Card Co \(1 + index % 15) - Card \(1 + index % 15)"
                )
            }
        )
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
