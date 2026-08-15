import Core
import SwiftUI

struct AppSettingsView: View {
    @AppStorage(Appearance.defaultsKey) private var appearanceRaw = Appearance.system.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(Appearance.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows whatever the phone is set to, including its light and dark schedule.")
            }

            Section {
                LabeledContent("Sync", value: "iCloud")
            } footer: {
                Text("Everything you track syncs through your own iCloud account, so it comes back when you reinstall or set up another device.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
