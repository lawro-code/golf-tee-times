import Foundation
import TeesContract

/// A `SlotsFetching` that reads a bundled fixture instead of the network.
///
/// This is what Stage 2's simulator demo and every screen test run on. `golden`
/// is a real 15-course, 5-day scrape — 1755 slots, 282 of them unpriced, 301
/// of them 9-hole bookings — so a list built against it scrolls like the real
/// thing rather than like six rows of lorem ipsum. `minimal` is nine slots with
/// one example of each awkward case, for asserting against.
///
/// The delay and the failure are injectable because the four states a screen
/// has to get right — loading, empty, stale, offline — are otherwise only
/// reachable by unplugging a network:
///
/// ```swift
/// FixtureSlotsRemote(.golden)                                   // populated
/// FixtureSlotsRemote(.golden, delay: .seconds(2))               // loading
/// FixtureSlotsRemote(.minimal, failure: DataError.offline)      // offline
/// ```
///
/// The failure is thrown *after* the delay: a request that fails instantly is
/// not what a train tunnel looks like.
public struct FixtureSlotsRemote: SlotsFetching {

    public enum Fixture: String, CaseIterable, Sendable {
        /// A real scrape. Big, messy, and the only honest way to test scrolling.
        case golden
        /// Nine slots, deterministic, regenerable. Assert against this one.
        case minimal
    }

    /// An injected error is a value the caller already owns; this box carries it
    /// without demanding that every error type in the app be `Sendable`.
    private struct FailureBox: @unchecked Sendable {
        let error: any Error
    }

    public let fixture: Fixture
    public let delay: Duration
    private let failure: FailureBox?
    private let bundle: Bundle

    public init(
        _ fixture: Fixture = .golden,
        delay: Duration = .zero,
        failure: (any Error)? = nil,
        bundle: Bundle = .contract
    ) {
        self.fixture = fixture
        self.delay = delay
        self.failure = failure.map(FailureBox.init(error:))
        self.bundle = bundle
    }

    // MARK: - SlotsFetching

    public func fetchPayload() async throws -> ContractPayload {
        try await loaded()
    }

    /// The same window bounding the live remote does, so a screen driven by a
    /// fixture and a screen driven by Supabase disagree about nothing.
    public func fetchPayload(mode: ContractPayload.Mode, days: Int) async throws -> ContractPayload {
        let payload = try await loaded()
        return Self.trimmed(payload, mode: mode, days: max(1, days))
    }

    private func loaded() async throws -> ContractPayload {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if let failure {
            throw failure.error
        }
        do {
            let payload = try ContractLoader.fixture(fixture.rawValue, bundle: bundle)
            // A fixture goes through the same issue logging a live read does.
            // A fixture that has started dropping rows is a broken fixture, and
            // silence is how that stays unnoticed for a week.
            DataLog.dropped(payload.issues)
            return payload
        } catch {
            throw DataError.from(error)
        }
    }

    // MARK: - Windowing

    /// Keep the first `days` calendar days the fixture covers. Dates are
    /// compared as the `YYYY-MM-DD` strings the contract stores, which sort
    /// chronologically — no timezone arithmetic, and none needed.
    static func trimmed(
        _ payload: ContractPayload, mode: ContractPayload.Mode, days: Int
    ) -> ContractPayload {
        let allDates = Set(payload.slots.map(\.teeDate)).union(payload.courseDays.map(\.teeDate))
        let keep = Set(allDates.sorted().prefix(days))
        guard keep.count < allDates.count else {
            return ContractPayload(
                contractVersion: payload.contractVersion,
                generatedAt: payload.generatedAt,
                mode: mode,
                days: payload.days,
                courses: payload.courses,
                slots: payload.slots,
                courseDays: payload.courseDays,
                issues: payload.issues)
        }
        return ContractPayload(
            contractVersion: payload.contractVersion,
            generatedAt: payload.generatedAt,
            mode: mode,
            days: keep.count,
            courses: payload.courses,
            slots: payload.slots.filter { keep.contains($0.teeDate) },
            courseDays: payload.courseDays.filter { keep.contains($0.teeDate) },
            issues: payload.issues)
    }
}
