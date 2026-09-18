import SwiftUI
import TeesContract

/// Everything the contract knows about one tee time, and the tap that leaves
/// for the club's own booking page.
///
/// The row above it is a summary; this is the page someone reads before
/// committing forty minutes of driving, so nothing is elided. Every price tier
/// gets its own line with the club's own label — `"Social Play 9 Holes Only"`
/// is the only place some clubs state the hole count at all (CONTRACT.md §2),
/// and collapsing three tiers into `"$55–$110"` throws away which one a golfer
/// would actually pay.
///
/// Two things this screen is careful about:
///
/// - **`booking_url` is optional by contract.** It decodes as a String so a
///   malformed one cannot fail the payload, which means a slot can reach this
///   screen with nothing to open. The button goes disabled and says so; it does
///   not silently do nothing when tapped.
/// - **The tap-out is recorded first.** `ledger.recordTapOut` runs immediately
///   before Safari opens, because once the app is backgrounded there is no
///   later. That record is what lets ticket C4 ask "did you book?" on return.
public struct SlotDetailScreen: View {
    private let slot: Slot
    private let today: String
    @ObservedObject private var ledger: BookingLedger

    @Environment(\.openURL) private var openURL

    /// - Parameters:
    ///   - slot: the tee time.
    ///   - today: the Sydney wall-clock date from `SearchStore.today`. Passed
    ///     in, never derived here — CONTRACT.md §4 puts DST resolution on the
    ///     server, and a screen inventing its own "today" is how a detail page
    ///     ends up disagreeing with the row that opened it.
    ///   - ledger: ticket C4's booking ledger.
    public init(slot: Slot, today: String, ledger: BookingLedger) {
        self.slot = slot
        self.today = today
        self.ledger = ledger
    }

    private var action: BookingAction { BookingAction(slot: slot) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SearchStyle.sectionSpacing) {
                header

                if let note = SlotFormatting.registrationNote(for: slot) {
                    registrationCallout(note)
                }

                facts
                priceBlock
                bookingBlock
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SearchStyle.gutter)
        }
        .navigationTitle(SlotFormatting.shortCourseName(slot.courseName))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(slot.courseName)
                .searchTitleText()
            Text(slot.region)
                .searchSecondaryText()
            Text("\(SlotFormatting.dayTitle(for: slot.teeDate, today: today)) \u{00B7} \(SlotFormatting.time(slot))")
                .searchSecondaryText()
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(slot.courseName), \(slot.region), "
            + "\(SlotFormatting.spokenDayTitle(for: slot.teeDate)), \(SlotFormatting.time(slot))")
    }

    /// Made loud rather than tucked into a footnote: finding out at the club's
    /// checkout that it wants an account first is the surprise this exists to
    /// prevent.
    private func registrationCallout(_ note: String) -> some View {
        Label(note, systemImage: "exclamationmark.triangle.fill")
            .searchCalloutText()
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(SearchStyle.gutter)
            .background(SearchStyle.calloutBackground, in: SearchStyle.calloutShape)
            .accessibilityElement(children: .combine)
    }

    // MARK: - Facts

    private var facts: some View {
        VStack(alignment: .leading, spacing: SearchStyle.rowSpacing) {
            factRow("Round", SlotFormatting.holesAndPar(slot))
            factRow("Spots", SlotFormatting.players(slot))
            factRow("Tee", slot.bookingType.isEmpty ? "\u{2014}" : slot.bookingType)
            if let drive = SlotFormatting.drive(slot) {
                factRow("Drive", drive)
            }
        }
    }

    /// Label and value stack rather than sit side by side once the text is big
    /// enough that they would collide — measured, not guessed at.
    private func factRow(_ label: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).searchCaptionText()
                Spacer(minLength: SearchStyle.gutter)
                Text(value).searchBodyText()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).searchCaptionText()
                Text(value).searchBodyText()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }

    // MARK: - Price

    private var priceBlock: some View {
        VStack(alignment: .leading, spacing: SearchStyle.rowSpacing) {
            Text("Price").searchCaptionText()

            if slot.priceTiers.isEmpty {
                // CONTRACT.md §3. One slot in six is here, and it is ordinary
                // data rather than a failure, so the copy is plain.
                Text(SlotFormatting.priceAtCourse)
                    .searchBodyText()
                Text("This club doesn't publish a fee for this tee time.")
                    .searchCaptionText()
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(slot.priceTiers.enumerated()), id: \.offset) { _, tier in
                    factRow(tier.label, SlotFormatting.money(tier.amount))
                }
            }
        }
    }

    // MARK: - Booking

    private var bookingBlock: some View {
        VStack(alignment: .leading, spacing: SearchStyle.rowSpacing) {
            Button {
                guard case .open(let url) = action else { return }
                // Recorded before the app is backgrounded: afterwards there is
                // no "later" in which to do it.
                ledger.recordTapOut(slot)
                openURL(url)
            } label: {
                Text(action.title)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(action.isDisabled)
            .accessibilityHint(
                action.isDisabled
                    ? ""
                    : "Opens \(SlotFormatting.shortCourseName(slot.courseName)) in Safari")

            if let explanation = action.explanation {
                Text(explanation)
                    .searchCaptionText()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - The booking action, as a value

    /// Whether there is anywhere to send a golfer, resolved as a value type.
    ///
    /// `ios/project.yml` is frozen, so there is no ViewInspector and a SwiftUI
    /// body cannot be asserted on. Lifting the one branch that matters out of
    /// the body is what makes "a slot with no booking url disables the button"
    /// a test rather than a screenshot.
    public enum BookingAction: Equatable, Sendable {
        case open(URL)
        case unavailable

        public init(slot: Slot) {
            if let url = slot.bookingURL {
                self = .open(url)
            } else {
                self = .unavailable
            }
        }

        public var isDisabled: Bool { self == .unavailable }

        public var title: String {
            switch self {
            case .open: return "Book at the club"
            case .unavailable: return "Booking link unavailable"
            }
        }

        /// Shown under a disabled button so the dead control is explained
        /// rather than merely dead.
        public var explanation: String? {
            switch self {
            case .open: return "Booking happens on the club's own site."
            case .unavailable:
                return "This club's booking link is missing, so we can't open it. "
                    + "The tee time is real \u{2014} call the club to book it."
            }
        }
    }
}
