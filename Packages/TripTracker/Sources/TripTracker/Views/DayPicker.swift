import SwiftUI

/// The editors' "Day" row: every day of the trip by date and number, plus
/// Unassigned where that's on offer.
struct DayPicker: View {
    let dates: TripDates
    @Binding var selection: DayChoice
    var includesUnassigned = DayChoice.offersUnassigned

    var body: some View {
        Picker("Day", selection: $selection) {
            ForEach(DayChoice.all(in: dates, includingUnassigned: includesUnassigned, keeping: selection)) { choice in
                Text(choice.label(in: dates)).tag(choice)
            }
        }
    }
}

/// The timeline's "Move to…": one button per other day, tomorrow first while
/// the trip is under way. The same list serves a context menu, a submenu and
/// a confirmation dialog.
struct MoveToDayButtons: View {
    let dates: TripDates
    let current: DayChoice
    var includesUnassigned = DayChoice.offersUnassigned
    let now: Date
    let move: (DayChoice) -> Void

    var body: some View {
        ForEach(DayChoice.moveTargets(from: current, in: dates, includingUnassigned: includesUnassigned, asOf: now)) { choice in
            Button {
                move(choice)
            } label: {
                if let relative = choice.relativeName(in: dates, asOf: now) {
                    Text("\(relative) · \(choice.label(in: dates))")
                } else {
                    Text(choice.label(in: dates))
                }
            }
        }
    }
}
