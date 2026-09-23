import Core
import SwiftUI

/// Settings → Customize Trackers: show or hide each tracker and drag them into
/// the order the home screen (and the Mac sidebar and its ⌘-number shortcuts)
/// lists them in. Every change lands in `TrackerLayoutStore` straight away and
/// syncs to the user's other devices from there.
struct CustomizeTrackersView: View {
    @ObservedObject private var layoutStore = TrackerLayoutStore.shared

    var body: some View {
        List {
            Section {
                ForEach(layoutStore.allModules) { module in
                    Toggle(isOn: visibility(of: module)) {
                        HStack(spacing: 12) {
                            Image(systemName: module.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(module.accent.color, in: RoundedRectangle(cornerRadius: 7))
                            Text(module.accent.name)
                        }
                    }
                    .toggleStyle(.switch)
                    // Only ever disables a switch that's on: the last one left
                    // showing can't be turned off, or the hub would be empty.
                    .disabled(!layoutStore.isHidden(module) && !layoutStore.canHide(module))
                }
                .onMove { source, destination in
                    layoutStore.move(fromOffsets: source, toOffset: destination)
                }
            } footer: {
                Text(footer)
            }

            Section {
                Button("Reset to Default") {
                    layoutStore.reset()
                }
                .disabled(layoutStore.isDefault)
            }
        }
        .navigationTitle("Customize Trackers")
        .navigationBarTitleDisplayMode(.inline)
        #if os(iOS)
        // iOS only shows drag handles in edit mode, and an Edit button to get
        // there would be a step with nothing else behind it. macOS drags a
        // List row with `onMove` alone, and has no edit mode to set.
        .environment(\.editMode, .constant(.active))
        #endif
    }

    private func visibility(of module: SelectedModule) -> Binding<Bool> {
        Binding {
            !layoutStore.isHidden(module)
        } set: { isVisible in
            layoutStore.setHidden(!isVisible, for: module)
        }
    }

    private var footer: String {
        #if os(macOS)
        "Hiding a tracker only removes it from the sidebar. Nothing is deleted, and its data keeps syncing."
        #else
        "Hiding a tracker only removes it from the home screen. Nothing is deleted, and its data keeps syncing."
        #endif
    }
}
