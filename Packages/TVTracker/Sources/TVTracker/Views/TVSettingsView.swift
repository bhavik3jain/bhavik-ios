import Core
import SwiftData
import SwiftUI

struct TVSettingsView: View {
    @SyncedSecret(TVTrackerModule.apiKeyDefaultsKey) private var apiKey
    @State private var draft = ""
    @State private var checkState: CheckState = .idle

    private enum CheckState {
        case idle
        case checking
        case valid
        case invalid(String)
    }

    @Query private var shows: [Show]
    @Query private var movies: [Movie]

    private var watchedEpisodes: Int {
        shows.reduce(0) { $0 + $1.watchedCount }
    }

    var body: some View {
        Form {
            Section("Watching") {
                LabeledContent("Episodes watched", value: "\(watchedEpisodes)")
                LabeledContent("Shows completed", value: "\(shows.count { $0.status == .completed })")
                LabeledContent("Movies watched", value: "\(movies.count(where: \.isWatched))")
            }

            if !shows.isEmpty {
                Section("Progress") {
                    ForEach(shows.sorted { $0.progress > $1.progress }) { show in
                        HStack {
                            Text(show.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            Text("\(show.watchedCount)/\(show.episodeCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }

            Section {
                SecureField("TMDB API key", text: $draft)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button("Save and check") {
                    Task { await saveAndCheck() }
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)

                switch checkState {
                case .idle:
                    EmptyView()
                case .checking:
                    HStack {
                        ProgressView()
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                case .valid:
                    Label("Key works", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .invalid(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Metadata")
            } footer: {
                Text("A free TMDB account provides an API key for personal use. It's kept in your iCloud Keychain and used only to look up shows and episodes — what you've watched is stored in your own iCloud account.")
            }

            if !apiKey.isEmpty {
                Section {
                    Button("Remove key", role: .destructive) {
                        apiKey = ""
                        draft = ""
                        checkState = .idle
                    }
                }
            }

            Section {
                Text(TMDBClient.attribution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("TV Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = apiKey }
    }

    private func saveAndCheck() async {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        checkState = .checking
        do {
            _ = try await TMDBClient(apiKey: trimmed).searchShows(query: "test")
            apiKey = trimmed
            checkState = .valid
        } catch {
            checkState = .invalid(error.localizedDescription)
        }
    }
}
