import XCTest
@testable import TeesPush

/// A tap becoming a route, and the cold launch that would otherwise lose it.
@MainActor
final class PushCoordinatorTests: XCTestCase {

    private let watchID = "6f1c1f0e-0c2e-4f1a-9b0f-2f2a5d9c1a77"
    private let slotID = "the-coast:2026-09-20:0758:public-play"

    private func userInfo(count: Int) -> [AnyHashable: Any] {
        let aps: [String: Any] = [
            "alert": ["title": "The Coast, Sunday 7:58am", "body": "tee times just opened"],
            "sound": "default",
            "thread-id": "watch:\(watchID)",
            "interruption-level": "time-sensitive",
        ]
        let tees: [String: Any] = [
            "v": 1,
            "watch_id": watchID,
            "slot_ids": [slotID],
            "primary_slot_id": slotID,
            "course_slug": "the-coast",
            "course_name": "The Coast Golf Club",
            "tee_at": "2026-09-20T07:58:00+10:00",
            "count": count,
        ]
        return ["aps": aps, "tees": tees]
    }

    // MARK: - Cold launch

    /// **The case that breaks this.** The app was not running, the golfer
    /// tapped, and the route arrives during launch — before any screen exists
    /// to subscribe. A stream with nobody attached drops what it is given, and
    /// a dropped route means the tap goes nowhere.
    func testAColdLaunchRouteReachesASubscriberThatAttachesAfterTheFact() async {
        let coordinator = PushCoordinator()

        // Launch: the tap is handled before any screen is on the air.
        let routed = coordinator.handleTap(userInfo: userInfo(count: 1))
        XCTAssertEqual(routed, .slot(id: slotID))

        // The first screen appears and subscribes, late.
        let stream = coordinator.routes()
        var iterator = stream.makeAsyncIterator()
        let delivered = await iterator.next()

        XCTAssertEqual(delivered, .slot(id: slotID))
    }

    func testAColdLaunchRouteIsAlsoReadableWithoutSubscribing() {
        let coordinator = PushCoordinator()

        coordinator.handleTap(userInfo: userInfo(count: 5))

        XCTAssertEqual(coordinator.latest, .watch(id: watchID))
    }

    /// A tap that has already been handed to a screen is not handed to the next
    /// one: re-navigating on every appearance is its own bug.
    func testADrainedRouteIsNotReplayedToTheNextSubscriber() async {
        let coordinator = PushCoordinator()
        coordinator.deliver(.slot(id: slotID))

        let firstStream = coordinator.routes()
        var first = firstStream.makeAsyncIterator()
        let drained = await first.next()
        XCTAssertEqual(drained, .slot(id: slotID))

        let secondStream = coordinator.routes()
        var second = secondStream.makeAsyncIterator()
        coordinator.deliver(.watch(id: watchID))

        // If the buffer had replayed, this would be the slot again.
        let next = await second.next()
        XCTAssertEqual(next, .watch(id: watchID))
    }

    // MARK: - Live routes

    func testASubscribedScreenReceivesRoutesAsTheyArrive() async {
        let coordinator = PushCoordinator()
        let stream = coordinator.routes()
        var iterator = stream.makeAsyncIterator()

        coordinator.handleTap(userInfo: userInfo(count: 3))

        let delivered = await iterator.next()
        XCTAssertEqual(delivered, .watch(id: watchID))
        XCTAssertEqual(coordinator.latest, .watch(id: watchID))
    }

    func testTwoScreensBothHearTheSameRoute() async {
        let coordinator = PushCoordinator()
        let firstStream = coordinator.routes()
        var first = firstStream.makeAsyncIterator()
        let secondStream = coordinator.routes()
        var second = secondStream.makeAsyncIterator()

        coordinator.deliver(.slot(id: slotID))

        let toFirst = await first.next()
        let toSecond = await second.next()
        XCTAssertEqual(toFirst, .slot(id: slotID))
        XCTAssertEqual(toSecond, .slot(id: slotID))
    }

    // MARK: - The routing rule, through the coordinator

    func testOneMatchOpensTheSlotAndSeveralOpenTheWatch() {
        let cases: [(count: Int, expected: PushRoute)] = [
            (1, .slot(id: slotID)),
            (5, .watch(id: watchID)),
        ]

        for test in cases {
            let coordinator = PushCoordinator()
            XCTAssertEqual(
                coordinator.handleTap(userInfo: userInfo(count: test.count)),
                test.expected,
                "count \(test.count)")
        }
    }

    // MARK: - Nothing to route

