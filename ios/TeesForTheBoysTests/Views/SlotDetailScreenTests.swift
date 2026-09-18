import SwiftUI
import XCTest
import TeesContract
@testable import TeesViews

/// The detail screen's one branch that can go wrong silently.
///
/// `booking_url` decodes to a String by contract, so a malformed one cannot
/// fail the payload — which means a slot can reach this screen with nothing to
/// open. The screen's primary action is therefore a value,
/// `SlotDetailScreen.BookingAction`, rather than a closure buried in a body:
/// with `ios/project.yml` frozen there is no ViewInspector, and "the button is
/// disabled" has to be assertable somewhere.
@MainActor
final class SlotDetailScreenTests: XCTestCase {

    private var slots: [Slot] = []
    private let fixedNow = ContractDate.date(from: "2026-10-01T07:30:00+10:00")!

    override func setUpWithError() throws {
        slots = try ContractLoader.fixture("minimal").slots
    }

    private func slot(_ id: String) throws -> Slot {
        try XCTUnwrap(slots.first { $0.id == id }, "no slot \(id) in minimal.json")
    }

    /// The same slot with its booking url replaced, so the "no link" case is
    /// built from real data rather than from an invented row.
    private func withBookingURL(_ urlString: String, _ slot: Slot) -> Slot {
        Slot(
            id: slot.id,
            courseSlug: slot.courseSlug,
            courseName: slot.courseName,
            region: slot.region,
            driveMinutesFromBondi: slot.driveMinutesFromBondi,
            par: slot.par,
            lengthMetres: slot.lengthMetres,
            requiresRegistration: slot.requiresRegistration,
            teeDate: slot.teeDate,
            teeTime: slot.teeTime,
            teeAt: slot.teeAt,
            spotsAvailable: slot.spotsAvailable,
            totalSpots: slot.totalSpots,
            holes: slot.holes,
            priceMin: slot.priceMin,
            priceMax: slot.priceMax,
            priceTiers: slot.priceTiers,
            bookingType: slot.bookingType,
            bookingURLString: urlString)
    }

    private func ledger() -> BookingLedger {
        BookingLedger(store: InMemoryViewsStore(), now: { self.fixedNow })
    }

    // MARK: - The booking button

    func testAUsableLinkGivesAnEnabledButtonThatOpensIt() throws {
        let coast = try slot("the-coast:2026-10-03:0800:1st-tee")
        let url = try XCTUnwrap(coast.bookingURL)

        let action = SlotDetailScreen.BookingAction(slot: coast)

        XCTAssertEqual(action, .open(url))
        XCTAssertFalse(action.isDisabled)
        XCTAssertEqual(action.title, "Book at the club")
    }

    /// The failure this screen exists to avoid: a live-looking button that does
    /// nothing when tapped.
    func testAMissingLinkDisablesTheButtonAndExplainsWhy() throws {
        let coast = try slot("the-coast:2026-10-03:0800:1st-tee")
        let linkless = withBookingURL("", coast)

        XCTAssertNil(linkless.bookingURL, "the empty string must not parse as a URL")

        let action = SlotDetailScreen.BookingAction(slot: linkless)

        XCTAssertEqual(action, .unavailable)
        XCTAssertTrue(action.isDisabled)
        XCTAssertEqual(action.title, "Booking link unavailable")

        let explanation = try XCTUnwrap(action.explanation)
        XCTAssertTrue(explanation.contains("missing"), explanation)
        // The tee time is still real. Saying so is the difference between a
        // dead end and a phone call.
        XCTAssertTrue(explanation.contains("call the club"), explanation)
    }

    /// A url the decoder kept but `URL` will not parse ends in the same place.
    /// The contract is explicit that a malformed one must not fail the decode,
    /// so the screen is where it has to be handled.
    func testAMalformedLinkIsTreatedAsAMissingOne() throws {
        let coast = try slot("the-coast:2026-10-03:0800:1st-tee")
        let broken = withBookingURL("http://example.com/a path with spaces", coast)

        if broken.bookingURL == nil {
            XCTAssertEqual(SlotDetailScreen.BookingAction(slot: broken), .unavailable)
        } else {
            // Foundation accepted it; then the enabled state is correct and
            // there is a real URL to open.
            XCTAssertFalse(SlotDetailScreen.BookingAction(slot: broken).isDisabled)
        }
    }

