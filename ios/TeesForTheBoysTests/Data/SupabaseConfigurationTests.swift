import Supabase
import XCTest
@testable import TeesData

/// Config resolution, which is the one thing standing between a build and a
/// `preconditionFailure` inside the Supabase SDK.
///
/// No key, URL or project ref appears in this file or anywhere else in the
/// repo, and nothing here contacts a hosted project.
final class SupabaseConfigurationTests: XCTestCase {

    private let url = URL(string: "https://stub.supabase.co")!

    override func setUp() {
        super.setUp()
        SupabaseConfiguration.resetExplicitConfiguration()
    }

    override func tearDown() {
        SupabaseConfiguration.resetExplicitConfiguration()
        super.tearDown()
    }

    // MARK: - Precedence

    func testAnExplicitConfigurationBeatsTheEnvironment() throws {
        SupabaseConfiguration.configure(url: url, anonKey: "explicit-key")
        let resolved = try SupabaseConfiguration.resolve(
            environment: [
                SupabaseConfiguration.environmentURLKey: "https://environment.supabase.co",
                SupabaseConfiguration.environmentAnonKeyKey: "environment-key",
            ],
            bundle: .b1Test)
        XCTAssertEqual(resolved.url, url)
        XCTAssertEqual(resolved.anonKey, "explicit-key")
    }

    func testTheEnvironmentIsUsedWhenTheHostAppHasNotConfigured() throws {
        let resolved = try SupabaseConfiguration.resolve(
            environment: [
                SupabaseConfiguration.environmentURLKey: "https://environment.supabase.co",
                SupabaseConfiguration.environmentAnonKeyKey: "environment-key",
            ],
            bundle: .b1Test)
        XCTAssertEqual(resolved.url.host, "environment.supabase.co")
        XCTAssertEqual(resolved.anonKey, "environment-key")
    }

    func testHalfTheEnvironmentIsNotEnough() {
        XCTAssertThrowsError(
            try SupabaseConfiguration.resolve(
                environment: [SupabaseConfiguration.environmentURLKey: "https://stub.supabase.co"],
                bundle: .b1Test)
        ) { error in
            guard case .notConfigured = error as? DataError else {
                return XCTFail("expected .notConfigured, got \(error)")
            }
        }
    }

    func testNoSourceAtAllIsNotConfiguredAndSaysWhatToSet() {
        XCTAssertThrowsError(
            try SupabaseConfiguration.resolve(environment: [:], bundle: .b1Test)
        ) { error in
            guard case .notConfigured(let why)? = error as? DataError else {
                return XCTFail("expected .notConfigured, got \(error)")
            }
            XCTAssertTrue(why.contains(SupabaseConfiguration.environmentURLKey), why)
            XCTAssertFalse(
                (error as? DataError)?.isRetryable ?? true,
                "a missing key is not going to appear on a retry")
        }
    }

    func testTheInfoPlistIsTheLastResort() throws {
        let bundle = try b1BundleWithInfoKeys([
            SupabaseConfiguration.infoPlistURLKey: "https://plist.supabase.co",
            SupabaseConfiguration.infoPlistAnonKeyKey: "plist-key",
        ])
        let resolved = try SupabaseConfiguration.resolve(environment: [:], bundle: bundle)
        XCTAssertEqual(resolved.url.host, "plist.supabase.co")
        XCTAssertEqual(resolved.anonKey, "plist-key")
    }

    func testTheEnvironmentBeatsTheInfoPlist() throws {
        // A scheme's run arguments are how a developer points a build at a
        // branch database. A plist baked into the app must not win over it.
        let bundle = try b1BundleWithInfoKeys([
            SupabaseConfiguration.infoPlistURLKey: "https://plist.supabase.co",
            SupabaseConfiguration.infoPlistAnonKeyKey: "plist-key",
        ])
        let resolved = try SupabaseConfiguration.resolve(
            environment: [
                SupabaseConfiguration.environmentURLKey: "https://environment.supabase.co",
                SupabaseConfiguration.environmentAnonKeyKey: "environment-key",
            ],
            bundle: bundle)
        XCTAssertEqual(resolved.url.host, "environment.supabase.co")
        XCTAssertEqual(resolved.anonKey, "environment-key")
    }

    func testAnEmptyEnvironmentVariableFallsThroughInsteadOfShadowingThePlist() throws {
        // Xcode writes a declared-but-unset scheme variable as an empty string.
        // Treating that as "configured" would break a build that is configured
        // perfectly well from its Info.plist.
        let bundle = try b1BundleWithInfoKeys([
            SupabaseConfiguration.infoPlistURLKey: "https://plist.supabase.co",
            SupabaseConfiguration.infoPlistAnonKeyKey: "plist-key",
        ])
        let resolved = try SupabaseConfiguration.resolve(
            environment: [
                SupabaseConfiguration.environmentURLKey: "   ",
                SupabaseConfiguration.environmentAnonKeyKey: "",
            ],
            bundle: bundle)
        XCTAssertEqual(resolved.url.host, "plist.supabase.co")
        XCTAssertEqual(resolved.anonKey, "plist-key")
    }

    func testAPaddedEnvironmentValueIsTrimmedRatherThanRefused() throws {
        // Copy a URL out of the Supabase dashboard into a scheme and it arrives
        // with a trailing space. Untrimmed, `URL(string:)` returns nil and a
        // correctly configured build reports itself as not configured.
        let resolved = try SupabaseConfiguration.resolve(
            environment: [
                SupabaseConfiguration.environmentURLKey: "  https://environment.supabase.co  ",
                SupabaseConfiguration.environmentAnonKeyKey: " environment-key\n",
            ],
            bundle: .b1Test)
        XCTAssertEqual(resolved.url.host, "environment.supabase.co")
        XCTAssertEqual(
            resolved.anonKey, "environment-key",
            "a key with a newline on the end goes out in an Authorization header")
    }

