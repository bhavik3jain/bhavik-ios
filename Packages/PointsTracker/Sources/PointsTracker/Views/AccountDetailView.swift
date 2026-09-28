import Charts
import Core // Only reached on macOS, where Core's UIPasteboard stands in for UIKit's.
import CoreData
import SwiftUI

struct AccountDetailView: View {
    @ObservedObject var account: SharedPointsAccount

    @Environment(\.managedObjectContext) private var context
    @Environment(\.pointsPersistentContainer) private var container
    @Environment(\.moduleLayout) private var layout
    @State private var showingUpdate = false
    @State private var showingEdit = false
    @State private var copied = false

    /// False for a view-only participant in a partner's household.
    private var isEditable: Bool { canEdit(account, in: container) }

    var body: some View {
        Group {
            if layout == .sidebar {
                MacAccountDetail(account: account, isEditable: isEditable, copied: $copied) { entries in
                    account.deleteEntries(entries)
                    try? context.saveIfNeeded()
                }
            } else {
                list
            }
        }
        .navigationTitle(account.displayName.isEmpty ? "Account" : account.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isEditable {
                if layout == .sidebar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") { showingEdit = true }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Update Balance") { showingUpdate = true }
                            .buttonStyle(.borderedProminent)
                            .tint(PointsTrackerModule.accent.color)
                    }
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") { showingEdit = true }
                    }
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

    private var list: some View {
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
                LabeledContent("Type") {
                    Label {
                        Text(account.kind.displayName)
                    } icon: {
                        Image(systemName: account.kind.symbolName)
                            .foregroundStyle(account.kind.color)
                    }
                }
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

/// An account on the Mac: the balance and how it has moved, the details beside
/// it, and the history as a table. The phone's list centred one number in a
/// window-wide column and put every detail a window-width from its label.
private struct MacAccountDetail: View {
    @ObservedObject var account: SharedPointsAccount
    let isEditable: Bool
    @Binding var copied: Bool
    let delete: ([SharedPointsEntry]) -> Void

    @State private var selection: NSManagedObjectID?

    var body: some View {
        let history = account.orderedHistory
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(account.balance.formatted())
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("\(account.kind.unit.singular)s")
                            .foregroundStyle(.secondary)
                    }
                    Text("Updated \(account.balanceUpdatedAt.formatted(.relative(presentation: .named)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if history.count > 1 {
                        Chart(history) { entry in
                            AreaMark(x: .value("Date", entry.recordedAt), y: .value("Balance", entry.balance))
                                .foregroundStyle(account.kind.color.opacity(0.18).gradient)
                                .interpolationMethod(.stepEnd)
                            LineMark(x: .value("Date", entry.recordedAt), y: .value("Balance", entry.balance))
                                .foregroundStyle(account.kind.color)
                                .interpolationMethod(.stepEnd)
                        }
                        .chartYAxis { AxisMarks(position: .trailing) }
                        .frame(height: 140)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: .rect(cornerRadius: 14))

                details
                    .padding(16)
                    .frame(width: 300, alignment: .leading)
                    .background(.background.secondary, in: .rect(cornerRadius: 14))
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Table(history, selection: $selection) {
                TableColumn("Date") { entry in
                    Text(entry.recordedAt, format: .dateTime.day().month(.abbreviated).year())
                }
                .width(min: 100, ideal: 120)
                TableColumn("Note") { entry in
                    Text(entry.note).foregroundStyle(.secondary)
                }
                TableColumn("Change") { entry in
                    // The first entry's change is the whole opening balance,
                    // which reads as a huge earn rather than a starting point.
                    if entry != history.last, entry.delta != 0 {
                        Text(entry.delta.formatted(.number.sign(strategy: .always())))
                            .monospacedDigit()
                            .foregroundStyle(entry.delta > 0 ? Color.green : Color.red)
                    }
                }
                .alignment(.numeric)
                TableColumn("Balance") { entry in
                    Text(entry.balance.formatted()).monospacedDigit()
                }
                .alignment(.numeric)
            }
            .tableRowBackgroundsPlain()
            .contextMenu(forSelectionType: NSManagedObjectID.self) { ids in
                if isEditable, let id = ids.first, let entry = history.first(where: { $0.objectID == id }) {
                    Button("Delete Entry", systemImage: "trash", role: .destructive) { delete([entry]) }
                }
            }
        }
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Person").foregroundStyle(.secondary)
                Text(account.owner?.name ?? PointsSummary.unassigned)
            }
            GridRow {
                Text("Type").foregroundStyle(.secondary)
                Label {
                    Text(account.kind.displayName)
                } icon: {
                    Image(systemName: account.kind.symbolName)
                        .foregroundStyle(account.kind.color)
                }
            }
            if !account.program.isEmpty {
                GridRow {
                    Text("Programme").foregroundStyle(.secondary)
                    Text(account.program)
                }
            }
            if !account.memberNumber.isEmpty {
                GridRow {
                    Text("Member no.").foregroundStyle(.secondary)
                    Button {
                        UIPasteboard.general.string = account.memberNumber
                        copied = true
                    } label: {
                        Text(copied ? "Copied" : account.memberNumber)
                            .monospaced()
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                }
            }
            if !account.status.isEmpty {
                GridRow {
                    Text("Status").foregroundStyle(.secondary)
                    Text(account.status)
                }
            }
            if let expiresAt = account.expiresAt {
                GridRow {
                    Text(expiresAt < .now ? "Expired" : "Expires").foregroundStyle(.secondary)
                    Text(expiresAt, format: .dateTime.day().month().year())
                        .foregroundStyle(account.expiresSoon() ? Color.orange : Color.primary)
                }
            }
            if !account.notes.isEmpty {
                GridRow {
                    Text("Notes").foregroundStyle(.secondary)
                    Text(account.notes).lineLimit(4)
                }
            }
        }
        .font(.callout)
    }
}
