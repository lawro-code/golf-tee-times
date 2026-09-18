import Foundation

/// Where the Supabase URL and anon key come from.
///
/// **Nothing in this repo contains a key, a URL or a project ref, and nothing
/// in Stage 1 contacts a hosted project.** `ios/project.yml` is frozen, so this
/// cannot lean on a build setting or an Info.plist key that does not exist yet.
/// Three sources are tried in order:
///
/// 1. `SupabaseConfiguration.configure(url:anonKey:)` — what the host app calls
///    once at launch. Wins over everything, and is how Stage 2 will wire it.
/// 2. The environment: `TEES_SUPABASE_URL` and `TEES_SUPABASE_ANON_KEY`. This is
///    what a scheme's run arguments set, and what CI would use.
/// 3. `Bundle.main` keys `TeesSupabaseURL` and `TeesSupabaseAnonKey`, for if the
///    app target later adds them to its Info.plist.
///
/// None of them hit? `DataError.notConfigured`. A build that cannot say where
/// the server is should say so loudly at the first call, not pretend.
public struct SupabaseConfiguration: Sendable, Equatable {
    public let url: URL
    public let anonKey: String

    public init(url: URL, anonKey: String) {
        self.url = url
        self.anonKey = anonKey
    }

    // MARK: - Names, in one place

    public static let environmentURLKey = "TEES_SUPABASE_URL"
    public static let environmentAnonKeyKey = "TEES_SUPABASE_ANON_KEY"
    public static let infoPlistURLKey = "TeesSupabaseURL"
    public static let infoPlistAnonKeyKey = "TeesSupabaseAnonKey"

    // MARK: - Explicit configuration

    /// Set the configuration from the host app. Safe to call from any thread;
    /// meant to be called once, before the first `SupabaseClientProvider.client()`.
    public static func configure(url: URL, anonKey: String) {
        explicitConfiguration.set(SupabaseConfiguration(url: url, anonKey: anonKey))
    }

    /// The same, from strings — what you have when the values arrive from a
    /// launch argument or a plist.
    ///
    /// - Throws: `DataError.notConfigured` if either value is unusable. Failing
    ///   here beats a `SupabaseClient` built on a URL with no host, which the
    ///   SDK turns into a `preconditionFailure` — a crash, not an error.
    public static func configure(urlString: String, anonKey: String) throws {
        configure(try validated(urlString: urlString, anonKey: anonKey, source: "configure(urlString:anonKey:)"))
    }

    public static func configure(_ configuration: SupabaseConfiguration) {
        explicitConfiguration.set(configuration)
    }

    /// Forget an explicit configuration. Tests only — the app configures once.
    static func resetExplicitConfiguration() {
        explicitConfiguration.set(nil)
    }

    // MARK: - Resolution

    /// The configuration to build a client from.
    ///
    /// - Throws: `DataError.notConfigured` when no source supplied one.
    public static func resolve() throws -> SupabaseConfiguration {
        try resolve(environment: ProcessInfo.processInfo.environment, bundle: .main)
    }

    /// The injectable half, so the precedence rules can be tested without
    /// mutating the process environment or shipping a test Info.plist.
    static func resolve(environment: [String: String], bundle: Bundle) throws -> SupabaseConfiguration {
        if let explicit = explicitConfiguration.value {
            return explicit
        }
        if let url = environment[environmentURLKey]?.trimmed, !url.isEmpty,
           let key = environment[environmentAnonKeyKey]?.trimmed, !key.isEmpty {
            return try validated(urlString: url, anonKey: key, source: "the environment")
        }
        if let url = (bundle.object(forInfoDictionaryKey: infoPlistURLKey) as? String)?.trimmed, !url.isEmpty,
           let key = (bundle.object(forInfoDictionaryKey: infoPlistAnonKeyKey) as? String)?.trimmed, !key.isEmpty {
            return try validated(urlString: url, anonKey: key, source: "Info.plist")
        }
        throw DataError.notConfigured(
            """
            no Supabase URL or anon key. Call SupabaseConfiguration.configure(url:anonKey:) \
            at launch, or set \(environmentURLKey) and \(environmentAnonKeyKey).
            """
        )
    }

    // MARK: - Validation

    /// - Note: the message never contains the key. A `notConfigured` string can
    ///   end up in a log or a crash report.
    private static func validated(urlString: String, anonKey: String, source: String) throws -> SupabaseConfiguration {
        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else {
            throw DataError.notConfigured("\(source) gave a Supabase URL that is not a URL")
        }
        guard !anonKey.trimmed.isEmpty else {
            throw DataError.notConfigured("\(source) gave an empty Supabase anon key")
        }
        return SupabaseConfiguration(url: url, anonKey: anonKey)
    }
}

/// Thread-safe because `configure` may land on any thread and `resolve` is read
/// from whichever one first asks for a client.
private final class ExplicitConfigurationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SupabaseConfiguration?

    var value: SupabaseConfiguration? {
        lock.withLock { stored }
    }

    func set(_ configuration: SupabaseConfiguration?) {
        lock.withLock { stored = configuration }
    }
}

private let explicitConfiguration = ExplicitConfigurationBox()

extension String {
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
