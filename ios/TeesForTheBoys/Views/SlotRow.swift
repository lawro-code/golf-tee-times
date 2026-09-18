import SwiftUI
import TeesContract

/// One bookable tee time, as it appears in the results list.
///
/// Six facts fit in a row and all six are load-bearing:
///
/// | Shown | Why it is not optional |
/// |---|---|
/// | Club and time | the two things being chosen between |
/// | Holes and par | CONTRACT.md §2 — three 18-hole clubs sell 9-hole rounds, so the course's number is not the booking's |
/// | Price | CONTRACT.md §3 — an unpriced slot says "Price at course" rather than disappearing |
/// | Spots | four golfers need a four-spot slot, and most rows are not four |
/// | Registration | CONTRACT.md — the club wanting a free account is better learned here than at its checkout |
///
/// The whole row is a single accessibility element. Read one label at a time
/// this is six fragments of noise; as one sentence from
/// `SlotFormatting.accessibilityLabel(for:)` it is a round someone can decide
/// about without looking.
///
/// Nothing here has a fixed height. At AX5 the time and the detail line stop
/// sitting side by side and stack instead — `ViewThatFits` picks, so the
/// decision is made on the real measured width rather than by guessing at a
/// size class.
public struct SlotRow: View {
    private let slot: Slot

    public init(result: SlotResult) {
        self.slot = result.slot
    }

    public init(slot: Slot) {
        self.slot = slot
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SearchStyle.rowSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: SearchStyle.gutter) {
                    heading
                    Spacer(minLength: SearchStyle.gutter)
                    price
                }
                VStack(alignment: .leading, spacing: SearchStyle.rowSpacing) {
                    heading
                    price
                }
            }

            details

            if let note = SlotFormatting.registrationNote(for: slot) {
                registrationBadge(note)
            }
        }
        .padding(.vertical, SearchStyle.rowSpacing)
        // One element, one sentence. `children: .ignore` is what stops
        // VoiceOver reading the six labels above separately.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SlotFormatting.accessibilityLabel(for: slot))
        .accessibilityAddTraits(.isButton)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(SlotFormatting.time(slot))
                .searchTitleText()
            Text(slot.courseName)
                .searchSecondaryText()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var price: some View {
        Text(SlotFormatting.price(slot))
            .searchPriceText(isKnown: !slot.priceIsUnknown)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Holes, par and spots. `holesAndPar` already carries the slot's own hole
    /// count, which is the number that matters.
    private var details: some View {
        Text("\(SlotFormatting.holesAndPar(slot))  \u{00B7}  \(SlotFormatting.players(slot))")
            .searchCaptionText()
            .fixedSize(horizontal: false, vertical: true)
    }

    private func registrationBadge(_ note: String) -> some View {
        Label(note, systemImage: "person.badge.key")
            .searchWarningText()
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview("Rows") {
    let payload = try? ContractLoader.fixture("golden")
    return List(Array((payload?.slots ?? []).prefix(30)), id: \.id) { slot in
        SlotRow(slot: slot)
    }
    .listStyle(.plain)
}
#endif