    /// Every club in the fixture publishes a usable link today. If one stops,
    /// this fails before a golfer finds out by tapping.
    func testEveryFixtureSlotHasAUsableLink() {
        for slot in slots {
            XCTAssertFalse(
                SlotDetailScreen.BookingAction(slot: slot).isDisabled,
                "\(slot.id) has no usable booking url")
        }
    }

    // MARK: - The tap-out record

    /// The detail screen records the tap-out immediately before Safari opens,
    /// because once the app is backgrounded there is no later. This is the
    /// contract the screen depends on: record, come back, get asked.
    func testRecordingATapOutIsWhatMakesTheReturnPromptFire() throws {
        let coast = try slot("the-coast:2026-10-03:0800:1st-tee")
        let ledger = ledger()

        XCTAssertNil(ledger.pendingConfirmation)

        ledger.recordTapOut(coast)
        ledger.appDidBecomeActive()

        XCTAssertEqual(ledger.pendingConfirmation?.id, coast.id)
    }

    // MARK: - What the screen surfaces

    /// "Every price tier by label" is the ticket. The Coast publishes three,
    /// and collapsing them into a range throws away which one a golfer would
    /// actually pay.
    func testEveryPriceTierIsAvailableToTheScreen() throws {
        let coast = try slot("the-coast:2026-10-03:0800:1st-tee")

        XCTAssertEqual(coast.priceTiers.count, 3)
        for tier in coast.priceTiers {
            XCTAssertFalse(tier.label.isEmpty, "a tier with no label has nothing to show")
            XCTAssertTrue(SlotFormatting.money(tier.amount).hasPrefix("$"))
        }
    }

    /// CONTRACT.md §3 on the detail screen: no tiers is ordinary data, and the
    /// screen says so in words rather than showing an empty list.
    func testAnUnpricedSlotHasNoTiersToShow() throws {
        let warringah = try slot("warringah:2026-10-03:0616:1st-tee-social")
        XCTAssertTrue(warringah.priceTiers.isEmpty)
        XCTAssertTrue(warringah.priceIsUnknown)
    }

    // MARK: - Construction

    func testScreenConstructsWithItsPublicInit() throws {
        let coast = try slot("the-coast:2026-10-03:0800:1st-tee")
        let view: any View = SlotDetailScreen(slot: coast, today: "2026-10-03", ledger: ledger())
        XCTAssertTrue(view is SlotDetailScreen)
    }
}

// MARK: - Tester's pass, ticket C2

/// The booking button, from the golfer's side: is there anywhere to go, and
/// does the tap land on the right page when there is.
@MainActor
final class SlotDetailBookingActionTests: XCTestCase {

    private var slots: [Slot] = []

    override func setUpWithError() throws {
        slots = try ContractLoader.fixture("minimal").slots
    }

    private func slot(_ id: String) throws -> Slot {
        try XCTUnwrap(slots.first { $0.id == id }, "no slot \(id) in minimal.json")
    }

    private func withBookingURL(_ urlString: String, _ slot: Slot) -> Slot {
        Slot(
            id: slot.id,
            courseSlug: slot.courseSlug,
            courseName: slot.courseName,
            region: slot.region,
            driveMinutesFromBondi: slot.driveMinutesFromBondi,
            par: slot.par,
            lengthMetres: slot.lengthMetres,
            requiresRegistration: slot.requiresRegistration,
            teeDate: slot.teeDate,
            teeTime: slot.teeTime,
            teeAt: slot.teeAt,
            spotsAvailable: slot.spotsAvailable,
            totalSpots: slot.totalSpots,
            holes: slot.holes,
            priceMin: slot.priceMin,
            priceMax: slot.priceMax,
            priceTiers: slot.priceTiers,
            bookingType: slot.bookingType,
            bookingURLString: urlString)
    }

