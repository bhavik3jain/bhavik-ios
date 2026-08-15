import SwiftUI

struct ParcelSettingsView: View {
    @AppStorage(ParcelTrackerModule.fedExKeyDefaultsKey) private var fedExKey = ""
    @AppStorage(ParcelTrackerModule.fedExSecretDefaultsKey) private var fedExSecret = ""

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
                    Text("A free account at developer.fedex.com provides an API key and secret. They're stored on this device.")
                }

                Section {
                    LabeledContent("UPS", value: "Not set up")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("UPS credentials come from developer.ups.com. Support for them isn't wired up yet.")
                }

                Section {
                    LabeledContent("USPS", value: "Manual only")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Since April 2026 USPS only serves tracking to whoever shipped the parcel, so USPS parcels are kept here by hand with a link out to USPS.")
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
