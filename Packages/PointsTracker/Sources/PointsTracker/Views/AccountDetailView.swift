import Core // Only reached on macOS, where Core's UIPasteboard stands in for UIKit's.
import CoreData
import SwiftUI

struct AccountDetailView: View {
    @ObservedObject var account: SharedPointsAccount

    @Environment(\.managedObjectContext) private var context
    @Environment(\.pointsPersistentContainer) private var container
    @State private var showingUpdate = false
    @State private var showingEdit = false
    @State private var copied = false

    /// False for a view-only participant in a partner's household.
    private var isEditable: Bool { canEdit(account, in: container) }

    var body: some View {
        List {
            Section {
                VStack(spacing: 4) {
                    Text(account.balance.formatted())
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("\(account.kind.unit.singular)s · updated \(account.balanceUpdatedAt.formatted(.relative(presentation: .named)))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if isEditable {
                        Button("Update Balance") { showingUpdate = true }
                            .primaryActionStyle(tint: PointsTrackerModule.accent.color)
                            .padding(.top, 10)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("Person", value: account.owner?.name ?? PointsSummary.unassigned)
                LabeledContent("Type", value: account.kind.displayName)
                if !account.program.isEmpty {
                    LabeledContent("Programme", value: account.program)
                }
                if !account.memberNumber.isEmpty {
                    Button {
                        UIPasteboard.general.string = account.memberNumber
                        copied = true
                    } label: {
                        LabeledContent("Member number") {
                            Text(copied ? "Copied" : account.memberNumber)
                                .monospaced()
                        }
                    }
                    .tint(.primary)
                }
                if !account.status.isEmpty {
                    LabeledContent("Status", value: account.status)
                }
                if let expiresAt = account.expiresAt {
                    LabeledContent(expiresAt < .now ? "Expired" : "Expires") {
                        Text(expiresAt, format: .dateTime.day().month().year())
                            .foregroundStyle(account.expiresSoon() ? Color.orange : Color.secondary)
                    }
                }
            }

            if !account.notes.isEmpty {
                Section("Notes") {
                    Text(account.notes)
                }
            }

            Section("History") {
                let history = account.orderedHistory
                ForEach(history) { entry in
                    HistoryRow(entry: entry, unit: account.kind.unit, isOpening: entry == history.last)
                }
                .onDelete { offsets in
                    guard isEditable else { return }
                    account.deleteEntries(offsets.map { history[$0] })
                    try? context.saveIfNeeded()
                }
            }
        }
        .navigationTitle(account.displayName.isEmpty ? "Account" : account.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isEditable {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { showingEdit = true }
                }
            }
        }
        .sheet(isPresented: $showingUpdate) {
            UpdateBalanceView(account: account)
        }
        .sheet(isPresented: $showingEdit) {
            AccountEditorView(account: account)
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

private struct HistoryRow: View {
    let entry: SharedPointsEntry
    let unit: PointsUnit
    let isOpening: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.recordedAt, format: .dateTime.day().month(.abbreviated).year())
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.balance.formatted())
                    .monospacedDigit()
                // The first entry's change is the whole opening balance, which
                // reads as a huge earn rather than a starting point.
                if !isOpening, entry.delta != 0 {
                    Text(entry.delta.formatted(.number.sign(strategy: .always())))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(entry.delta > 0 ? Color.green : Color.red)
                }
            }
        }
    }
}
