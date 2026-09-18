import TeesContract
import XCTest
@testable import TeesDesign

/// Price presentation, which is `CONTRACT.md` §3 and `docs/app.js` turned into
/// assertions.
///
/// These read the model rather than the view on purpose: there is no snapshot
/// or view-inspection library in this target — `ios/project.yml` is frozen, so
/// an SPM package cannot be added — so a rule computed inside `body` could not
/// be tested at all. The split exists so these tests can exist.
final class TeesPriceTierBadgeTests: XCTestCase {

    // MARK: - Fixtures

    /// A slot with only the price fields that matter varied. Everything else is
    /// a plausible constant, built with the contract's own memberwise
    /// initialiser — `golden.json` is a resource of the TeesContract framework
    /// and is not reachable from this bundle.
    private static func slot(
        priceMin: Double?,
        priceMax: Double? = nil,
        tiers: [PriceTier]
    ) -> Slot {
        Slot(
            id: "warringah:2026-09-18:0616:1st-tee-social",
            courseSlug: "warringah",
            courseName: "Warringah Golf Club",
            region: "Northern Beaches",
            driveMinutesFromBondi: 32,
            par: 70,
            requiresRegistration: false,
            teeDate: "2026-09-18",
            teeTime: "06:16:00",
            teeAt: Date(timeIntervalSince1970: 1_789_000_000),
            spotsAvailable: 2,
            totalSpots: 4,
            holes: 18,
            priceMin: priceMin,
            priceMax: priceMax,
            priceTiers: tiers,
            bookingType: "1st Tee Social",
            bookingURLString: "https://warringah.miclub.com.au/guests/bookings/x")
    }

    // MARK: - The cheapest tier is the headline

    /// Tiers arrive in whatever order the club's fee table lists them. The
    /// headline is the cheapest, not the first.
    func testCheapestTierWinsWhateverOrderTheClubSendsThemIn() {
        let model = TeesPriceTierBadge.Model(slot: Self.slot(
            priceMin: 28,
            priceMax: 62,
            tiers: [
                PriceTier(label: "Weekend", amount: 62),
                PriceTier(label: "Social", amount: 48),
                PriceTier(label: "Early Bird", amount: 28),
            ]))

        XCTAssertEqual(model.headline, "$28", "the headline is the cheapest tier, not the first one listed")
        XCTAssertEqual(model.secondary, "or $62 Weekend", "the secondary line is the dearest tier")
        XCTAssertFalse(model.isUnknown)
    }

    /// `$48`, never `$48.00` — `Math.round` in `docs/app.js`, which rounds a
    /// half up.
    func testAmountsAreWholeDollars() {
        let cases: [(Double, String)] = [(48.0, "$48"), (48.4, "$48"), (48.6, "$49"), (22.5, "$23")]

        for (amount, expected) in cases {
            let model = TeesPriceTierBadge.Model(slot: Self.slot(
                priceMin: amount, tiers: [PriceTier(label: "Social", amount: amount)]))
            XCTAssertEqual(model.headline, expected, "\(amount) should render as \(expected)")
            XCTAssertFalse(model.headline.contains("."), "a price is never shown with cents")
        }
    }

    /// One tier is one price. An "or …" line with nothing to compare against
    /// is noise on a card that has room for four facts.
    func testASingleTierHasNoSecondaryLine() {
        let model = TeesPriceTierBadge.Model(slot: Self.slot(
            priceMin: 48, priceMax: 48, tiers: [PriceTier(label: "Social", amount: 48)]))

        XCTAssertEqual(model.headline, "$48")
        XCTAssertNil(model.secondary)
    }

    // MARK: - Year stripping

    /// MiClub fee labels carry the season — "Social Twilight 2026". The year is
    /// noise next to a price, and `docs/app.js` strips it with
    /// `/\s*\d{4}\s*$/`.
    func testTrailingYearIsStrippedFromTheSecondaryLabel() {
        let model = TeesPriceTierBadge.Model(slot: Self.slot(
            priceMin: 30,
            priceMax: 55,
            tiers: [
                PriceTier(label: "Member 2026", amount: 30),
                PriceTier(label: "Social Twilight 2026", amount: 55),
            ]))

        XCTAssertEqual(model.secondary, "or $55 Social Twilight")
        XCTAssertFalse(model.secondary?.contains("2026") ?? true, "the season is not part of a price")
    }