    func testConfiguringFromStringsIsWhatResolveThenReturns() throws {
        try SupabaseConfiguration.configure(
            urlString: "https://launch.supabase.co", anonKey: "launch-key")
        let resolved = try SupabaseConfiguration.resolve(environment: [:], bundle: .b1Test)
        XCTAssertEqual(resolved.url.host, "launch.supabase.co")
        XCTAssertEqual(resolved.anonKey, "launch-key")
    }

    // MARK: - Rejecting what would crash the SDK

    func testAURLWithoutAHostIsRefusedRatherThanCrashingTheSDK() {
        // SupabaseClient calls preconditionFailure on a URL with no host — a
        // crash, not an error. It has to be caught here.
        XCTAssertThrowsError(
            try SupabaseConfiguration.resolve(
                environment: [
                    SupabaseConfiguration.environmentURLKey: "not a url",
                    SupabaseConfiguration.environmentAnonKeyKey: "environment-key",
                ],
                bundle: .b1Test)
        ) { error in
            guard case .notConfigured = error as? DataError else {
                return XCTFail("expected .notConfigured, got \(error)")
            }
        }
    }

    func testAnEmptyKeyIsRefused() {
        XCTAssertThrowsError(try SupabaseConfiguration.configure(urlString: "https://stub.supabase.co", anonKey: "   ")) { error in
            guard case .notConfigured = error as? DataError else {
                return XCTFail("expected .notConfigured, got \(error)")
            }
        }
    }

    func testAnUnusableValueNeverPutsTheKeyInTheMessage() {
        XCTAssertThrowsError(
            try SupabaseConfiguration.configure(urlString: "nonsense", anonKey: "super-secret-key")
        ) { error in
            guard case .notConfigured(let why)? = error as? DataError else {
                return XCTFail("expected .notConfigured, got \(error)")
            }
            XCTAssertFalse(
                why.contains("super-secret-key"),
                "a notConfigured message can end up in a crash report: \(why)")
        }
    }

    // MARK: - The one shared client

    func testTheSharedClientIsBuiltOnceSoTwoOfThemCannotFightOverTheSession() throws {
        // Two clients own two refresh timers and the same keychain entry, and
        // overwrite each other's tokens. There has to be exactly one.
        SupabaseClientProvider.resetShared()
        addTeardownBlock {
            SupabaseClientProvider.resetShared()
            SupabaseConfiguration.resetExplicitConfiguration()
        }
        SupabaseConfiguration.configure(url: url, anonKey: "b1-shared-key")

        let first = try SupabaseClientProvider.client()
        let second = try SupabaseClientProvider.client()
        XCTAssertTrue(first === second, "the second call rebuilt the client")

        SupabaseClientProvider.resetShared()
        let third = try SupabaseClientProvider.client()
        XCTAssertFalse(third === first, "resetShared has to actually drop it")
    }

    func testAskingForAClientBeforeAnybodyConfiguredOneSaysSo() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment[SupabaseConfiguration.environmentURLKey] != nil,
            "this machine has \(SupabaseConfiguration.environmentURLKey) set, so nothing is unconfigured")
        SupabaseClientProvider.resetShared()
        SupabaseConfiguration.resetExplicitConfiguration()
        addTeardownBlock { SupabaseClientProvider.resetShared() }

        XCTAssertThrowsError(try SupabaseClientProvider.client()) { error in
            guard case .notConfigured = error as? DataError else {
                return XCTFail("expected .notConfigured, got \(error)")
            }
        }
    }

    // MARK: - Threading

    func testConfigureAndResolveAreSafeFromManyThreads() {
        // configure() lands on whichever thread launched the app; resolve() on
        // whichever one first asks for a client. Under TSan this is the test
        // that would catch it.
        DispatchQueue.concurrentPerform(iterations: 64) { iteration in
            if iteration.isMultiple(of: 2) {
                SupabaseConfiguration.configure(url: url, anonKey: "key-\(iteration)")
            } else {
                _ = try? SupabaseConfiguration.resolve(environment: [:], bundle: .b1Test)
            }
        }
        let resolved = try? SupabaseConfiguration.resolve(environment: [:], bundle: .b1Test)
        XCTAssertEqual(resolved?.url, url)
        XCTAssertTrue(resolved?.anonKey.hasPrefix("key-") ?? false)
    }

    // MARK: - Helpers

    /// A real loadable bundle carrying nothing but the two Info.plist keys.
    private func b1BundleWithInfoKeys(_ keys: [String: String]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("B1Config-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        var info: [String: Any] = [
            "CFBundleIdentifier": "code.lawro.TeesForTheBoys.b1-config-fixture",
            "CFBundleName": "B1Config",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundlePackageType": "BNDL",
        ]
        for (key, value) in keys { info[key] = value }

        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: root.appendingPathComponent("Info.plist"))

        guard let bundle = Bundle(url: root) else {
            throw XCTSkip("this platform would not load a synthesised bundle")
        }
        return bundle
    }
}

extension Bundle {
    /// The test bundle: a real bundle that definitely has neither key, which is
    /// what the fall-through cases need.
    fileprivate static var b1Test: Bundle { Bundle(for: SupabaseConfigurationTests.self) }
}
