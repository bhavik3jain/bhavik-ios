import Core
import SwiftData
import SwiftUI

/// Imports a TV library export.
///
/// Unlike the fuel importer this is not a parse — the export identifies
/// everything by TMDB id alone, so every title has to be looked up to get
/// episode lists and posters. A full library is several hundred round trips and
/// takes minutes, which is why this is a screen with progress and a cancel
/// button rather than a menu item that blocks.
struct LibraryImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @SyncedSecret(TVTrackerModule.apiKeyDefaultsKey) private var apiKey

    @State private var phase: Phase = .idle
    @State private var showingPicker = false
    @State private var task: Task<Void, Never>?
    /// Kept after the run so a resolved title can be re-imported with the watch
    /// history the export recorded against its broken id.
    @State private var export: LibraryExport?
    @State private var unresolved: [UnresolvedItem] = []
    @State private var resolving: UnresolvedItem?

    private enum Phase {
        case idle
        case working(done: Int, total: Int, title: String)
        case finished(LibraryImportSummary)
        case failed(String)
    }

    var body: some View {
        SheetStack {
            Form {
                switch phase {
                case .idle:
                    instructions
                case .working(let done, let total, let title):
                    progress(done: done, total: total, title: title)
                case .finished(let summary):
                    results(summary)
                case .failed(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("Try Again") { phase = .idle }
                    }
                }
            }
            .navigationTitle("Import Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isWorking ? "Stop" : "Done") {
                        task?.cancel()
                        if !isWorking { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(isWorking)
            .fileImporter(
                isPresented: $showingPicker,
                allowedContentTypes: [.commaSeparatedText, .text],
                // Both files at once: which is which is worked out from their
                // headers, so the order they're picked in doesn't matter.
                allowsMultipleSelection: true
            ) { result in
                start(with: result)
            }
        }
        .sheet(item: $resolving) { item in
            if let export {
                ResolveItemView(item: item, export: export, apiKey: apiKey) {
                    unresolved.removeAll { $0.id == item.id }
                }
            }
        }
        .onDisappear { task?.cancel() }
    }

    private var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    @ViewBuilder
    private var instructions: some View {
        Section {
            Text("Select **library.csv** and **watches.csv** from your export. Unzip it first — both files are needed.")
                .font(.subheadline)
        }

        Section {
            Button("Choose Files…") { showingPicker = true }
                .disabled(apiKey.isEmpty)
        } footer: {
            if apiKey.isEmpty {
                Text("Add a TMDB API key above first. The export only stores ids, so every show and film has to be looked up to get its episodes and artwork.")
                    .foregroundStyle(.orange)
            } else {
                Text("Every title is looked up on TMDB, so a full library takes a few minutes. Anything already in your library is left alone.")
            }
        }
    }

    @ViewBuilder
    private func progress(done: Int, total: Int, title: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(TVTrackerModule.accent.color)
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("\(done) of \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Stopping keeps everything imported so far.")
        }
    }

    @ViewBuilder
    private func results(_ summary: LibraryImportSummary) -> some View {
        Section("Imported") {
            LabeledContent("Shows", value: "\(summary.showsImported)")
            LabeledContent("Movies", value: "\(summary.moviesImported)")
            LabeledContent("Episodes watched", value: "\(summary.episodesMarkedWatched)")
            LabeledContent("Movies watched", value: "\(summary.moviesMarkedWatched)")
            if summary.specialsImported > 0 {
                LabeledContent("Specials", value: "\(summary.specialsImported)")
            }
        }

        if summary.showsAlreadyPresent + summary.moviesAlreadyPresent > 0 {
            Section("Already in your library") {
                if summary.showsAlreadyPresent > 0 {
                    LabeledContent("Shows", value: "\(summary.showsAlreadyPresent)")
                }
                if summary.moviesAlreadyPresent > 0 {
                    LabeledContent("Movies", value: "\(summary.moviesAlreadyPresent)")
                }
            }
        }

        // Tappable, because a list you can't act on is just a list of
        // complaints. Each row opens the same choice: point it at the right
        // thing, or drop it.
        if !unresolved.isEmpty {
            Section {
                ForEach(unresolved) { item in
                    Button {
                        resolving = item
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName)
                                    .foregroundStyle(.primary)
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("Couldn't be matched")
            } footer: {
                Text("Tap one to link it to the right show, film or episode — or to ignore it.")
            }
        }
    }

    private func start(with result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            if case .failure(let error) = result { phase = .failed(error.localizedDescription) }
            return
        }

        let key = apiKey
        task = Task { @MainActor in
            do {
                let parsed = try LibraryImporter.parse(fileURLs: urls)
                export = parsed
                phase = .working(done: 0, total: parsed.titleCount, title: "")

                let summary = try await LibraryImporter.run(
                    parsed,
                    apiKey: key,
                    into: modelContext
                ) { done, total, title in
                    phase = .working(done: done, total: total, title: title)
                }
                unresolved = summary.unresolved
                phase = .finished(summary)
            } catch is CancellationError {
                // Everything fetched so far was already saved, so this is a
                // stopping point rather than a failure.
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
