import Core
import CoreData
import SwiftUI

/// TV's Lists tab: this person's watch lists, then the ones shared with them.
///
/// Lists live in TV's own Core Data store (`TVListModel`), not the SwiftData
/// library the other tabs read — this view's `\.managedObjectContext` is that
/// store's, set by `TVTrackerModule.rootView(context:container:section:)`.
struct WatchListsView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.tvListPersistentContainer) private var container
    @Environment(\.presentShareSheet) private var presentShareSheet
    @FetchRequest(fetchRequest: SharedWatchList.fetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \SharedWatchList.createdAt, ascending: false)]
    ))
    private var listResults: FetchedResults<SharedWatchList>

    @State private var opened: SharedWatchList?
    @State private var addingList = false
    @State private var renaming: SharedWatchList?
    @State private var nameDraft = ""
    @State private var pendingRemoval: SharedWatchList?
    @State private var failure: String?

    private var lists: [SharedWatchList] { listResults.filter { !$0.isDeleted } }
    private var ownLists: [SharedWatchList] { lists.filter { WatchListOwnership.isOwn($0, in: container) } }
    private var sharedLists: [SharedWatchList] { lists.filter { !WatchListOwnership.isOwn($0, in: container) } }

    var body: some View {
        NavigationStack {
            Group {
                if lists.isEmpty {
                    ContentUnavailableView {
                        Label("No lists yet", systemImage: "list.bullet.rectangle.portrait")
                    } description: {
                        Text("Start a list of shows and films to watch with someone, then share it so they can add to it too.")
                    } actions: {
                        Button("New List") { startAdding() }
                            .primaryActionStyle(tint: TVTrackerModule.accent.color)
                    }
                    .scrollsForRefresh()
                } else {
                    List {
                        if !ownLists.isEmpty {
                            Section {
                                ForEach(ownLists) { row(for: $0) }
                            } header: {
                                if !sharedLists.isEmpty { Text("Your Lists") }
                            }
                        }
                        if !sharedLists.isEmpty {
                            Section {
                                ForEach(sharedLists) { row(for: $0) }
                            } header: {
                                Text("Shared with You")
                            } footer: {
                                Text("Leaving a list someone shared with you takes it off your devices only; it stays theirs.")
                            }
                        }
                    }
                    .readableWidthInSidebar()
                }
            }
            .refreshesFromCloud()
            .navigationTitle("Lists")
            .navigationDestination(item: $opened) { WatchListDetailView(list: $0) }
            .debugOpensFirstItem { opened = lists.first }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        startAdding()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New list")
                }
            }
            .textPrompt("New List", isPresented: $addingList, text: $nameDraft, prompt: "Name", actionTitle: "Create") {
                createList()
            }
            .textPrompt(
                "Rename List",
                isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                text: $nameDraft,
                prompt: "Name",
                actionTitle: "Rename"
            ) {
                rename()
            }
            .confirmationDialog(
                removalTitle,
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible,
                presenting: pendingRemoval
            ) { list in
                if WatchListOwnership.isOwn(list, in: container) {
                    Button("Delete List", role: .destructive) { delete(list) }
                } else {
                    Button("Leave List", role: .destructive) { leave(list) }
                }
            } message: { list in
                Text(removalMessage(for: list))
            }
            .alert(
                "Couldn't Leave the List",
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
    }

    private func row(for list: SharedWatchList) -> some View {
        let isOwn = WatchListOwnership.isOwn(list, in: container)
        let canEdit = WatchListOwnership.canEdit(list, in: container)
        return NavigationLink {
            WatchListDetailView(list: list)
        } label: {
            WatchListRow(list: list)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Red explicitly: the module's purple tint otherwise wins, and
            // removing looked like any other action.
            Button(isOwn ? "Delete" : "Leave", systemImage: isOwn ? "trash" : "rectangle.portrait.and.arrow.right", role: .destructive) {
                pendingRemoval = list
            }
            .tint(.red)
        }
        .contextMenu {
            if canEdit {
                Button("Rename", systemImage: "pencil") { startRenaming(list) }
            }
            if let container {
                Button("Share List", systemImage: "person.crop.circle.badge.plus") {
                    presentShareSheet(ShareSheetRequest(object: list, container: container))
                }
            }
            Divider()
            Button(isOwn ? "Delete List" : "Leave List", systemImage: isOwn ? "trash" : "rectangle.portrait.and.arrow.right", role: .destructive) {
                pendingRemoval = list
            }
        }
    }

    private var removalTitle: String {
        guard let list = pendingRemoval else { return "Remove list?" }
        return WatchListOwnership.isOwn(list, in: container) ? "Delete “\(list.displayName)”?" : "Leave “\(list.displayName)”?"
    }

    private func removalMessage(for list: SharedWatchList) -> String {
        let count = list.allItems.count
        guard WatchListOwnership.isOwn(list, in: container) else {
            return "It comes off your devices. Whoever shared it keeps it, and can share it with you again."
        }
        let items = count == 0 ? "It has nothing on it yet." : "Its \(counted(count, "title")) will be deleted too."
        if let container, case .owned = SharingStatusResolver.badgeStatus(for: list, in: container) {
            return "\(items) It's shared, so it goes for everyone you share it with."
        }
        return items
    }

    private func startAdding() {
        nameDraft = ""
        addingList = true
    }

    private func startRenaming(_ list: SharedWatchList) {
        nameDraft = list.name
        renaming = list
    }

    private func createList() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let list = SharedWatchList(context: context, name: name)
        try? context.saveIfNeeded()
        opened = list
    }

    private func rename() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let list = renaming, !name.isEmpty else { return }
        if list.name != name { list.name = name }
        try? context.saveIfNeeded()
        renaming = nil
    }

    /// The owner's delete: the list and everything on it, for everyone it's
    /// shared with.
    private func delete(_ list: SharedWatchList) {
        context.delete(list)
        try? context.saveIfNeeded()
        pendingRemoval = nil
    }

    /// A participant's way out. Deleting a list shared with you would ask
    /// CloudKit to delete the owner's own list; leaving drops the share
    /// instead and takes the local copy with it. See
    /// `leaveShareInBackground`.
    private func leave(_ list: SharedWatchList) {
        pendingRemoval = nil
        guard let container else { return }
        let id = list.objectID
        Task {
            let message = await withCheckedContinuation { (finished: CheckedContinuation<String?, Never>) in
                container.leaveShareInBackground(of: id) { error in
                    finished.resume(returning: error?.localizedDescription)
                }
            }
            SharingStatusCache.shared.invalidateAll()
            if let message { failure = message }
        }
    }
}

/// One list in the Lists tab: its name, what's on it, and whether it's shared.
private struct WatchListRow: View {
    @ObservedObject var list: SharedWatchList
    @Environment(\.tvListPersistentContainer) private var container

    private var sharingLabel: String? {
        guard let container else { return nil }
        return SharingStatusResolver.badgeStatus(for: list, in: container).watchListBadgeLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(list.displayName)
                    .font(.headline)
                    .lineLimit(2)
                if let sharingLabel {
                    Label(sharingLabel, systemImage: "person.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
            Text(list.countsLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
