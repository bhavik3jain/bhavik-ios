import Core
import CoreData
import SwiftData
import SwiftUI

/// One watch list: what's still to watch, in the order chosen on this device,
/// then what's been watched together.
struct WatchListDetailView: View {
    @ObservedObject var list: SharedWatchList

    @Environment(\.managedObjectContext) private var context
    @Environment(\.tvListPersistentContainer) private var container
    @Environment(\.presentShareSheet) private var presentShareSheet
    /// This person's own library — SwiftData, never shared — for "In your
    /// library" and "Add to My Library".
    @Environment(\.modelContext) private var libraryContext
    @Query private var shows: [Show]
    @Query private var movies: [Movie]
    @SyncedSecret(TVTrackerModule.apiKeyDefaultsKey) private var apiKey
    @AppStorage(WatchListOrder.defaultsKey) private var orderRaw = WatchListOrder.custom.rawValue
    /// Fetched rather than read off `list.items`, so an item a partner adds,
    /// ticks off or reorders redraws the screen when it's imported.
    @FetchRequest private var itemResults: FetchedResults<SharedWatchListItem>

    @State private var showingAdd = false
    @State private var renaming = false
    @State private var editingNotes = false
    @State private var nameDraft = ""
    @State private var libraryProblem: String?

    init(list: SharedWatchList) {
        self.list = list
        _itemResults = FetchRequest(fetchRequest: SharedWatchListItem.fetchRequest(
            predicate: NSPredicate(format: "list == %@", list),
            sortDescriptors: [NSSortDescriptor(keyPath: \SharedWatchListItem.addedAt, ascending: false)]
        ))
    }

    private var order: WatchListOrder { WatchListOrder(rawValue: orderRaw) ?? .custom }
    private var items: [SharedWatchListItem] { itemResults.filter { !$0.isDeleted } }
    private var toWatch: [SharedWatchListItem] { WatchListOrdering.toWatch(items, order: order, key: \.orderingKey) }
    private var watched: [SharedWatchListItem] { WatchListOrdering.watched(items, key: \.orderingKey) }
    private var library: LibraryIndex { LibraryIndex(shows: shows, movies: movies) }
    private var isGone: Bool { list.isDeleted || list.managedObjectContext == nil }

    private var canEdit: Bool { WatchListOwnership.canEdit(list, in: container) }
    private var sharingLabel: String? {
        guard let container else { return nil }
        return SharingStatusResolver.badgeStatus(for: list, in: container).watchListBadgeLabel
    }

    var body: some View {
        if isGone {
            // Deleted on another device, or left, while it was open.
            ContentUnavailableView("This list is gone", systemImage: "list.bullet.rectangle.portrait", description: Text("It was deleted, or you left it."))
        } else {
            content
        }
    }

    private var content: some View {
        listBody
            .readableWidthInSidebar()
            .refreshesFromCloud()
            .navigationTitle(list.displayName)
            .moduleSubtitle(list.countsLine)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .modifier(presentations)
            // Two devices adding the same title offline both keep theirs; the
            // list folds them as soon as either of them shows it.
            .task(id: items.map(\.objectID)) { foldDuplicates() }
    }