    func testANotificationThatIsNotOursGoesNowhere() {
        let coordinator = PushCoordinator()

        let routed = coordinator.handleTap(userInfo: ["aps": ["alert": "from some other app"]])

        XCTAssertNil(routed)
        XCTAssertNil(coordinator.latest)
    }

    func testAPayloadNamingNeitherASlotNorAWatchGoesNowhere() {
        let coordinator = PushCoordinator()
        var info = userInfo(count: 1)
        let tees: [String: Any] = [
            "v": 1,
            "slot_ids": [String](),
            "course_slug": "the-coast",
            "course_name": "The Coast Golf Club",
            "tee_at": "2026-09-20T07:58:00+10:00",
            "count": 1,
        ]
        info["tees"] = tees

        XCTAssertNil(coordinator.handleTap(userInfo: info))
        XCTAssertNil(coordinator.latest)
    }

    func testClearingTheLatestRouteStopsItBeingActedOnTwice() {
        let coordinator = PushCoordinator()
        coordinator.deliver(.slot(id: slotID))

        coordinator.clearLatest()

        XCTAssertNil(coordinator.latest)
    }

    // MARK: - The buffer, when several taps land before a screen exists

    /// A phone left overnight can be tapped more than once before the app is
    /// opened. The newest routes reach the screen, in order, and the stale
    /// ones are dropped rather than queued in front of them — a golfer who
    /// taps the 7am and then the 8am must land on the 8am, not be walked
    /// through everything they tapped since.
    func testTheOldestBufferedRoutesAreDroppedAndTheNewestArriveInOrder() async {
        let coordinator = PushCoordinator()
        let ids = (1...6).map { "the-coast:2026-09-2\($0):0758:public-play" }

        for id in ids { coordinator.deliver(.slot(id: id)) }

        let stream = coordinator.routes()
        var iterator = stream.makeAsyncIterator()
        var drained: [PushRoute] = []
        for _ in 0..<4 {
            guard let route = await iterator.next() else { break }
            drained.append(route)
        }

        XCTAssertEqual(drained, ids.suffix(4).map { PushRoute.slot(id: $0) })
        XCTAssertEqual(coordinator.latest, .slot(id: ids[5]))
    }

    /// Every screen has gone — backgrounded, or torn down between tests — and
    /// then a tap arrives. Yielding it into a finished stream loses it for
    /// good; it has to be held for whoever subscribes next. This is the cold
    /// launch case again, arriving the other way round.
    func testARouteDeliveredAfterEveryStreamHasFinishedIsHeldForTheNextScreen() async {
        let coordinator = PushCoordinator()
        let firstStream = coordinator.routes()
        var first = firstStream.makeAsyncIterator()
        coordinator.finish()
        let ended = await first.next()
        XCTAssertNil(ended, "finish should end the stream it handed out")

        coordinator.deliver(.watch(id: watchID))

        let delivered = await Self.firstRoute(from: coordinator.routes())
        XCTAssertEqual(
            delivered, .watch(id: watchID),
            "the route was yielded into a dead stream and lost")
    }

    // MARK: - A push this build cannot read

    /// A sender two versions ahead, and somebody else's notification. Neither
    /// routes anywhere, and neither is allowed to wipe the route a screen has
    /// not acted on yet — clearing it is how a cold-launch tap disappears
    /// because an unrelated notification was tapped a second later.
    func testAPushThisBuildCannotReadLeavesTheLastGoodRouteAlone() async {
        let coordinator = PushCoordinator()
        coordinator.deliver(.slot(id: slotID))

        XCTAssertNil(coordinator.handleTap(userInfo: ["aps": ["alert": "from some other app"]]))
        XCTAssertNil(coordinator.handleTap(
            userInfo: userInfo(count: 1, overriding: "v", with: 99)))

        XCTAssertEqual(coordinator.latest, .slot(id: slotID))
        // And nothing unroutable was queued behind the good one.
        let delivered = await Self.firstRoute(from: coordinator.routes())
        XCTAssertEqual(delivered, .slot(id: slotID))
    }

    // MARK: -

    private func userInfo(
        count: Int, overriding key: String, with value: Any?
    ) -> [AnyHashable: Any] {
        var info = userInfo(count: count)
        var tees = (info["tees"] as? [String: Any]) ?? [:]
        if let value { tees[key] = value } else { tees.removeValue(forKey: key) }
        info["tees"] = tees
        return info
    }

    /// `next()` on a stream that is never given anything waits forever, which
    /// in a gate is a hung build rather than a failed test. This gives up.
    private static func firstRoute(
        from stream: AsyncStream<PushRoute>, timeout: TimeInterval = 2
    ) async -> PushRoute? {
        await withTaskGroup(of: PushRoute?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
