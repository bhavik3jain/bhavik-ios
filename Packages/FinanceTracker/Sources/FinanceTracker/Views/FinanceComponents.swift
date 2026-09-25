import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import SwiftUI

/// The owner's initials in a small circle — "B", "S", "J" — on every account
/// and metal row. Grey for no one.
struct OwnerBadge: View {
    let owner: SharedFinanceOwner?

    var body: some View {
        Text(owner?.initials ?? "–")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(owner == nil ? Color.gray : FinanceTrackerModule.accent.color, in: Circle())
            .accessibilityLabel(owner?.name ?? "No one")
    }
}

/// A money field that writes as it's typed. Text-backed — see
/// `FinanceInput` for why `TextField(value:format:)` isn't used. `commit`
/// changes the model; `endEditing` runs when focus leaves, which is where the
/// caller saves.
struct AmountField: View {
    let title: String
    let value: Double
    let commit: (Double) -> Void
    var endEditing: () -> Void = {}

    @State private var text = ""
    @State private var loaded = false
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TextField(title, text: $text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focused)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                text = FinanceFormat.editable(value)
            }
            .onChange(of: text) { _, newText in
                guard focused, let parsed = FinanceInput.parse(newText), parsed != value else { return }
                commit(parsed)
            }
            .onChange(of: focused) { _, isFocused in
                guard !isFocused else { return }
                // A cleared field means zero, but only once the reader's done
                // with it — mid-edit an empty field is just a new figure
                // about to be typed.
                if text.trimmingCharacters(in: .whitespaces).isEmpty, value != 0 {
                    commit(0)
                }
                text = FinanceFormat.editable(FinanceInput.parse(text) ?? 0)
                endEditing()
            }
            // Leaving the app mid-edit never moves focus, so the figure typed
            // was changed in memory but never saved, and lost if the system
            // then ended the app.
            .onChange(of: scenePhase) { _, phase in
                guard focused, phase != .active else { return }
                endEditing()
            }
            // A partner's edit arriving while the field isn't being typed in.
            .onChange(of: value) { _, newValue in
                guard !focused else { return }
                text = FinanceFormat.editable(newValue)
            }
    }
}

/// A rounded selectable chip — card filters, categories, locations.
struct FinanceChip: View {
    let title: String
    var detail: String = ""
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if !detail.isEmpty {
                    Text(detail)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                        .monospacedDigit()
                }
            }
            .font(.subheadline)
            .fontWeight(isSelected ? .semibold : .regular)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                isSelected ? FinanceTrackerModule.accent.color : Color.secondary.opacity(0.12),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }
}

/// A horizontal run of chips that scrolls when it doesn't fit.
struct ChipRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                content
            }
            .padding(.vertical, 2)
        }
    }
}

/// "+$1,204" in green or "−$310" in red, for changes month to month.
struct DeltaText: View {
    let delta: Double?
    /// For liabilities, going down is the good direction.
    var upIsGood = true

    var body: some View {
        if let delta, delta.rounded() != 0 {
            Text(FinanceFormat.signedMoney(delta))
                .monospacedDigit()
                .foregroundStyle((delta > 0) == upIsGood ? Color.green : Color.red)
        }
    }
}

/// A figure in the Summary's grid.
struct SummaryTile: View {
    let title: String
    let value: Double
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(FinanceFormat.money(value))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
