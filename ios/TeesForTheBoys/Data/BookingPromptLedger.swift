import Foundation
import TeesContract

/// Which slots this device has already asked "did you book?" about.
///
/// ## Asked once. That is the whole product rule.
///
/// The golfer taps out to MiClub, comes back, and gets one question. A yes
/// becomes a ``Booking``. A no, or a swipe away, or a phone call landing on top
/// of the prompt — all of those cost them nothing and are never asked again for
/// that slot. Re-asking is the behaviour that makes an app feel like it is
/// nagging, and the thing being asked about (a tee time you may well not have
/// booked) is not worth a second prompt.
///
/// ## Why this is local and why it is not the disk cache
///
/// Local, because it is a fact about this phone's UI and not about the user's
/// data: a prompt shown on the iPad has nothing to say about the iPhone, and
/// `bookings` already records the answers that mattered.
///
/// Not the payload cache, because that file belongs to another ticket and
/// holds scraped tee times which are thrown away and rewritten wholesale on
/// every refresh. Answers must not evaporate with a cache clear.
/// `UserDefaults` is the right size of thing: a few dozen slot ids.
///
/// ## Pruning
///
/// An entry is only worth keeping until its tee time has passed — after that
/// the slot cannot be booked and will never be asked about again. Pruning on
/// every read keeps the stored dictionary the size of "rounds you looked at
/// this week" rather than growing for the life of the install.
public final class BookingPromptLedger: @unchecked Sendable {

    /// The `UserDefaults` key. One dictionary of slot id to tee time, because
    /// the tee time is what says when the entry can be thrown away.
    public static let storageKey = "tees.bookingPromptLedger.v1"

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    /// - Parameters:
    ///   - defaults: injectable so a test gets its own suite instead of
    ///     scribbling on the app's.
    ///   - now: injectable so pruning can be tested on a boundary rather than
    ///     waited out.
    public init(
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.now = now
    }

    // MARK: - Asking

    /// Whether to show the prompt for this slot.
    ///
    /// False once ``recordAsked(slot:)`` has been called for it, whatever the
    /// answer was — a no is an answer.
    public func shouldAsk(about slot: Slot) -> Bool {
        shouldAsk(slotID: slot.id)
    }

    /// Reads, and deliberately does not write: asking a question should not
    /// cost a disk write, and the stored dictionary is tidied by
    /// ``recordAsked(slotID:teeAt:)`` and ``prune()`` instead.
    public func shouldAsk(slotID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return prunedEntries()[slotID] == nil
    }

    /// Remember that the prompt was shown for this slot.
    ///
    /// Call it when the prompt appears, not when it is answered: a prompt
    /// dismissed by a phone call has still been asked, and asking again is the
    /// thing this type exists to prevent.
    public func recordAsked(slot: Slot) {
        recordAsked(slotID: slot.id, teeAt: slot.teeAt)
    }

    public func recordAsked(slotID: String, teeAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        var entries = prunedEntries()
        entries[slotID] = teeAt.timeIntervalSince1970
        write(entries)
    }

    // MARK: - Housekeeping

    /// Drop entries whose tee time is in the past. Happens as a side effect of
    /// recording an answer; public so a launch can do it explicitly.
    public func prune() {
        lock.lock()
        defer { lock.unlock() }
        write(prunedEntries())
    }

    /// The slots currently remembered. Diagnostics and tests.
    public var askedSlotIDs: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(prunedEntries().keys)
    }

    /// Forget everything. Sign-out, or a user asking to be asked again.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.storageKey)
    }

    // MARK: - Storage

    /// Stored as `[slot id: tee time as a unix timestamp]`. A plain
    /// `[String: Double]` so it is a property list without a coder, and so a
    /// future version reading it can still make sense of it.
    private func prunedEntries() -> [String: Double] {
        let stored = defaults.dictionary(forKey: Self.storageKey) as? [String: Double] ?? [:]
        let cutoff = now().timeIntervalSince1970
        return stored.filter { $0.value > cutoff }
    }

    private func write(_ entries: [String: Double]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else {
            defaults.set(entries, forKey: Self.storageKey)
        }
    }
}
