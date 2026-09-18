import XCTest
@testable import TeesData
import TeesContract

/// The fixture-backed remote: what Stage 2's simulator demo and every screen
/// test run on.
///
/// These assertions are deliberately specific about the golden fixture's
/// contents. It is a real 17 September 2026 scrape, and the numbers below are
/// the ones CONTRACT.md quotes — if one of them moves, either the fixture was
/// regenerated or something is dropping rows, and both are worth a failing test.
final class FixtureSlotsRemoteTests: XCTestCase {

    func testGoldenIsTheWholeScrape() async throws {
        let payload = try await FixtureSlotsRemote(.golden).fetchPayload()

        XCTAssertEqual(payload.contractVersion, Contract.version)
        XCTAssertEqual(payload.courses.count, 15, "the roster is frozen at 15")
        XCTAssertEqual(payload.slots.count, 1755)
        XCTAssertTrue(payload.issues.isEmpty, "a real scrape decodes clean: \(payload.issues)")
        XCTAssertEqual(payload.slots.filter(\.priceIsUnknown).count, 282,
                       "one slot in six publishes no price, and all of them are still inventory")
        XCTAssertEqual(payload.slots.filter { $0.holes == 9 }.count, 301,
                       "every 9-hole booking: 176 at Woollahra, which is a 9-hole course, "
                       + "plus the 125 that CONTRACT.md counts on 18-hole courses")
    }

    func testMinimalIsTheAssertableOne() async throws {
        let payload = try await FixtureSlotsRemote(.minimal).fetchPayload()

        XCTAssertEqual(payload.slots.count, 9)
        XCTAssertEqual(payload.courses.count, 15)
        XCTAssertTrue(payload.issues.isEmpty)

        let twoTeeStart = payload.slots.filter {
            $0.courseSlug == "warringah" && $0.teeTime == "06:16:00"
        }
        XCTAssertEqual(twoTeeStart.count, 2, "minimal carries one example of every awkward case")
        XCTAssertEqual(Set(twoTeeStart.map(\.id)).count, 2)
    }

    func testDefaultIsGolden() async throws {
        let payload = try await FixtureSlotsRemote().fetchPayload()
        XCTAssertEqual(payload.slots.count, 1755)
    }

    // MARK: - The states a screen has to get right

    /// Track C needs an offline state without unplugging anything.
    func testInjectedFailureIsWhatIsThrown() async throws {
        let remote = FixtureSlotsRemote(.minimal, failure: DataError.offline)

        do {
            _ = try await remote.fetchPayload()
            XCTFail("the injected failure must surface")
        } catch let error as DataError {
            XCTAssertEqual(error, .offline)
        }
    }

    /// And a loading state that lasts long enough to see.
    func testDelayIsObservedBeforeTheResult() async throws {
        let remote = FixtureSlotsRemote(.minimal, delay: .milliseconds(150))

        let elapsed = try await ContinuousClock().measure {
            _ = try await remote.fetchPayload()
        }

        XCTAssertGreaterThan(elapsed, .milliseconds(100))
    }

    /// The failure comes after the delay: a request that fails the instant it
    /// starts is not what a train tunnel looks like, and a spinner that never
    /// appears is a state that never gets designed.
    func testFailureComesAfterTheDelay() async throws {
        let remote = FixtureSlotsRemote(.minimal, delay: .milliseconds(120),
                                        failure: DataError.offline)

        let elapsed = await ContinuousClock().measure {
            do {
                _ = try await remote.fetchPayload()
                XCTFail("expected the injected failure")
            } catch {
                XCTAssertEqual(error as? DataError, .offline)
            }
        }

        XCTAssertGreaterThan(elapsed, .milliseconds(80))
    }

    func testAMissingFixtureIsADataErrorNotACrash() async throws {
        // The test bundle carries no fixtures; they are resources of the
        // contract framework.
        let remote = FixtureSlotsRemote(.golden, bundle: Bundle(for: type(of: self)))

        do {
            _ = try await remote.fetchPayload()
            XCTFail("there is no fixture in this bundle")
        } catch let error as DataError {
            guard case .cacheUnavailable(let why) = error else {
                return XCTFail("expected .cacheUnavailable, got \(error.diagnostic)")
            }
            XCTAssertTrue(why.contains("golden"), why)
        }
    }

    // MARK: - The same window the live remote applies

    func testFastModeTrimsToTheNearDays() async throws {
        let full = try await FixtureSlotsRemote(.golden).fetchPayload()
        let fast = try await FixtureSlotsRemote(.golden).fetchPayload(mode: .fast, days: 3)

        XCTAssertEqual(fast.mode, .fast)
        XCTAssertEqual(fast.days, 3)
        XCTAssertEqual(Set(fast.slots.map(\.teeDate)).count, 3)
        XCTAssertLessThan(fast.slots.count, full.slots.count)
        XCTAssertEqual(Set(fast.slots.map(\.teeDate)),
                       Set(Set(full.slots.map(\.teeDate)).sorted().prefix(3)))
        XCTAssertEqual(fast.courses.count, 15, "trimming days never trims the roster")
    }

    func testAskingForMoreDaysThanTheFixtureHasKeepsItWhole() async throws {
        let payload = try await FixtureSlotsRemote(.golden).fetchPayload(mode: .full, days: 30)

        XCTAssertEqual(payload.slots.count, 1755)
        XCTAssertEqual(payload.days, 5, "the fixture's own day count, not the one we asked for")
    }

    func testItIsUsableAsASlotsFetching() async throws {
        let remote: any SlotsFetching = FixtureSlotsRemote(.minimal)
        let payload = try await remote.fetchPayload()
        XCTAssertEqual(payload.slots.count, 9)
    }
}