    /// A label that is nothing but a year leaves no label at all, and the line
    /// must not end in a dangling space.
    func testALabelThatIsOnlyAYearLeavesJustTheAmount() {
        let model = TeesPriceTierBadge.Model(slot: Self.slot(
            priceMin: 10,
            priceMax: 20,
            tiers: [PriceTier(label: "Social", amount: 10), PriceTier(label: "2026", amount: 20)]))

        XCTAssertEqual(model.secondary, "or $20")
    }

    /// Only a trailing year goes. A year in the middle of a label is part of
    /// the label.
    func testAYearInsideALabelSurvives() {
        XCTAssertEqual(
            TeesPriceTierBadge.Model.strippingTrailingYear("2026 Season Social"),
            "2026 Season Social")
    }

    // MARK: - Twilight

    /// Clubs write it every way. `/twilight/i` matches all of them, and the
    /// match is what repaints the headline in `TeesColor.priceTwilight`.
    func testTwilightDetectionIsCaseInsensitive() {
        let labels = ["Twilight", "twilight", "TWILIGHT", "Social Twilight Rate", "tWiLiGhT"]

        for label in labels {
            let model = TeesPriceTierBadge.Model(slot: Self.slot(
                priceMin: 28, tiers: [PriceTier(label: label, amount: 28)]))
            XCTAssertTrue(model.isTwilight, "\(label) should read as a twilight rate")
        }
    }

    /// The flag follows the cheapest tier, because that is the one drawn in the
    /// headline.
    func testTwilightFollowsTheCheapestTierNotAnyTier() {
        let twilightIsDearest = TeesPriceTierBadge.Model(slot: Self.slot(
            priceMin: 30,
            priceMax: 55,
            tiers: [PriceTier(label: "Member", amount: 30), PriceTier(label: "Twilight", amount: 55)]))
        XCTAssertFalse(twilightIsDearest.isTwilight, "the headline is the $30 member rate, not the twilight one")

        let twilightIsCheapest = TeesPriceTierBadge.Model(slot: Self.slot(
            priceMin: 28,
            priceMax: 48,
            tiers: [PriceTier(label: "Twilight", amount: 28), PriceTier(label: "Social", amount: 48)]))
        XCTAssertTrue(twilightIsCheapest.isTwilight)
    }

    func testAnOrdinaryRateIsNotTwilight() {
        let model = TeesPriceTierBadge.Model(slot: Self.slot(
            priceMin: 48, tiers: [PriceTier(label: "Social Play 18 Holes", amount: 48)]))
        XCTAssertFalse(model.isTwilight)
    }

    // MARK: - No price at all

    /// **The one that matters most.** 282 of the 1755 slots in the golden
    /// fixture publish no fee — Warringah's whole sheet, most of Bexley's. That
    /// is ordinary data, not an error, and the failure mode this test exists to
    /// prevent is a row that renders blank or "$0" and gets quietly filtered
    /// out of a price search, taking 17% of the inventory with it.
    func testAnUnpricedSlotSaysPriceAtCourseAndIsNeverBlankOrZero() {
        let model = TeesPriceTierBadge.Model(slot: Self.slot(priceMin: nil, priceMax: nil, tiers: []))

        XCTAssertTrue(model.isUnknown, "no price_min and no tiers is the unknown case")
        XCTAssertEqual(model.headline, "Price at course")
        XCTAssertEqual(model.headline, TeesPriceTierBadge.Model.unknownHeadline)

        XCTAssertNotEqual(model.headline, "", "an unpriced slot is never blank")
        XCTAssertFalse(model.headline.isEmpty, "an unpriced slot is never blank")
        XCTAssertNotEqual(model.headline, "$0", "we do not know the price; we do not claim it is free")
        XCTAssertFalse(model.headline.contains("$"), "no dollar figure is invented")

        XCTAssertNil(model.secondary)
        XCTAssertFalse(model.isTwilight)
    }

    /// A priced slot is not the unknown case, which is the other half of the
    /// same assertion.
    func testAPricedSlotIsNotUnknown() {
        let model = TeesPriceTierBadge.Model(slot: Self.slot(
            priceMin: 48, tiers: [PriceTier(label: "Social", amount: 48)]))

        XCTAssertFalse(model.isUnknown)
        XCTAssertEqual(model.headline, "$48")
    }

