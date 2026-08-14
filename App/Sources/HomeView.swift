import Core
import FuelTracker
import GymTracker
import SwiftData
import SwiftUI

struct HomeView: View {
    @State private var selectedModule: SelectedModule?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ModuleTile(
                        accent: GymTrackerModule.accent,
                        icon: "dumbbell.fill",
                        subtitle: gymSubtitle
                    ) {
                        selectedModule = .gym
                    }

                    ModuleTile(
                        accent: .init(name: "TV", color: .indigo),
                        icon: "tv.fill",
                        subtitle: "Coming soon",
                        isEnabled: false
                    ) {}

                    ModuleTile(
                        accent: FuelTrackerModule.accent,
                        icon: "fuelpump.fill",
                        subtitle: "Fill-ups, MPG, and cost"
                    ) {
                        selectedModule = .fuel
                    }
                }
                .padding()
            }
            .navigationTitle("Trackers")
            .fullScreenCover(item: $selectedModule) { module in
                switch module {
                case .gym:
                    GymTrackerModule.rootView()
                case .fuel:
                    FuelTrackerModule.rootView()
                }
            }
        }
    }

    private var gymSubtitle: String {
        "Log workouts, track progress"
    }
}

private enum SelectedModule: String, Identifiable {
    case gym
    case fuel
    var id: String { rawValue }
}

private struct ModuleTile: View {
    let accent: ModuleAccent
    let icon: String
    let subtitle: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(accent.color, in: RoundedRectangle(cornerRadius: 8))

                Spacer(minLength: 0)

                Text(accent.name)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(accent.color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .padding(14)
            .background(accent.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.6)
    }
}
