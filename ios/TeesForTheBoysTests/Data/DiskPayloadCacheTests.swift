import XCTest
import TeesContract
@testable import TeesData

/// Deterministic payloads for the B3 tests.
///
/// Built in code rather than loaded from a fixture so that a cache test is
/// about the cache and not about bundle resource resolution. Every date is on
/// a whole second, because the contract encodes `tee_at` without fractional
/// seconds and a round-trip has to compare equal.
enum B3Fixtures {

    /// A fixed instant. Nothing in these tests reads the real clock.
    static let t0 = Date(timeIntervalSince1970: 1_789_000_000)

    static func course(slug: String = "warringah", sortOrder: Int = 1) -> Course {
        Course(
            slug: slug,
            name: "Warringah Golf Club",
            region: "Northern Beaches",
            host: "warringah.miclub.com.au",
            feeGroupID: "3000000",
            holes: 18,
            par: 70,
            lengthMetres: nil,
            driveMinutesFromBondi: 32,
            requiresRegistration: false,
            address: nil,
            notes: "",
            sortOrder: sortOrder)
    }

    /// Defaults to a two-tee slot id, because that is the shape the contract
    /// froze and a cache that mangled it would be worth catching here.
    static func slot(
        id: String = "warringah:2026-09-18:0616:1st-tee-social",
        teeTime: String = "06:16:00",
        bookingType: String = "1st Tee Social",
        holes: Int = 18,
        priceMin: Double? = 45
    ) -> Slot {
        Slot(
            id: id,
            courseSlug: "warringah",
            courseName: "Warringah Golf Club",
            region: "Northern Beaches",
            driveMinutesFromBondi: 32,
            par: 70,
            lengthMetres: nil,
            requiresRegistration: false,
            teeDate: "2026-09-18",
            teeTime: teeTime,
            teeAt: t0,
            spotsAvailable: 2,
            totalSpots: 4,
            holes: holes,
            priceMin: priceMin,
            priceMax: priceMin,
            priceTiers: [],
            bookingType: bookingType,
            bookingURLString: "https://warringah.miclub.com.au/guests/bookings/x")
    }

    static func courseDay(ok: Bool = true, slotCount: Int = 1) -> CourseDay {
        CourseDay(
            courseSlug: "warringah",
            teeDate: "2026-09-18",
            ok: ok,
            slotCount: slotCount,
            error: ok ? nil : "500",
            lastAttemptAt: t0,
            lastSuccessAt: ok ? t0 : nil)
    }

    /// `count` distinct slots, ids differing in the minute so they stay unique.
    static func payload(slots count: Int = 9, generatedAt: String = "2026-09-18T06:00:00+10:00")
        -> ContractPayload {
        let slots = (0..<count).map { index -> Slot in
            let minute = String(format: "%02d", index)
            return slot(
                id: "warringah:2026-09-18:06\(minute):1st-tee-social",
                teeTime: "06:\(minute):00")
        }
        return ContractPayload(
            contractVersion: Contract.version,
            generatedAt: generatedAt,
            mode: .full,
            days: 5,
            courses: [course()],
            slots: slots,
            courseDays: [courseDay()])
    }
}

/// The rule every one of these is about: **a bad cache is never a launch
/// crash.** Missing, truncated, corrupt, left behind by an older contract —
/// each of them has to come back as `nil` and let the network try.
final class DiskPayloadCacheTests: XCTestCase {

    private var directory: URL!
    private var cache: DiskPayloadCache!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A temp directory per test. Never the simulator's real Application
        // Support, which would leak one test run into the next.
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("B3DiskCache-\(UUID().uuidString)", isDirectory: true)
        cache = DiskPayloadCache(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        cache = nil
        try super.tearDownWithError()
    }

    // MARK: - The happy path

    func testSavedPayloadRoundTripsExactly() throws {
        let original = B3Fixtures.payload(slots: 9)
        try cache.save(original, fetchedAt: B3Fixtures.t0)

        let loaded = try XCTUnwrap(cache.load())
        XCTAssertEqual(loaded.payload, original, "a round trip must not alter the payload")
        XCTAssertEqual(loaded.fetchedAt, B3Fixtures.t0)
        XCTAssertEqual(loaded.payload.slots.count, 9)
        XCTAssertEqual(
            loaded.payload.slots.first?.id, "warringah:2026-09-18:0600:1st-tee-social",
            "the two-tee slot id has to survive verbatim")
    }