    /// The contract allows a `price_min` without tiers. Showing the number we
    /// have beats claiming we have none.
    func testAMinimumWithoutTiersStillShowsANumber() {
        let model = TeesPriceTierBadge.Model(slot: Self.slot(priceMin: 35, priceMax: 35, tiers: []))

        XCTAssertEqual(model.headline, "$35")
        XCTAssertFalse(model.isUnknown)
        XCTAssertNil(model.secondary)
    }

    // MARK: - What VoiceOver hears

    func testSpokenDescriptionCarriesBothLines() {
        let model = TeesPriceTierBadge.Model(slot: Self.slot(
            priceMin: 28,
            priceMax: 48,
            tiers: [PriceTier(label: "Twilight", amount: 28), PriceTier(label: "Social", amount: 48)]))

        XCTAssertTrue(model.spokenDescription.contains("$28"))
        XCTAssertTrue(model.spokenDescription.contains("or $48 Social"))
    }

    func testAnUnpricedSlotIsStillSpoken() {
        let model = TeesPriceTierBadge.Model(slot: Self.slot(priceMin: nil, tiers: []))
        XCTAssertEqual(model.spokenDescription, "price at course")
        XCTAssertFalse(model.spokenDescription.isEmpty)
    }

    // MARK: - Two tiers at the same price

    /// `docs/app.js` sorts tiers on amount alone, so when a club lists "Social"
    /// and "Twilight" at the same $48 — which clubs do — whichever one the fee
    /// table happened to print first becomes the headline. The headline's
    /// colour rides on that choice: `isTwilight` repaints it. Sorted on amount
    /// alone the same slot can come back gold or green depending on the order a
    /// scrape emitted, and nobody can reproduce it. The label tie-break is what
    /// makes it one answer.
    func testTiersAtTheSameAmountResolveTheSameWayWhateverOrderTheyArriveIn() {
        let social = PriceTier(label: "Social", amount: 48)
        let twilight = PriceTier(label: "Twilight", amount: 48)

        let socialFirst = TeesPriceTierBadge.Model(
            slot: Self.slot(priceMin: 48, priceMax: 48, tiers: [social, twilight]))
        let twilightFirst = TeesPriceTierBadge.Model(
            slot: Self.slot(priceMin: 48, priceMax: 48, tiers: [twilight, social]))

        XCTAssertEqual(
            socialFirst, twilightFirst,
            "the same two tiers in the other order produced a different badge")
        XCTAssertFalse(
            socialFirst.isTwilight,
            "\"Social\" sorts before \"Twilight\", so the headline is the social rate either way")
        XCTAssertEqual(socialFirst.headline, "$48")
        XCTAssertEqual(socialFirst.secondary, "or $48 Twilight")
    }

    /// The same thing with three, because two could agree by luck. Every
    /// arrangement of one price has to produce one badge.
    func testEveryArrangementOfThreeEqualTiersProducesTheSameBadge() {
        let affiliate = PriceTier(label: "Affiliate", amount: 40)
        let member = PriceTier(label: "Member", amount: 40)
        let twilight = PriceTier(label: "Twilight", amount: 40)

        let arrangements = [
            [affiliate, member, twilight], [affiliate, twilight, member],
            [member, affiliate, twilight], [member, twilight, affiliate],
            [twilight, affiliate, member], [twilight, member, affiliate],
        ]
        let badges = arrangements.map {
            TeesPriceTierBadge.Model(slot: Self.slot(priceMin: 40, priceMax: 40, tiers: $0))
        }

        for (index, badge) in badges.enumerated() {
            XCTAssertEqual(badge, badges[0], "arrangement \(index) disagrees with the first")
        }
        XCTAssertFalse(badges[0].isTwilight)
        XCTAssertEqual(badges[0].secondary, "or $40 Twilight")
    }

    // MARK: - Numbers that are not numbers

