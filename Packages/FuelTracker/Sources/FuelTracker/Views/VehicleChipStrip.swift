import Core
import CoreData
import SwiftUI

/// What a chip can ask the module to do. Raised to the root view because
/// switching tabs and presenting the add sheet are both its business.
enum VehicleChipAction {
    case select
    case logFillUp
    case showTrends
}

/// One capsule per vehicle, with its name and MPG, above the Vehicle and Trends
/// tabs.
///
/// Switching cars used to be a picker buried in a toolbar menu on the Vehicle
/// tab only, so the Trends tab drew one car's charts without ever naming it.
/// The strip makes the whole garage visible on both, and long-pressing a chip
/// reads a car's numbers without switching to it.
struct VehicleChipStrip: View {
    let summaries: [VehicleSummary]
    let selectedID: NSManagedObjectID?
    let perform: (VehicleChipAction, VehicleSummary) -> Void

    @Environment(\.moduleLayout) private var layout

    var body: some View {
        // With a single vehicle there is nothing to switch between, so the strip
        // is absent entirely rather than showing one chip that does nothing.
        // On the Mac the toolbar carries the switch instead — see
        // `vehicleSwitcher`, which is also what places this strip.
        if summaries.count > 1, layout == .tabs {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(summaries) { summary in
                        chip(for: summary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func chip(for summary: VehicleSummary) -> some View {
        let isSelected = summary.id == selectedID

        return Button {
            perform(.select, summary)
        } label: {
            HStack(spacing: 6) {
                Text(summary.name)
                    .fontWeight(.semibold)
                Text(VehicleSummary.mpgText(summary.averageMPG))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
            }
            .font(.subheadline)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                isSelected ? AnyShapeStyle(FuelTrackerModule.accent.color) : AnyShapeStyle(.fill.tertiary),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        // Every fact in the preview is also on the chip or in the menu: on a Mac
        // the preview is not shown at all and this degrades to a right-click
        // menu, so nothing may live only in the peek.
        .contextMenu {
            if !isSelected {
                Button {
                    perform(.select, summary)
                } label: {
                    Label("Switch to \(summary.name)", systemImage: "car.2.fill")
                }
            }
            Button {
                perform(.logFillUp, summary)
            } label: {
                Label("Log a fill-up", systemImage: "plus")
            }
            Button {
                perform(.showTrends, summary)
            } label: {
                Label("Show trends", systemImage: "chart.xyaxis.line")
            }
        } preview: {
            VehiclePeekCard(summary: summary)
        }
        .accessibilityLabel(accessibilityLabel(for: summary, isSelected: isSelected))
    }

    private func accessibilityLabel(for summary: VehicleSummary, isSelected: Bool) -> String {
        let economy = summary.averageMPG.map { "\(VehicleSummary.mpgText($0)) miles per gallon" } ?? "no fuel economy yet"
        return isSelected ? "\(summary.name), selected, \(economy)" : "\(summary.name), \(economy)"
    }
}

/// Puts the vehicle switch on a Fuel screen that shows one car: the chip strip
/// above it on the phone, a segmented control in the toolbar on the Mac. Every
/// screen that depends on the selected car goes through this, so they all
/// switch the same way and share `FuelRootView`'s one selection.
///
/// The phone's log lost its chips once pull-to-refresh came to it: the strip
/// sat in a VStack of its own inside `.refreshesFromCloud()`, which reaches
/// every scroll view below it, so the strip's horizontal ScrollView became a
/// pull-to-refresh view too and never showed under the large title. The only
/// way left to change car was the strip on Trends, which has no refresh (the
/// user's report: "I have to go to Trends to change a car"). Apply this *after* any
/// `.refreshesFromCloud()`, so the refresh covers the content and not the
/// strip.
///
/// On the Mac the cars go at the leading edge of the toolbar, where the
/// window's title would sit. A strip of capsules under a desktop toolbar read
/// as a second toolbar. The title goes when the switcher shows, since the
/// selected segment already names the car — otherwise "My X3" sat beside a
/// segment reading "My X3".
///
/// `badge` ("Shared with Priya") goes under the chips on the phone and beside
/// the switcher on the Mac. Removing the title took `.moduleSubtitle` with it,
/// so a shared car said so nowhere on the Mac exactly when there were several
/// to tell apart.
private struct VehicleSwitcher: ViewModifier {
    let summaries: [VehicleSummary]
    let selectedID: NSManagedObjectID?
    let badge: String?
    let perform: (VehicleChipAction, VehicleSummary) -> Void

    @Environment(\.moduleLayout) private var layout

    private var selection: Binding<NSManagedObjectID?> {
        Binding {
            selectedID
        } set: { id in
            if let summary = summaries.first(where: { $0.id == id }) {
                perform(.select, summary)
            }
        }
    }

    func body(content: Content) -> some View {
        if layout == .sidebar {
            if summaries.count > 1 {
                content
                    .toolbar(removing: .title)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Picker("Vehicle", selection: selection) {
                                ForEach(summaries) { summary in
                                    Text(summary.name).tag(Optional(summary.id))
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                        if let badge {
                            ToolbarItem(placement: .navigation) {
                                Text(badge)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                        }
                    }
            } else {
                content
            }
        } else {
            VStack(spacing: 0) {
                VehicleChipStrip(summaries: summaries, selectedID: selectedID, perform: perform)

                if let badge {
                    Label(badge, systemImage: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }

                content
            }
        }
    }
}

extension View {
    func vehicleSwitcher(
        summaries: [VehicleSummary],
        selectedID: NSManagedObjectID?,
        badge: String? = nil,
        perform: @escaping (VehicleChipAction, VehicleSummary) -> Void
    ) -> some View {
        modifier(VehicleSwitcher(summaries: summaries, selectedID: selectedID, badge: badge, perform: perform))
    }
}
