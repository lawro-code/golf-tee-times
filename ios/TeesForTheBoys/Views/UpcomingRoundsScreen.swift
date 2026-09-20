import SwiftUI
import TeesDesign

/// Every string an upcoming-round row shows.
///
/// Pure and public, like `SlotFormatting`, and for the same reason: with
/// `ios/project.yml` frozen there is no ViewInspector in this target, so a
/// string lifted out of the body is the only part of the screen that can be
/// asserted on. The day and time formatting is `SlotFormatting`'s — a round in
/// this list has to read exactly like the search row it came from, and two
/// formatters drift.
public enum UpcomingRoundCopy {

    /// `"Today \u{00B7} 8:00 am"`, or `"Sat 19 Sep \u{00B7} 8:00 am"`.
    ///
    /// - Parameter today: the Sydney wall-clock date, passed down from
    ///   `SearchStore.today` rather than derived here. A screen that invents its
    ///   own "today" is a screen that disagrees with the one next to it.
    public static func when(_ booking: ConfirmedBooking, today: String) -> String {
        let day = SlotFormatting.dayTitle(for: booking.teeDate, today: today)
        return "\(day) \u{00B7} \(SlotFormatting.time(teeTime: booking.teeTime))"
    }

    /// `"18 holes \u{00B7} par 70"`, or just `"18 holes"`. The hole count is the
    /// booking's own, copied off the slot when it was confirmed — three of the
    /// fifteen courses sell 9-hole rounds (CONTRACT.md §2).
    public static func detail(_ booking: ConfirmedBooking) -> String {
        let holes = "\(booking.holes) holes"
        guard let par = booking.par else { return holes }
        return "\(holes) \u{00B7} par \(par)"
    }

    /// One spoken sentence for the whole row. Three small labels read one at a
    /// time are fragments; as a sentence it is a round someone can recognise
    /// without looking. Never relative — a label read out of context should say
    /// which day it means.
    public static func accessibilityLabel(_ booking: ConfirmedBooking) -> String {
        [
            booking.courseName,
            SlotFormatting.spokenDayTitle(for: booking.teeDate),
            SlotFormatting.time(teeTime: booking.teeTime),
            detail(booking).replacingOccurrences(of: " \u{00B7} ", with: ", ")
        ].joined(separator: ", ") + "."
    }

    public static let emptyTitle = "No rounds yet"

    /// Says what puts a round here, because nothing the golfer can do on *this*
    /// screen will. The list is a consequence of answering one question
    /// elsewhere, and an empty state that does not explain that reads like a
    /// bug.
    public static let emptyMessage = "When you book a tee time, say yes to \"did you book?\" and the round shows up here."

    public static let navigationTitle = "Rounds"
}

/// The rounds the golfer confirmed, soonest first.
///
/// A plain list of confirmed bookings, and deliberately nothing else. No
/// playing partners, no teams, no invites — a later version's problem, and
/// leaving room for them here would mean shipping fields nothing fills.
///
/// Rounds leave the list on their own: ``BookingLedger/upcoming`` is computed
/// against the ledger's injected clock every time it is read, so a tee time
/// that has passed is gone on the next render without anything having to sweep
/// up after it.
public struct UpcomingRoundsScreen: View {

    @ObservedObject private var ledger: BookingLedger
    private let today: String

    /// - Parameters:
    ///   - ledger: the booking ledger. Observed, so confirming a round from the
    ///     did-you-book prompt puts it in this list immediately.
    ///   - today: the Sydney wall-clock date from `SearchStore.today`.
    public init(ledger: BookingLedger, today: String) {
        self.ledger = ledger
        self.today = today
    }

    public var body: some View {
        Group {
            let rounds = ledger.upcoming
            if rounds.isEmpty {
                TeesEmptyState(
                    headline: UpcomingRoundCopy.emptyTitle,
                    message: UpcomingRoundCopy.emptyMessage)
            } else {
                List(rounds) { booking in
                    UpcomingRoundRow(booking: booking, today: today)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(UpcomingRoundCopy.navigationTitle)
    }
}

/// One confirmed round. Not public: ``UpcomingRoundsScreen`` is the vocabulary.
///
/// Nothing has a fixed height — at AX5 a club name is three lines on its own —
/// and the row is one accessibility element so VoiceOver reads a round rather
/// than three fragments.
struct UpcomingRoundRow: View {

    let booking: ConfirmedBooking
    let today: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(UpcomingRoundCopy.when(booking, today: today))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(booking.courseName)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            Text(UpcomingRoundCopy.detail(booking))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UpcomingRoundCopy.accessibilityLabel(booking))
    }
}
