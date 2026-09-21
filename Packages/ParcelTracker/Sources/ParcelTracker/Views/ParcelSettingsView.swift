import Core
import SwiftUI

struct ParcelSettingsView: View {
    @SyncedSecret(ParcelTrackerModule.fedExKeyDefaultsKey) private var fedExKey
    @SyncedSecret(ParcelTrackerModule.fedExSecretDefaultsKey) private var fedExSecret

    @State private var keyDraft = ""
    @State private var secretDraft = ""
    @State private var checkState: CheckState = .idle

    private enum CheckState {
        case idle, checking, valid, invalid(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API key", text: $keyDraft)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("API secret", text: $secretDraft)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button("Save and check") {
                        Task { await saveAndCheck() }
                    }
                    .disabled(keyDraft.isEmpty || secretDraft.isEmpty)

                    switch checkState {
                    case .idle:
                        EmptyView()
                    case .checking:
                        HStack {
                            ProgressView()
                            Text("Checking…").foregroundStyle(.secondary)
                        }
                    case .valid:
                        Label("Credentials work", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .invalid(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("FedEx")
                } footer: {
                    Text("A free account at developer.fedex.com provides an API key and secret. They're kept in your iCloud Keychain, so they reach your other devices and survive reinstalling the app.")
                }

                Section {
                    LabeledContent("UPS", value: "Opens in browser")
                        .foregroundStyle(.secondary)
                    LabeledContent("USPS", value: "Opens in browser")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Other carriers")
                } footer: {
                    Text("These are kept here by hand: tap an order to open the carrier's own tracking page without leaving the app, then set its status. USPS stopped answering third parties in April 2026; UPS support just isn't built yet.")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                keyDraft = fedExKey
                secretDraft = fedExSecret
            }
        }
    }

    private func saveAndCheck() async {
        checkState = .checking
        let client = FedExClient(
            apiKey: keyDraft.trimmingCharacters(in: .whitespaces),
            apiSecret: secretDraft.trimmingCharacters(in: .whitespaces)
        )
        do {
            // FedEx publishes this number as a documentation sample, so it is
            // a safe way to prove the credentials work.
            _ = try await client.track("111111111111")
            fedExKey = keyDraft.trimmingCharacters(in: .whitespaces)
            fedExSecret = secretDraft.trimmingCharacters(in: .whitespaces)
            checkState = .valid
        } catch CarrierError.notFound {
            // Reaching the API at all means the credentials were accepted.
            fedExKey = keyDraft.trimmingCharacters(in: .whitespaces)
            fedExSecret = secretDraft.trimmingCharacters(in: .whitespaces)
            checkState = .valid
        } catch {
            checkState = .invalid(error.localizedDescription)
        }
    }
}
