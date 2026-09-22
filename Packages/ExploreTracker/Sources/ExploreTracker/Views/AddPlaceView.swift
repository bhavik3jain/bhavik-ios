import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import CoreData
import SwiftUI

struct AddPlaceView: View {
    let guide: SharedGuide

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var modelContext

    @State private var search: PlaceSearch
    @State private var chosen: Choice?
    @State private var resolvingID: String?
    @State private var lookupFailed = false
    @State private var category: PlaceCategory
    /// What Maps' category suggested, so the hint can disappear as soon as
    /// the reader picks something else.
    @State private var guessedCategory: PlaceCategory?
    @State private var manualName = ""
    @State private var manualAddress = ""
    @State private var note = ""
    @FocusState private var isSearchFocused: Bool

    private enum Choice: Equatable {
        case found(resultID: String, PlaceSearch.Resolved)
        case manual
    }

    private let areaLabel: String
    private let isBiased: Bool

    init(guide: SharedGuide, initialCategory: PlaceCategory) {
        self.guide = guide
        let region = GuideRegion.enclosing(guide.allPlaces.compactMap(\.point))
        _search = State(initialValue: PlaceSearch(region: region))
        _category = State(initialValue: initialCategory)
        areaLabel = guide.areaLabel.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        isBiased = region != nil
    }

    private var trimmedQuery: String {
        search.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        switch chosen {
        case .found: true
        case .manual: !manualName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case nil: false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Search Apple Maps", text: $search.query)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($isSearchFocused)
                } header: {
                    Text("to \(guide.name)")
                        .textCase(nil)
                } footer: {
                    Text(searchFootnote)
                }

                if !trimmedQuery.isEmpty {
                    Section {
                        // A handful is plenty: the completer can return a dozen,
                        // which pushed the category picker and note off screen.
                        ForEach(search.results.prefix(6)) { result in
                            resultRow(result)
                        }
                        Button {
                            chooseManual()
                        } label: {
                            HStack {
                                Label("Add “\(trimmedQuery)” by hand", systemImage: "square.and.pencil")
                                Spacer()
                                if chosen == .manual {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(ExploreTrackerModule.accent.color)
                                }
                            }
                        }
                    } footer: {
                        if lookupFailed {
                            Text("Apple Maps couldn't find that one's location. Add it by hand instead.")
                        }
                    }
                }

                if chosen == .manual {
                    Section {
                        TextField("Name", text: $manualName)
                        TextField("Address (optional)", text: $manualAddress, axis: .vertical)
                    } footer: {
                        Text("Places added by hand are listed in the guide but not shown on its map.")
                    }
                }

                Section {
                    Picker("File it under", selection: $category) {
                        ForEach(PlaceCategory.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    Text("File it under")
                } footer: {
                    if guessedCategory == category {
                        Text("Guessed from Apple Maps' category — change it if it's wrong.")
                    }
                }

                Section("Note") {
                    TextField("What's it for? e.g. go before 11:30", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle("Add a Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onAppear { isSearchFocused = true }
        }
    }

    private var searchFootnote: String {
        guard isBiased else { return "Searching everywhere. Once the guide has a place, search leans toward where its places are." }
        return areaLabel.isEmpty ? "Searching around this guide's places." : "Searching around this guide's places in \(areaLabel)."
    }

    private func resultRow(_ result: PlaceSearch.Result) -> some View {
        Button {
            Task { await choose(result) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .font(.title3)
                    .foregroundStyle(ExploreTrackerModule.accent.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .foregroundStyle(.primary)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if resolvingID == result.id {
                    ProgressView()
                } else if case .found(let id, _) = chosen, id == result.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(ExploreTrackerModule.accent.color)
                }
            }
            .contentShape(Rectangle())
        }
        // Plain, so a result reads as a place rather than as tinted link text.
        .buttonStyle(.plain)
    }

    private func choose(_ result: PlaceSearch.Result) async {
        resolvingID = result.id
        lookupFailed = false
        defer { resolvingID = nil }
        guard let resolved = await search.resolve(result) else {
            lookupFailed = true
            return
        }
        chosen = .found(resultID: result.id, resolved)
        category = resolved.category
        guessedCategory = resolved.category
        isSearchFocused = false
    }

    private func chooseManual() {
        chosen = .manual
        guessedCategory = nil
        lookupFailed = false
        if manualName.isEmpty { manualName = trimmedQuery }
        isSearchFocused = false
    }

    private func save() {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let place: SharedGuidePlace
        switch chosen {
        case .found(_, let resolved):
            place = SharedGuidePlace(
                context: modelContext,
                name: resolved.name,
                category: category,
                note: trimmedNote,
                address: resolved.address,
                latitude: resolved.point.latitude,
                longitude: resolved.point.longitude
            )
        case .manual:
            place = SharedGuidePlace(
                context: modelContext,
                name: manualName.trimmingCharacters(in: .whitespacesAndNewlines),
                category: category,
                note: trimmedNote,
                address: manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case nil:
            return
        }
        place.guide = guide
        try? modelContext.saveIfNeeded()
        dismiss()
    }
}
