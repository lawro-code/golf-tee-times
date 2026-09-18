import Foundation
import Security
import Supabase

/// Where the Supabase session lives between launches.
///
/// `kSecAttrAccessibleAfterFirstUnlock` rather than `WhenUnlocked` because a
/// background refresh has to read the session while the phone is still locked —
/// which is the whole point of alerts arriving before you pick the phone up.
/// It is still not readable before the first unlock after a reboot, and it is
/// not `ThisDeviceOnly`, so it restores with an encrypted backup.
///
/// No access group: nothing else shares this keychain item.
public final class KeychainSessionStorage: AuthLocalStorage {
    /// The keychain service every session item is filed under.
    public static let defaultService = "code.lawro.TeesForTheBoys.session"

    /// `errSecMissingEntitlement`. A host-less unit-test bundle on the simulator
    /// has no keychain access group, and every keychain call returns this.
    /// Tests skip on it rather than fail; it says nothing about the code.
    public static let missingEntitlementStatus: OSStatus = -34018

    private let service: String

    public init(service: String = KeychainSessionStorage.defaultService) {
        self.service = service
    }

    public func store(key: String, value: Data) throws {
        var query = query(for: key)
        let attributes: [String: Any] = [kSecValueData as String: value]

        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Self.failure("store", updated) }

        query[kSecValueData as String] = value
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(query as CFDictionary, nil)
        guard added == errSecSuccess else { throw Self.failure("store", added) }
    }

    public func retrieve(key: String) throws -> Data? {
        var query = query(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            // Not an error: nobody has signed in on this device yet.
            return nil
        default:
            throw Self.failure("retrieve", status)
        }
    }

    public func remove(key: String) throws {
        let status = SecItemDelete(query(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.failure("remove", status)
        }
    }

    private func query(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    /// Every `OSStatus` becomes a `DataError`, with the raw status kept in the
    /// message — it is the only thing that tells `-34018` (no entitlement, skip
    /// the test) apart from `-25300` (nothing stored, which we never surface).
    private static func failure(_ operation: String, _ status: OSStatus) -> DataError {
        .cacheUnavailable("keychain \(operation) failed (OSStatus \(status))")
    }

    /// True when `error` is the keychain refusing a host-less test bundle.
    public static func isMissingEntitlement(_ error: Error) -> Bool {
        guard case .cacheUnavailable(let message)? = error as? DataError else { return false }
        return message.contains("OSStatus \(missingEntitlementStatus)")
    }
}

/// The same storage, in memory.
///
/// Three callers need it: unit tests (which must not touch the keychain),
/// previews, and the simulator when a host-less test bundle has no keychain
/// access at all. A session stored here dies with the process, which is
/// precisely what a test wants.
public final class InMemorySessionStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func store(key: String, value: Data) throws {
        lock.withLock { items[key] = value }
    }

    public func retrieve(key: String) throws -> Data? {
        lock.withLock { items[key] }
    }

    public func remove(key: String) throws {
        lock.withLock { items[key] = nil }
    }

    /// Everything currently held. Tests assert on this to prove sign-out really
    /// cleared the session rather than only forgetting it in memory.
    public var storedKeys: [String] {
        lock.withLock { Array(items.keys) }
    }
}