    /// The link is handed on exactly as the contract delivered it. MiClub's
    /// timesheet URL carries `feeGroupId` and `selectedDate` in its query, and
    /// a rebuilt or truncated one lands a golfer on the club's generic booking
    /// page with no sign of the 8am they tapped.
    func testTheActionCarriesTheWholeContractURLQueryAndAll() throws {
        let coast = try slot("the-coast:2026-10-03:0800:1st-tee")

        guard case .open(let url) = SlotDetailScreen.BookingAction(slot: coast) else {
            return XCTFail("a slot with a usable link did not produce an open action")
        }

        XCTAssertEqual(url.absoluteString, coast.bookingURLString)
        XCTAssertTrue(url.absoluteString.contains("feeGroupId="), url.absoluteString)
        XCTAssertTrue(url.absoluteString.contains("selectedDate=2026-10-03"), url.absoluteString)
    }

    /// An enabled button leaves the app, and says so before it does. The
    /// difference between "Book" meaning booked and "Book" meaning a browser
    /// nobody asked for is one line of copy under the button.
    func testAnEnabledButtonSaysWhereTheTapGoes() throws {
        let coast = try slot("the-coast:2026-10-03:0800:1st-tee")
        let action = SlotDetailScreen.BookingAction(slot: coast)

        XCTAssertFalse(action.isDisabled)
        let explanation = try XCTUnwrap(
            action.explanation, "an enabled button that explains nothing is a surprise")
        XCTAssertTrue(explanation.lowercased().contains("club"), explanation)
        XCTAssertFalse(
            explanation.contains("missing"),
            "the enabled button is wearing the broken button's copy: \(explanation)")
    }

    /// Every shape an unusable link arrives in, in one table. The rule the
    /// screen promises is a single one: the button is enabled exactly when
    /// there is a URL to open, and when it is not, it says why.
    func testEveryUnusableLinkStringDisablesTheButtonAndExplainsItself() throws {
        let coast = try slot("the-coast:2026-10-03:0800:1st-tee")
        var disabledCount = 0

        for raw in ["", " ", "   ", "\n", "not a url at all", "http://example.com/a path"] {
            let candidate = withBookingURL(raw, coast)
            let action = SlotDetailScreen.BookingAction(slot: candidate)

            XCTAssertEqual(
                action.isDisabled,
                candidate.bookingURL == nil,
                "\(raw.debugDescription): the button's state and the URL disagree")

            if action.isDisabled {
                disabledCount += 1
                XCTAssertEqual(action.title, "Booking link unavailable")
                let explanation = try XCTUnwrap(action.explanation, raw.debugDescription)
                XCTAssertTrue(explanation.contains("call the club"), explanation)
            }
        }

        XCTAssertGreaterThan(
            disabledCount, 0, "the table stopped exercising the failure path at all")
    }

    /// A link with no scheme still parses: `URL(string: "/guests/bookings/...")`
    /// is a perfectly good relative URL with nowhere to go. The button comes up
    /// enabled, `openURL` has no host to open, and the tap does nothing — which
    /// is the exact failure this screen's own documentation says it prevents:
    /// "it does not silently do nothing when tapped."
    ///
    /// Recorded as a known gap rather than as a red suite: three other tickets
    /// gate on this scheme, MiClub publishes absolute URLs today, and the fix
    /// is a scraper-regression guard that belongs to whoever picks it up. The
    /// expectation is strict, so it fails the day the behaviour changes and the
    /// note gets revisited instead of rotting.
    func testASchemelessLinkLooksBookableAndIsNot() throws {
        let coast = try slot("the-coast:2026-10-03:0800:1st-tee")
        let relative = withBookingURL(
            "/guests/bookings/ViewPublicTimesheet.msp?feeGroupId=2&selectedDate=2026-10-03",
            coast)

        let parsed = try XCTUnwrap(
            relative.bookingURL, "Foundation parses a schemeless path as a relative URL")
        XCTAssertNil(parsed.scheme)
        XCTAssertNil(parsed.host)

        XCTExpectFailure("known gap: BookingAction accepts a URL with no scheme and no host") {
            XCTAssertTrue(
                SlotDetailScreen.BookingAction(slot: relative).isDisabled,
                "an enabled button with nowhere to open is the failure this screen prevents")
        }
    }
}