    /// `fetchedAt` is the cache's own timestamp, and it is not
    /// `payload.generatedAt`. Staleness is measured against this one.
    func testFetchedAtIsStoredSeparatelyFromGeneratedAt() throws {
        let payload = B3Fixtures.payload(generatedAt: "2026-09-18T06:00:00+10:00")
        let fetched = B3Fixtures.t0.addingTimeInterval(3600)
        try cache.save(payload, fetchedAt: fetched)

        let loaded = try XCTUnwrap(cache.load())
        XCTAssertEqual(loaded.fetchedAt, fetched)
        XCTAssertEqual(loaded.payload.generatedAt, "2026-09-18T06:00:00+10:00")
    }

    func testDirectoryIsCreatedOnDemand() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                       "precondition: nothing exists yet")

        try cache.save(B3Fixtures.payload(), fetchedAt: B3Fixtures.t0)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(cache.fileURL.lastPathComponent, "payload-\(Contract.version).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.fileURL.path))
    }

    func testSecondSaveReplacesTheFirstAndLeavesNothingBehind() throws {
        try cache.save(B3Fixtures.payload(slots: 2), fetchedAt: B3Fixtures.t0)
        try cache.save(B3Fixtures.payload(slots: 5), fetchedAt: B3Fixtures.t0)

        XCTAssertEqual(try XCTUnwrap(cache.load()).payload.slots.count, 5)

        // .atomic writes through a sibling temp file. If one were ever left
        // behind, a directory listing is where it would show up.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents, ["payload-\(Contract.version).json"])
    }

    /// The file is regenerable from the network. Backing it up spends the
    /// user's iCloud quota and can restore a months-old payload onto a new
    /// phone.
    func testCacheIsExcludedFromICloudBackup() throws {
        try cache.save(B3Fixtures.payload(), fetchedAt: B3Fixtures.t0)

        let fileValues = try cache.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(fileValues.isExcludedFromBackup, true)

        let directoryValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(directoryValues.isExcludedFromBackup, true)
    }

    // MARK: - Nothing there

    func testMissingFileIsNilRatherThanAnError() throws {
        XCTAssertNil(try cache.load(), "first launch is not a failure")
    }

    func testLoadOnAMissingDirectoryDoesNotCreateIt() throws {
        XCTAssertNil(try cache.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                       "a read must not leave a directory behind")
    }

    // MARK: - Bad bytes

    func testCorruptFileIsDeletedAndTheNextLaunchStillWorks() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data("this is not json, it is a photo of a golf course".utf8)
            .write(to: cache.fileURL)

        XCTAssertNil(try cache.load(), "a corrupt cache reads as nothing, never as a throw")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cache.fileURL.path),
            "the bad bytes must be deleted, or every launch re-reads them")

        // And the app recovers completely on the next successful fetch.
        try cache.save(B3Fixtures.payload(slots: 3), fetchedAt: B3Fixtures.t0)
        XCTAssertEqual(try XCTUnwrap(cache.load()).payload.slots.count, 3)
    }

    /// What a crash mid-write used to look like before `.atomic`: a real file,
    /// half of it.
    func testTruncatedFileIsDeleted() throws {
        try cache.save(B3Fixtures.payload(slots: 9), fetchedAt: B3Fixtures.t0)
        let whole = try Data(contentsOf: cache.fileURL)
        try whole.prefix(whole.count / 2).write(to: cache.fileURL)

        XCTAssertNil(try cache.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL.path))
    }

    func testEmptyFileIsDeleted() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data().write(to: cache.fileURL)

        XCTAssertNil(try cache.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL.path))
    }

    // MARK: - Contract versions

    /// The version in the filename means a bump orphans the old file instead of
    /// decoding it as the new shape. Those orphans have to be swept or they
    /// accumulate forever.
    func testStaleVersionFilesAreSweptOnLoad() throws {
        try cache.save(B3Fixtures.payload(), fetchedAt: B3Fixtures.t0)
        let orphan = directory.appendingPathComponent("payload-0.9.0.json")
        let unrelated = directory.appendingPathComponent("something-else.txt")
        try Data("old".utf8).write(to: orphan)
        try Data("keep".utf8).write(to: unrelated)

        XCTAssertNotNil(try cache.load())

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path),
                       "a cache from another contract version is dead weight")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.fileURL.path),
                      "the current version's file is not an orphan")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path),
                      "the sweep only claims payload-*.json")
    }

    /// Belt and braces: a file whose *name* says the right version but whose
    /// contents say another. The filename is a convention, not a guarantee.
    func testAPayloadFromAnotherContractVersionIsRejected() throws {
        let cacheOfAnotherAge = DiskPayloadCache(directory: directory, contractVersion: "0.9.0")
        try cacheOfAnotherAge.save(B3Fixtures.payload(), fetchedAt: B3Fixtures.t0)
        // Rename it into this version's slot.
        try FileManager.default.moveItem(at: cacheOfAnotherAge.fileURL, to: cache.fileURL)

        XCTAssertNil(try cache.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL.path))
    }

    func testTwoContractVersionsDoNotShareAFile() {
        let other = DiskPayloadCache(directory: directory, contractVersion: "2.0.0")
        XCTAssertNotEqual(cache.fileURL, other.fileURL)
        XCTAssertEqual(other.fileURL.lastPathComponent, "payload-2.0.0.json")
    }

    // MARK: - Clearing

    func testClearRemovesEverythingItOwns() throws {
        try cache.save(B3Fixtures.payload(), fetchedAt: B3Fixtures.t0)
        let orphan = directory.appendingPathComponent("payload-0.9.0.json")
        try Data("old".utf8).write(to: orphan)

        try cache.clear()

        XCTAssertNil(try cache.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testClearOnAnEmptyCacheIsNotAnError() throws {
        XCTAssertNoThrow(try cache.clear())
    }

    // MARK: - Failure is typed

    /// No `NSError` leaves this module. A directory that cannot be created —
    /// here, because a file is sitting where the directory should be — comes
    /// back as `DataError.cacheUnavailable`.
    func testAnUnwritableLocationThrowsATypedError() throws {
        try Data("in the way".utf8).write(to: directory)   // a file, not a directory

        XCTAssertThrowsError(try cache.save(B3Fixtures.payload(), fetchedAt: B3Fixtures.t0)) { error in
            guard let typed = error as? DataError, case .cacheUnavailable = typed else {
                XCTFail("expected DataError.cacheUnavailable, got \(error)")
                return
            }
        }
    }

    // MARK: - The other ways a file goes wrong

    /// The decode path has a test; the *read* path did not. A directory sitting
    /// where the file should be is the cheap way to produce it — `fileExists`
    /// says yes and `Data(contentsOf:)` throws. The real-world versions are a
    /// half-restored container and a file whose protection class has not been
    /// unlocked yet. Same rule: nil, not a throw, and clear it out.
    func testAnUnreadableCacheFileIsDiscardedRatherThanThrown() throws {
        try FileManager.default.createDirectory(
            at: cache.fileURL, withIntermediateDirectories: true)   // a directory, not a file
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.fileURL.path),
                      "precondition: something is at the cache path")

        XCTAssertNil(try cache.load(), "unreadable reads as nothing, never as a launch throw")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL.path),
                       "and it is cleared, or every launch trips over the same thing")

        try cache.save(B3Fixtures.payload(slots: 4), fetchedAt: B3Fixtures.t0)
        XCTAssertEqual(try XCTUnwrap(cache.load()).payload.slots.count, 4,
                       "and the app recovers completely")
    }

    /// The envelope on disk is a format, not an implementation detail: the file
    /// today's build writes is the file next week's build reads. Asserted in
    /// both directions so a rename of the coding keys cannot pass silently —
    /// it would orphan the cache on every installed device, and the only
    /// symptom would be a spinner nobody could reproduce.
    func testTheOnDiskEnvelopeFormatIsStable() throws {
        try cache.save(B3Fixtures.payload(slots: 2), fetchedAt: B3Fixtures.t0)

        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: cache.fileURL))
        let keys = Set((written as? [String: Any] ?? [:]).keys)
        XCTAssertEqual(keys, Set(["contract_version", "fetched_at", "payload"]),
                       "three snake_case keys, the same ones a later build will look for")

        // And a file in that shape, built by hand rather than by this encoder,
        // loads. This is what an install upgrading from an older build does.
        let payloadJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(B3Fixtures.payload(slots: 5)))
        let handBuilt: [String: Any] = [
            "contract_version": Contract.version,
            "fetched_at": B3Fixtures.t0.timeIntervalSinceReferenceDate,
            "payload": payloadJSON,
        ]
        try JSONSerialization.data(withJSONObject: handBuilt).write(to: cache.fileURL)

        let loaded = try XCTUnwrap(cache.load())
        XCTAssertEqual(loaded.payload.slots.count, 5)
        XCTAssertEqual(loaded.fetchedAt, B3Fixtures.t0,
                       "fetched_at is seconds since 2001, the way Foundation writes a Date")
    }

    /// A background refresh has to read and rewrite this file while the phone
    /// is locked, so the protection class is
    /// `completeUntilFirstUserAuthentication` — deliberately not the stricter
    /// `complete`, which would make the file unreadable at exactly the moment
    /// it is most wanted.
    func testFileProtectionAllowsABackgroundRefreshWhileLocked() throws {
        try cache.save(B3Fixtures.payload(), fetchedAt: B3Fixtures.t0)

        let attributes = try FileManager.default.attributesOfItem(atPath: cache.fileURL.path)
        let protection = attributes[.protectionKey] as? FileProtectionType

        // The simulator's filesystem is the Mac's. Data protection is not
        // implemented there: the write option is accepted, ignored, and the
        // attribute comes back absent. Asserting anything in that case would be
        // asserting nothing, so this one check is honestly device-only — it is
        // left here, skipping rather than silently passing, so the gap is
        // visible in the test report instead of being forgotten.
        try XCTSkipIf(
            protection == nil,
            "data protection is not implemented on the simulator; run on a device to check this")

        XCTAssertEqual(protection, .completeUntilFirstUserAuthentication,
                       "a locked phone must still be able to refresh in the background")
    }

    /// The version bump from the *new* build's side: it finds a file it cannot
    /// trust, ignores it, sweeps it, and writes its own shape over the top.
    func testANewContractVersionIgnoresAndSweepsTheOldCache() throws {
        try cache.save(B3Fixtures.payload(slots: 9), fetchedAt: B3Fixtures.t0)
        let oldFile = cache.fileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path), "precondition")

        let nextBuild = DiskPayloadCache(directory: directory, contractVersion: "1.1.0")
        XCTAssertNil(try nextBuild.load(), "1.0.0's payload is not 1.1.0's shape")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path),
                       "and the orphan does not sit there forever")

        let nextShape = ContractPayload(
            contractVersion: "1.1.0",
            generatedAt: "2026-09-18T06:00:00+10:00",
            courses: [B3Fixtures.course()],
            slots: [B3Fixtures.slot()],
            courseDays: [B3Fixtures.courseDay()])
        try nextBuild.save(nextShape, fetchedAt: B3Fixtures.t0)
        XCTAssertEqual(try XCTUnwrap(nextBuild.load()).payload.contractVersion, "1.1.0",
                       "the new build's own cache works normally")
    }

    /// `save` stands the directory up every time, not once per process. A
    /// container that was migrated or a sweep that took the folder must not
    /// turn the next write into the first failure.
    func testSaveRebuildsTheDirectoryIfItDisappears() throws {
        try cache.save(B3Fixtures.payload(slots: 2), fetchedAt: B3Fixtures.t0)
        try FileManager.default.removeItem(at: directory)
        XCTAssertNil(try cache.load(), "precondition: the whole directory is gone")

        XCTAssertNoThrow(try cache.save(B3Fixtures.payload(slots: 7), fetchedAt: B3Fixtures.t0))
        XCTAssertEqual(try XCTUnwrap(cache.load()).payload.slots.count, 7)
    }
}