    /// `price_min` is allowed to arrive as a *string* — `CONTRACT.md` says some
    /// Postgres clients send `numeric` that way, and `decodeNumberIfPresent`
    /// reads it with `Double(_:)`, where `"1e400"` is `+inf` and `"nan"` is a
    /// NaN. `Int(_:)` traps on both. Without the finite guard this is not a
    /// wrong price on a card, it is the app closing while a golfer scrolls.
    ///
    /// The badge still reports `isUnknown == false` on this path, so the
    /// fallback text draws in the serif price face rather than the muted note
    /// face. Worth tidying; not worth a crash.
    func testANonFinitePriceNeitherCrashesNorInventsAFigure() {
        for amount in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            let fromMinimum = TeesPriceTierBadge.Model(slot: Self.slot(priceMin: amount, tiers: []))
            XCTAssertEqual(
                fromMinimum.headline, TeesPriceTierBadge.Model.unknownHeadline,
                "\(amount) as price_min")
            XCTAssertFalse(fromMinimum.headline.contains("$"), "no figure is invented from \(amount)")

            let fromTier = TeesPriceTierBadge.Model(
                slot: Self.slot(priceMin: nil, tiers: [PriceTier(label: "Social", amount: amount)]))
            XCTAssertEqual(
                fromTier.headline, TeesPriceTierBadge.Model.unknownHeadline, "\(amount) as a tier")
            XCTAssertFalse(fromTier.headline.lowercased().contains("inf"), "got \(fromTier.headline)")
            XCTAssertFalse(fromTier.headline.lowercased().contains("nan"), "got \(fromTier.headline)")
        }
    }

    /// The decode path that produces one, end to end, so nobody has to take the
    /// comment above on trust: this is `public.open_slots` sending a `numeric`
    /// as a string, which the contract explicitly allows.
    func testTheContractDecoderReallyCanHandTheBadgeAnInfinitePrice() throws {
        let json = """
        {
          "id": "warringah:2026-09-18:0616:1st-tee-social",
          "course_slug": "warringah", "course_name": "Warringah Golf Club",
          "region": "Northern Beaches", "drive_minutes_from_bondi": 32,
          "par": 70, "length_metres": null, "requires_registration": false,
          "tee_date": "2026-09-18", "tee_time": "06:16:00",
          "tee_at": "2026-09-18T06:16:00+10:00",
          "spots_available": 2, "total_spots": 4, "holes": 18,
          "price_min": "1e400", "price_max": "1e400", "price_tiers": [],
          "booking_type": "1st Tee Social",
          "booking_url": "https://warringah.miclub.com.au/guests/bookings/x"
        }
        """

        let slot = try JSONDecoder().decode(Slot.self, from: Data(json.utf8))
        XCTAssertEqual(slot.priceMin?.isFinite, false, "a numeric sent as a string is how this gets in")

        let model = TeesPriceTierBadge.Model(slot: slot)
        XCTAssertEqual(model.headline, TeesPriceTierBadge.Model.unknownHeadline)
        XCTAssertFalse(model.headline.contains("$"))
    }

    // MARK: - Zero is a price

    /// A club that publishes a $0 rate has published a price. The unpriced rule
    /// — never "$0" — is about a slot with no fee at all, and a port that
    /// reached for JavaScript's `if (!slot.price_min)` would collapse the two,
    /// because 0 is falsy. A published nothing shows as "$0" and is not the
    /// unknown case.
    func testAPublishedZeroIsAPriceAndNotTheUnknownCase() {
        let tiered = TeesPriceTierBadge.Model(slot: Self.slot(
            priceMin: 0, priceMax: 0, tiers: [PriceTier(label: "Member", amount: 0)]))
        XCTAssertEqual(tiered.headline, "$0")
        XCTAssertFalse(tiered.isUnknown, "a fee of nothing is not a missing fee")

        let minimumOnly = TeesPriceTierBadge.Model(slot: Self.slot(priceMin: 0, tiers: []))
        XCTAssertEqual(minimumOnly.headline, "$0")
        XCTAssertFalse(minimumOnly.isUnknown)
    }

    /// The year strip is a port of `/\s*\d{4}\s*$/`, quirks included: `\s*`
    /// matches no space at all, and nothing anchors the left, so a five-digit
    /// tail loses its last four. Both surfaces have to be wrong in the same
    /// way, or a fee label reads one way on the website and another in the app.
    func testTheYearStripMatchesTheJavaScriptOnTheAwkwardLabels() {
        let cases: [(String, String)] = [
            ("Social Twilight 2026", "Social Twilight"),
            ("Social  2026", "Social"),
            ("Twilight 2026 ", "Twilight"),
            ("Social2026", "Social"),
            ("2026 Season Social", "2026 Season Social"),
            ("Social 20265", "Social 2"),
            ("Comp 26", "Comp 26"),
            ("Social Play 9 Holes", "Social Play 9 Holes"),
        ]

        for (raw, expected) in cases {
            XCTAssertEqual(
                TeesPriceTierBadge.Model.strippingTrailingYear(raw), expected, "\"\(raw)\"")
        }
    }
}
