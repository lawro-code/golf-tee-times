import SwiftUI
import TeesContract

/// The one question this app asks: did you book?
///
/// Attached with ``SwiftUI/View/didYouBookPrompt(ledger:)`` to whatever view is
/// on screen when the app comes back — usually the tab root, so the dialog
/// survives the golfer having navigated away from the detail screen while they
/// were over in Safari.
///
/// ## Why a confirmation dialog and not a sheet
///
/// A sheet would have to be dismissed. This is a two-word question the golfer
/// did not ask for, arriving as they return to the app, and the cheapest
/// possible way out of it has to be the default. A `confirmationDialog` with a
/// `.cancel` role gets that for free: a tap outside, a swipe down, or the
/// hardware back gesture all land on "didn't book", VoiceOver announces it as a
/// dialog and offers Escape/two-finger-scrub as dismissal, and focus is not
/// trapped — the golfer can leave without answering and the ledger treats
/// leaving as an answer.
///
/// ## The three ways out are one outcome
///
/// Booked it → a round. Didn't book → nothing. Dismissed → nothing. Only the
/// first records anything, and all three close the question for good. Saying no
/// must cost nothing, or the honest answer stops being the easy one.
public struct DidYouBookPrompt: ViewModifier {

    @ObservedObject private var ledger: BookingLedger

    public init(ledger: BookingLedger) {
        self.ledger = ledger
    }

    /// `"Did you book 8:00 am at The Coast?"`
    ///
    /// The club is the short name — the golfer knows which Coast they tapped
    /// through to ten minutes ago, and "The Coast Golf and Recreation Club" in
    /// a dialog title wraps to three lines on a small phone at AX5.
    ///
    /// Pure and public because `ios/project.yml` is frozen: with no
    /// ViewInspector in the target, a string lifted out of the body is the only
    /// part of a dialog that can be asserted on.
    public static func title(for slot: Slot) -> String {
        "Did you book \(SlotFormatting.time(slot)) at \(SlotFormatting.shortCourseName(slot.courseName))?"
    }

    /// The day, spelled out. The title carries the time; a golfer who tapped
    /// through to three different mornings needs the date to tell them apart.
    public static func message(for slot: Slot) -> String {
        "\(SlotFormatting.spokenDayTitle(for: slot.teeDate)) \u{00B7} \(SlotFormatting.holesAndPar(slot))"
    }

    public static let confirmTitle = "Booked it"
    public static let declineTitle = "Didn't book"

    public func body(content: Content) -> some View {
        content.confirmationDialog(
            ledger.pendingConfirmation.map(Self.title(for:)) ?? "",
            isPresented: isPresented,
            titleVisibility: .visible,
            presenting: ledger.pendingConfirmation
        ) { slot in
            Button(Self.confirmTitle) { ledger.confirmBooked(slot) }
            // `.cancel` puts it in the dismissal position and makes it what an
            // outside tap resolves to. The ledger treats the two identically,
            // so which one fired does not matter.
            Button(Self.declineTitle, role: .cancel) { ledger.declineBooked(slot) }
        } message: { slot in
            Text(Self.message(for: slot))
        }
    }

    /// Presented whenever the ledger has a pending slot. The setter is the
    /// dismissal path: SwiftUI writes `false` for an outside tap *and* for a
    /// button press, and ``BookingLedger/dismissPrompt()`` is a no-op once the
    /// button's action has already cleared the pending slot. Both orderings
    /// land in the same place, which is why the button actions take the slot
    /// explicitly rather than reading it back off the ledger.
    private var isPresented: Binding<Bool> {
        Binding(
            get: { ledger.pendingConfirmation != nil },
            set: { presented in
                if !presented { ledger.dismissPrompt() }
            })
    }
}

public extension View {
    /// Ask about a returning golfer's tap-out, if there is one to ask about.
    ///
    /// Safe to attach unconditionally: it renders nothing until
    /// ``BookingLedger/appDidBecomeActive()`` has something to promote.
    func didYouBookPrompt(ledger: BookingLedger) -> some View {
        modifier(DidYouBookPrompt(ledger: ledger))
    }
}