    private var listBody: some View {
        let library = library
        let toWatch = toWatch
        let watched = watched
        let canEdit = canEdit
        let notes = list.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let move: ((IndexSet, Int) -> Void)? = canEdit && order == .custom ? { moveToWatch(from: $0, to: $1) } : nil
        let deleteToWatch: ((IndexSet) -> Void)? = canEdit ? { remove(toWatch, at: $0) } : nil
        let deleteWatched: ((IndexSet) -> Void)? = canEdit ? { remove(watched, at: $0) } : nil
        return List {
            Section {
                if items.isEmpty {
                    Text(canEdit
                         ? "Nothing on it yet. Add a show or a film, and whoever you share it with can add theirs."
                         : "Nothing on it yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(toWatch) { item in
                    itemLink(item, inLibrary: library.contains(item.watchListTitle), canEdit: canEdit)
                }
                .onMove(perform: move)
                .onDelete(perform: deleteToWatch)
            } header: {
                HStack(spacing: 6) {
                    Text(toWatch.isEmpty && !items.isEmpty ? "All watched" : "To Watch")
                    if let sharingLabel {
                        Label(sharingLabel, systemImage: "person.2.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }

            if !watched.isEmpty {
                Section("Watched Together") {
                    ForEach(watched) { item in
                        itemLink(item, inLibrary: library.contains(item.watchListTitle), canEdit: canEdit)
                    }
                    .onDelete(perform: deleteWatched)
                }
            }

            if !notes.isEmpty {
                Section("Notes") {
                    Text(notes)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        let canEdit = canEdit
        ToolbarItemGroup(placement: .primaryAction) {
            if canEdit && order == .custom && toWatch.count > 1 {
                EditButton()
            }
            if canEdit {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add to list")
            }
            Menu {
                Picker("Order", selection: $orderRaw) {
                    ForEach(WatchListOrder.allCases) { order in
                        Text(order.title).tag(order.rawValue)
                    }
                }
                if canEdit {
                    Button("Rename", systemImage: "pencil") {
                        nameDraft = list.name
                        renaming = true
                    }
                    Button("Edit Notes", systemImage: "note.text") { editingNotes = true }
                }
                if let container {
                    Button("Share List", systemImage: "person.crop.circle.badge.plus") {
                        presentShareSheet(ShareSheetRequest(object: list, container: container))
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("List options")
        }
    }

    private var presentations: WatchListPresentations {
        WatchListPresentations(
            list: list,
            showingAdd: $showingAdd,
            editingNotes: $editingNotes,
            renaming: $renaming,
            nameDraft: $nameDraft,
            libraryProblem: $libraryProblem
        )
    }
}

/// The detail screen's sheets, prompt and alert, apart so the screen's own
/// body stays small enough for the type checker.
private struct WatchListPresentations: ViewModifier {
    @ObservedObject var list: SharedWatchList
    @Binding var showingAdd: Bool
    @Binding var editingNotes: Bool
    @Binding var renaming: Bool
    @Binding var nameDraft: String
    @Binding var libraryProblem: String?
    @Environment(\.managedObjectContext) private var context

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingAdd) {
                AddToWatchListView(list: list)
            }
            .sheet(isPresented: $editingNotes) {
                WatchListNoteEditor(title: "Notes", text: list.notes, prompt: "What's this list for?") { notes in
                    if list.notes != notes { list.notes = notes }
                    try? context.saveIfNeeded()
                }
            }
            .textPrompt("Rename List", isPresented: $renaming, text: $nameDraft, prompt: "Name", actionTitle: "Rename") {
                let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != list.name else { return }
                list.name = name
                try? context.saveIfNeeded()
            }
            .alert(
                "Add to My Library",
                isPresented: Binding(get: { libraryProblem != nil }, set: { if !$0 { libraryProblem = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(libraryProblem ?? "")
            }
    }
}

private extension WatchListDetailView {
    func itemLink(_ item: SharedWatchListItem, inLibrary: Bool, canEdit: Bool) -> some View {
        NavigationLink {
            WatchListItemView(item: item)
        } label: {
            WatchListItemRow(item: item, inLibrary: inLibrary, canEdit: canEdit) {
                toggleWatched(item)
            }
        }
        .swipeActions(edge: .leading) {
            if canEdit {
                Button(item.isWatched ? "To Watch" : "Watched", systemImage: item.isWatched ? "arrow.uturn.backward" : "checkmark") {
                    toggleWatched(item)
                }
                .tint(TVTrackerModule.accent.color)
            }
        }
        .contextMenu {
            if canEdit {
                Button(item.isWatched ? "Move Back to Watch" : "Mark Watched Together", systemImage: item.isWatched ? "arrow.uturn.backward" : "checkmark.circle") {
                    toggleWatched(item)
                }
            }
            if inLibrary {
                Label("In Your Library", systemImage: "checkmark")
            } else {
                Button("Add to My Library", systemImage: "plus.rectangle.on.rectangle") { addToLibrary(item) }
            }
            if canEdit {
                Divider()
                Button("Remove from List", systemImage: "trash", role: .destructive) {
                    context.delete(item)
                    try? context.saveIfNeeded()
                }
            }
        }
    }

    func toggleWatched(_ item: SharedWatchListItem) {
        guard canEdit else { return }
        withAnimation { item.setWatched(!item.isWatched) }
        try? context.saveIfNeeded()
    }

    func moveToWatch(from source: IndexSet, to destination: Int) {
        moveWatchListItems(toWatch, from: source, to: destination)
        try? context.saveIfNeeded()
    }

    func remove(_ shown: [SharedWatchListItem], at offsets: IndexSet) {
        for index in offsets where shown.indices.contains(index) {
            context.delete(shown[index])
        }
        try? context.saveIfNeeded()
    }

    func addToLibrary(_ item: SharedWatchListItem) {
        let title = item.watchListTitle
        Task {
            let outcome = await TVLibrary.add(title, apiKey: apiKey, to: libraryContext)
            try? libraryContext.save()
            libraryProblem = TVLibrary.problem(after: outcome, adding: title, apiKey: apiKey)
        }
    }

    /// Only a list this device may change, and only when there's something
    /// to fold — `foldDuplicates` writes nothing otherwise, but the check is
    /// cheaper than asking CloudKit whether the list can be edited.
    func foldDuplicates() {
        guard !isGone, !WatchListDuplicates.folds(items.map(\.entry)).isEmpty, canEdit else { return }
        list.foldDuplicates()
        try? context.saveIfNeeded()
    }
}

/// One title on a list. The circle ticks it off in place, as in Movies; the
/// rest of the row opens it.
struct WatchListItemRow: View {
    @ObservedObject var item: SharedWatchListItem
    let inLibrary: Bool
    let canEdit: Bool
    let toggleWatched: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleWatched) {
                Image(systemName: item.isWatched ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isWatched ? TVTrackerModule.accent.color : .secondary)
            }
            // Borderless, or the whole row's tap goes to this button and the
            // link never opens.
            .buttonStyle(.borderless)
            .disabled(!canEdit)
            .accessibilityLabel(item.isWatched ? "Move \(item.title) back to watch" : "Mark \(item.title) watched")

            PosterView(path: item.posterPath, width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Text(WatchListItemText.detailLine(kind: item.kindLine, addedByName: item.addedByName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if inLibrary {
                    Label("In your library", systemImage: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(TVTrackerModule.accent.color)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A few lines of text in a sheet of their own — a list's notes, an item's
/// note. Saved once, on Done: a write per keystroke would be an iCloud upload
/// per keystroke, and a notification on the partner's phone for each.
struct WatchListNoteEditor: View {
    let title: String
    let prompt: String
    let save: (String) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(title: String, text: String, prompt: String, save: @escaping (String) -> Void) {
        self.title = title
        self.prompt = prompt
        self.save = save
        _text = State(initialValue: text)
    }

    var body: some View {
        SheetStack {
            Form {
                TextField(prompt, text: $text, axis: .vertical)
                    .lineLimit(3...10)
                    .focused($focused)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { focused = true }
        }
    }
}
