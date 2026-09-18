import Foundation
import TeesContract

/// The app's on-disk copy of the last payload we managed to fetch.
///
/// Two product promises rest on this file. The app opens on tee times rather
/// than a spinner, and it keeps working on a train with no signal. Both are
/// the same mechanism: whatever we last saw, written down.
///
/// Layout:
///
///     Application Support/TeesData/payload-1.0.0.json
///
/// The contract version is part of the filename deliberately. When the
/// contract moves to 1.1.0 the old file is simply not the one this build looks
/// for, so a stale payload can never be decoded as the new shape and silently
/// half-populate a screen. `load()` sweeps the orphans it finds on the way
/// past.
///
/// The rule that shapes every error path here: **a bad cache is never a launch
/// crash.** Missing, truncated, corrupt, written by a future version — all of
/// them return `nil` and let the network try. Losing the cache costs a
/// spinner; throwing out of it costs the launch.
public struct DiskPayloadCache: PayloadCaching {

    // MARK: - Location

    /// The directory name under Application Support. Not the Caches directory:
    /// the system may evict Caches under disk pressure, and the one time we
    /// want this file most is the time the phone is in a bad way.
    public static let directoryName = "TeesData"

    public static func fileName(contractVersion: String = Contract.version) -> String {
        "payload-\(contractVersion).json"
    }

    /// Application Support is not guaranteed to resolve on every platform
    /// configuration, and a cache is not worth a trap on launch. If it is
    /// missing we fall back to a temporary directory: the cache then behaves
    /// like a cache that keeps getting swept, which is degraded but alive.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Injected so tests write into a temp directory instead of the simulator's
    /// real Application Support, where one test run would leak into the next.
    public let directory: URL
    public let contractVersion: String

    public init(
        directory: URL = DiskPayloadCache.defaultDirectory(),
        contractVersion: String = Contract.version
    ) {
        self.directory = directory
        self.contractVersion = contractVersion
    }

    public var fileURL: URL {
        directory.appendingPathComponent(
            Self.fileName(contractVersion: contractVersion), isDirectory: false)
    }

    // MARK: - What actually gets written

    /// The payload plus when we fetched it. `fetchedAt` is the whole point of
    /// the envelope — staleness is a property of the read, not of the data,
    /// and `generated_at` inside the payload answers a different question
    /// (when the scraper ran, not when this device last heard from it).
    struct Envelope: Codable {
        let contractVersion: String
        let fetchedAt: Date
        let payload: ContractPayload

        enum CodingKeys: String, CodingKey {
            case contractVersion = "contract_version"
            case fetchedAt = "fetched_at"
            case payload
        }
    }

    // MARK: - PayloadCaching

    public func load() throws -> CachedPayload? {
        sweepOtherVersions()

        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil          // first launch. Not an error, just nothing yet.
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            cacheLog("could not read \(url.lastPathComponent): \(error). Discarding.")
            discard()
            return nil
        }

        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.contractVersion == contractVersion,
                  envelope.payload.contractVersion == contractVersion else {
                cacheLog("""
                    cache holds contract \(envelope.contractVersion)/\
                    \(envelope.payload.contractVersion), this build wants \
                    \(contractVersion). Discarding.
                    """)
                discard()
                return nil
            }
            return CachedPayload(payload: envelope.payload, fetchedAt: envelope.fetchedAt)
        } catch {
            // Truncated by a crash mid-write on an older build, or garbage.
            // Delete it so we do not re-read the same bad bytes every launch.
            cacheLog("cache is corrupt (\(error)). Discarding — a bad cache is not a crash.")
            discard()
            return nil
        }
    }

    public func save(_ payload: ContractPayload, fetchedAt: Date) throws {
        do {
            try ensureDirectory()

            let envelope = Envelope(
                contractVersion: contractVersion, fetchedAt: fetchedAt, payload: payload)
            let data = try JSONEncoder().encode(envelope)

            // .atomic writes a sibling temp file and renames it, so a crash
            // or a kill mid-write leaves the previous good file untouched
            // rather than half of the new one.
            //
            // .completeFileProtectionUntilFirstUserAuthentication, not the
            // stricter .complete: a background refresh has to be able to read
            // this while the phone is locked, which .complete would forbid.
            // The device still has to have been unlocked once since boot.
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])

            excludeFromBackup(fileURL)
        } catch {
            // No NSError leaves this module. A caller that cannot write the
            // cache has a degraded app, not a broken one, so it gets a typed
            // failure it can decide to ignore.
            throw DataError.cacheUnavailable(String(describing: error))
        }
    }

    public func clear() throws {
        discard()
        sweepOtherVersions()
    }

    // MARK: - Housekeeping

    private func ensureDirectory() throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if !manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: nil)
        }
        // Every byte in here is regenerable from the network. Backing it up
        // wastes the user's iCloud quota and, worse, can restore a months-old
        // payload onto a new phone.
        excludeFromBackup(directory)
    }

    private func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
        } catch {
            cacheLog("could not exclude \(target.lastPathComponent) from backup: \(error)")
        }
    }

    private func discard() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Delete cache files left behind by a different contract version. Without
    /// this, every version bump leaks a file that is never read again.
    private func sweepOtherVersions() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        let keep = Self.fileName(contractVersion: contractVersion)
        for name in names
        where name != keep && name.hasPrefix("payload-") && name.hasSuffix(".json") {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
            cacheLog("swept orphaned cache \(name)")
        }
    }
}

/// One funnel for this file's logging. Everything here is cache mechanics and
/// error shapes — never a person, never a token — so it is safe to mark
/// `.public` and actually be readable in Console.
private func cacheLog(_ message: String) {
    DataLog.cache.error("DiskPayloadCache: \(message, privacy: .public)")
}
