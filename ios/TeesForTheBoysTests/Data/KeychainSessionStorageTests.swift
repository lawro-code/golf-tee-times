import Security
import XCTest
@testable import TeesData

/// The keychain half of "stay signed in".
///
/// A host-less unit-test bundle has no keychain access group, so the simulator
/// answers every call with `errSecMissingEntitlement` (-34018). That says
/// nothing about this code, so these tests skip on it rather than fail — and
/// `InMemorySessionStorage`, which is what a test double and the previews use,
/// is exercised unconditionally below.
final class KeychainSessionStorageTests: XCTestCase {

    private let service = "code.lawro.TeesForTheBoys.session.b1-tests"
    private lazy var storage = KeychainSessionStorage(service: service)
    private let key = "b1-session"

    override func tearDown() {
        try? storage.remove(key: key)
        super.tearDown()
    }

    // MARK: - Keychain

    func testASessionSurvivesAStoreAndRetrieve() throws {
        try b1SkippingWhenTheKeychainIsUnavailable {
            let value = Data("a session blob".utf8)
            try storage.store(key: key, value: value)
            let stored = try storage.retrieve(key: key)
            XCTAssertEqual(stored, value)
        }
    }

    func testStoringTwiceReplacesRatherThanDuplicates() throws {
        try b1SkippingWhenTheKeychainIsUnavailable {
            try storage.store(key: key, value: Data("first".utf8))
            try storage.store(key: key, value: Data("second".utf8))
            let stored = try storage.retrieve(key: key)
            XCTAssertEqual(stored, Data("second".utf8))
        }
    }

    func testNothingStoredIsNilRatherThanAnError() throws {
        try b1SkippingWhenTheKeychainIsUnavailable {
            // The `try` is hoisted out of the assertion deliberately.
            // `XCTAssertNil(try …)` swallows the throw and records a failure,
            // so the skip helper below never sees the entitlement refusal that
            // every other keychain test here skips on.
            let stored = try storage.retrieve(key: "b1-never-written")
            XCTAssertNil(stored)
        }
    }

    func testRemovingIsIdempotentSoSignOutCannotFailTwice() throws {
        try b1SkippingWhenTheKeychainIsUnavailable {
            try storage.store(key: key, value: Data("a session blob".utf8))
            try storage.remove(key: key)
            try storage.remove(key: key)
            let stored = try storage.retrieve(key: key)
            XCTAssertNil(stored)
        }
    }

    func testTheItemIsReadableAfterFirstUnlockSoABackgroundRefreshCanReachIt() throws {
        try b1SkippingWhenTheKeychainIsUnavailable {
            try storage.store(key: key, value: Data("a session blob".utf8))

            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            query[kSecReturnData as String] = false

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess, let attributes = item as? [String: Any] else {
                return XCTFail("could not read the item's attributes back (OSStatus \(status))")
            }
            XCTAssertEqual(
                attributes[kSecAttrAccessible as String] as? String,
                kSecAttrAccessibleAfterFirstUnlock as String,
                "WhenUnlocked would lock a background refresh out of the session")
        }
    }

    func testTwoServicesDoNotSeeEachOthersSessions() throws {
        try b1SkippingWhenTheKeychainIsUnavailable {
            let other = KeychainSessionStorage(service: service + ".other")
            let account = key
            addTeardownBlock { try? other.remove(key: account) }

            try storage.store(key: key, value: Data("ours".utf8))
            XCTAssertNil(
                try other.retrieve(key: key),
                "the service has to scope the item, or the app and a test share one session")
        }
    }

    // MARK: - Error mapping

    func testTheEntitlementFailureIsRecognisableSoTestsCanSkipIt() {
        let entitlement = DataError.cacheUnavailable(
            "keychain store failed (OSStatus \(KeychainSessionStorage.missingEntitlementStatus))")
        XCTAssertTrue(KeychainSessionStorage.isMissingEntitlement(entitlement))

        XCTAssertFalse(
            KeychainSessionStorage.isMissingEntitlement(
                DataError.cacheUnavailable("keychain store failed (OSStatus -25300)")))
        XCTAssertFalse(KeychainSessionStorage.isMissingEntitlement(DataError.offline))
        XCTAssertFalse(KeychainSessionStorage.isMissingEntitlement(URLError(.timedOut)))
    }

    // MARK: - In memory

    func testInMemoryStorageRoundTrips() throws {
        let memory = InMemorySessionStorage()
        XCTAssertNil(try memory.retrieve(key: key))

        try memory.store(key: key, value: Data("a session blob".utf8))
        XCTAssertEqual(try memory.retrieve(key: key), Data("a session blob".utf8))
        XCTAssertEqual(memory.storedKeys, [key])

        try memory.store(key: key, value: Data("replaced".utf8))
        XCTAssertEqual(try memory.retrieve(key: key), Data("replaced".utf8))

        try memory.remove(key: key)
        XCTAssertNil(try memory.retrieve(key: key))
        XCTAssertTrue(memory.storedKeys.isEmpty)
    }

    func testInMemoryStorageRemovesOnlyTheKeyItWasGiven() throws {
        // Sign-out removes one key. A `remove` that emptied the store would
        // pass every round-trip test above and quietly drop the PKCE verifier
        // the SDK keeps alongside the session.
        let memory = InMemorySessionStorage()
        try memory.store(key: SupabaseClientProvider.sessionStorageKey, value: Data("session".utf8))
        try memory.store(key: "b1-code-verifier", value: Data("verifier".utf8))

        try memory.remove(key: "b1-code-verifier")

        XCTAssertEqual(memory.storedKeys, [SupabaseClientProvider.sessionStorageKey])
        XCTAssertEqual(
            try memory.retrieve(key: SupabaseClientProvider.sessionStorageKey),
            Data("session".utf8))
    }

    func testInMemoryStorageIsSafeFromManyThreads() {
        let memory = InMemorySessionStorage()
        DispatchQueue.concurrentPerform(iterations: 128) { iteration in
            try? memory.store(key: "b1-\(iteration % 8)", value: Data("\(iteration)".utf8))
            _ = try? memory.retrieve(key: "b1-\(iteration % 8)")
        }
        XCTAssertEqual(memory.storedKeys.count, 8)
    }

    // MARK: - Helper

    private func b1SkippingWhenTheKeychainIsUnavailable(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            if KeychainSessionStorage.isMissingEntitlement(error) {
                throw XCTSkip(
                    "the keychain refused a host-less test bundle (errSecMissingEntitlement, -34018)")
            }
            throw error
        }
    }
}
