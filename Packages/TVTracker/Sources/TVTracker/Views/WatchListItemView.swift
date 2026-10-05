import Core
import CoreData
import SwiftData
import SwiftUI

/// One title on a watch list: what it is, its note, whether it's been
/// watched together, and a way into this person's own library.
struct WatchListItemView: View {
    @ObservedObject var item: SharedWatchListItem

    @Environment(\.managedObjectContext) private var context
    @Environment(\.tvListPersistentContainer) private var container
    @Environment(\.modelContext) private var libraryContext
    @Environment(\.dismiss) private var dismiss
    @Query private var shows: [Show]
    @Query private var movies: [Movie]
    @SyncedSecret(TVTrackerModule.apiKeyDefaultsKey) private var apiKey

    @State private var editingNote = false
    @State private var addingToLibrary = false
    @State private var libraryProblem: String?

    private var isGone: Bool { item.isDeleted || item.managedObjectContext == nil }
    private var canEdit: Bool { WatchListOwnership.canEdit(item, in: container) }
    private var inLibrary: Bool { LibraryIndex(shows: shows, movies: movies).contains(item.watchListTitle) }

    var body: some View {
        if isGone {
            ContentUnavailableView("Not on the list any more", systemImage: "list.bullet.rectangle.portrait", description: Text("It was removed, maybe on another device."))
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    PosterView(path: item.posterPath, width: 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.title3)
                            .fontWeight(.semibold)
                        Label(item.kindLine, systemImage: item.mediaType.systemImage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let list = item.list {
                            Text("On \(list.displayName)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                let overview = item.overview.trimmingCharacters(in: .whitespacesAndNewlines)
                if !overview.isEmpty {
                    Text(overview)
                        .font(.callout)
                }
            }

            Section {
                Toggle("Watched Together", isOn: Binding(
                    get: { item.isWatched },
                    set: { watched in
                        guard watched != item.isWatched else { return }
                        item.setWatched(watched)
                        try? context.saveIfNeeded()
                    }
                ))
                .disabled(!canEdit)
                if let watchedAt = item.watchedAt {
                    LabeledContent("Watched", value: watchedAt.formatted(date: .abbreviated, time: .omitted))
                }
                LabeledContent("Added", value: WatchListItemText.addedLine(at: item.addedAt, by: item.addedByName))
            }

            Section("Note") {
                let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty {
                    Text(note)
                }
                if canEdit {
                    Button(note.isEmpty ? "Add a Note" : "Edit Note", systemImage: "note.text") { editingNote = true }
                } else if note.isEmpty {
                    Text("No note.").foregroundStyle(.secondary)
                }
            }

            Section {
                if inLibrary {
                    Label("In your library", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(TVTrackerModule.accent.color)
                } else {
                    Button {
                        addToLibrary()
                    } label: {
                        HStack {
                            Label("Add to My Library", systemImage: "plus.rectangle.on.rectangle")
                            if addingToLibrary {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(addingToLibrary)
                }
            } footer: {
                Text(item.mediaType == .show
                     ? "Adds it to your own Watching tab, which isn't shared."
                     : "Adds it to your own Movies tab, which isn't shared.")
            }

            if canEdit {
                Section {
                    Button("Remove from List", systemImage: "trash", role: .destructive) {
                        context.delete(item)
                        try? context.saveIfNeeded()
                        dismiss()
                    }
                }
            }
        }
        .readableWidthInSidebar()
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editingNote) {
            WatchListNoteEditor(title: "Note", text: item.note, prompt: "Why watch it, who suggested it…") { note in
                if item.note != note { item.note = note }
                try? context.saveIfNeeded()
            }
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

    private func addToLibrary() {
        let title = item.watchListTitle
        addingToLibrary = true
        Task {
            let outcome = await TVLibrary.add(title, apiKey: apiKey, to: libraryContext)
            try? libraryContext.save()
            addingToLibrary = false
            libraryProblem = TVLibrary.problem(after: outcome, adding: title, apiKey: apiKey)
        }
    }
}
