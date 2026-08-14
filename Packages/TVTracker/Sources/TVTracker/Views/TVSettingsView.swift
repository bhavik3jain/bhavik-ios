import SwiftUI

struct TVSettingsView: View {
    @AppStorage(TVTrackerModule.apiKeyDefaultsKey) private var apiKey = ""
    @State private var draft = ""
    @State private var checkState: CheckState = .idle

    private enum CheckState {
        case idle
        case checking
        case valid
        case invalid(String)
    }

    var body: some View {
        Form {
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
                Text("A free TMDB account provides an API key for personal use. It's stored on this device and used only to look up shows and episodes — what you've watched is stored in your own iCloud account.")
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
