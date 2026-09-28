import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import CoreData
import SwiftUI

/// New Guide, or editing an existing one's name and area.
///
/// There is no location field on purpose: a guide's map and weather come from
/// its places, so the area is only a label and is never looked up.
struct GuideFormView: View {
    let guide: SharedGuide?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var modelContext

    @State private var name = ""
    @State private var areaLabel = ""
    @FocusState private var isNameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SheetStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .focused($isNameFocused)
                    TextField("Area (optional), e.g. Kyoto, Japan", text: $areaLabel)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("Add places to the guide and its map and weather follow them.")
                }
            }
            .navigationTitle(guide == nil ? "New Guide" : "Edit Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(guide == nil ? "Create" : "Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .onAppear {
                if let guide {
                    name = guide.name
                    areaLabel = guide.areaLabel
                } else {
                    isNameFocused = true
                }
            }
        }
    }

    private func save() {
        let area = areaLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if let guide {
            guide.name = trimmedName
            guide.areaLabel = area
        } else {
            _ = SharedGuide(context: modelContext, name: trimmedName, areaLabel: area)
        }
        try? modelContext.saveIfNeeded()
        dismiss()
    }
}
