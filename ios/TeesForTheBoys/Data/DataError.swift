import Foundation
import Supabase
import TeesContract

/// Every failure this track can hand a caller, as one closed set.
///
/// The point is that track C can branch on a failure instead of reading a
/// string: "offline" gets a retry button and the cached list, "not signed in"
/// gets the sign-in sheet, "decoding" gets a bug report and the cached list.
/// No `NSError` leaks out of this module — `DataError.from(_:)` is the single
/// door everything foreign comes through.
///
/// The eight cases the other tickets were promised are the first eight below.
/// `invalidInput` is the ninth: a local validation failure that never made a
/// round trip, which would be a lie dressed up as `.server(status: 400, …)`.
public enum DataError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No Supabase URL or anon key could be resolved. A programming or
    /// deployment error, never the user's fault.
    case notConfigured(String)

    /// The operation needs a signed-in user and there is none. Only ever thrown
    /// on the alerts/watches/bookings path — never on the browse path.
    case notSignedIn

    /// The device has no usable network. Retryable, and the cue to fall back to
    /// the on-disk cache rather than show an error.
    case offline

    /// The request failed below HTTP: DNS, TLS, a dropped connection.
    case transport(String)

    /// The server answered, and said no. 5xx is retryable, 4xx is not.
    case server(status: Int, message: String?)

    /// The bytes arrived and did not fit the contract. Never retried — the same
    /// bytes will fail the same way.
    case decoding(reason: String)

    /// The local cache could not be read or written. The keychain refusing a
    /// host-less test bundle lands here too.
    case cacheUnavailable(String)

    /// A payload built against a different contract version. Refusing it is the
    /// point: half-understood data is worse than none.
    case contractVersionMismatch(expected: String, found: String)

    /// Caught locally before any request went out. `field` is the thing to put
    /// the red ring around.
    case invalidInput(field: String, reason: String)

    /// Whether trying the same thing again could plausibly work.
    ///
    /// Offline and transport failures are the network's fault and pass.
    /// Anything the server decided (4xx), anything about identity, and anything
    /// about the shape of the bytes will fail identically next time.
    public var isRetryable: Bool {
        switch self {
        case .offline, .transport:
            return true
        case .server(let status, _):
            return status >= 500
        case .notConfigured, .notSignedIn, .decoding, .contractVersionMismatch,
             .cacheUnavailable, .invalidInput:
            return false
        }
    }

    /// A sentence a screen can show without embarrassment. No status codes, no
    /// type names, no stack traces.
    public var description: String {
        switch self {
        case .notConfigured:
            return "This build is not connected to a server yet."
        case .notSignedIn:
            return "Sign in to use alerts."
        case .offline:
            return "You are offline. Showing the last tee times we saved."
        case .transport:
            return "Could not reach the server. Try again in a moment."
        case .server(let status, let message):
            if let message, !message.isEmpty { return message }
            return status >= 500
                ? "The server is having a moment. Try again shortly."
                : "That request was refused."
        case .decoding:
            return "Some tee times could not be read. We have reported it."
        case .cacheUnavailable:
            return "Could not read the saved tee times on this device."
        case .contractVersionMismatch:
            return "This version of the app is out of date. Update to keep seeing tee times."
        case .invalidInput(_, let reason):
            return reason
        }
    }

    /// A line for the log, which unlike `description` keeps the detail.
    public var diagnostic: String {
        switch self {
        case .notConfigured(let why): return "notConfigured(\(why))"
        case .notSignedIn: return "notSignedIn"
        case .offline: return "offline"
        case .transport(let why): return "transport(\(why))"
        case .server(let status, let message): return "server(\(status), \(message ?? "-"))"
        case .decoding(let reason): return "decoding(\(reason))"
        case .cacheUnavailable(let why): return "cacheUnavailable(\(why))"
        case .contractVersionMismatch(let expected, let found):
            return "contractVersionMismatch(expected \(expected), found \(found))"
        case .invalidInput(let field, let reason): return "invalidInput(\(field): \(reason))"
        }
    }

    // MARK: - The one door in

    /// Map anything thrown at this module onto a `DataError`.
    ///
    /// Everything unrecognised becomes `.transport`, which is the honest
    /// reading: we do not know what happened, and trying again is reasonable.
    public static func from(_ error: Error) -> DataError {
        if let already = error as? DataError { return already }
        if let urlError = error as? URLError { return fromURL(urlError) }
        if let authError = error as? AuthError { return fromAuth(authError) }
        if let postgrest = error as? PostgrestError { return fromPostgrest(postgrest) }
        if let http = error as? HTTPError {
            // What the SDK throws when a non-2xx body is not PostgREST's JSON —
            // a gateway's HTML 502, say. Without this it would read as
            // `.transport`, which blames the user's signal for something the
            // server did.
            return .server(status: http.response.statusCode, message: bodyMessage(http.data))
        }
        if let decoding = error as? DecodingError { return .decoding(reason: describe(decoding)) }
        if let contract = error as? ContractLoader.Failure { return fromContract(contract) }
        if error is CancellationError { return .transport("cancelled") }
        return .transport(String(describing: error))
    }

    private static func fromURL(_ error: URLError) -> DataError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut:
            return .offline
        default:
            return .transport("URLError.\(error.code.rawValue)")
        }
    }

    /// Deliberately not exhaustive: `AuthError` carries deprecated cases, and
    /// naming one is a deprecation warning, which this build treats as an error.
    private static func fromAuth(_ error: AuthError) -> DataError {
        switch error {
        case .sessionMissing:
            return .notSignedIn
        case .api(let message, _, _, let response):
            return .server(status: response.statusCode, message: message)
        case .weakPassword(let message, _):
            return .invalidInput(field: "password", reason: message)
        default:
            // PKCE and JWT failures. The server will refuse the same thing
            // again, so they must not read as retryable.
            return .server(status: 400, message: error.message)
        }
    }

    /// PostgREST hands back a Postgres SQLSTATE, not an HTTP status, so the
    /// status is inferred. Only the classes that change the retry decision are
    /// picked out; everything else is a 400 the caller should not repeat.
    private static func fromPostgrest(_ error: PostgrestError) -> DataError {
        let code = error.code ?? ""
        let status: Int
        if code == "42501" || code == "PGRST301" || code == "PGRST302" {
            status = 403                       // RLS said no
        } else if code.hasPrefix("53") || code.hasPrefix("57") || code.hasPrefix("58") {
            status = 503                       // out of resources, cancelled, I/O — transient
        } else if code == "PGRST116" {
            status = 404                       // no rows where exactly one was expected
        } else {
            status = 400
        }
        return .server(status: status, message: error.message)
    }

    /// A response body is only worth showing when it reads like a sentence. A
    /// gateway's HTML error page is not a message for a golfer, so it is dropped
    /// and the generic line is used instead.
    private static func bodyMessage(_ data: Data) -> String? {
        guard
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty, text.count <= 200, !text.hasPrefix("<")
        else { return nil }
        return text
    }

    private static func fromContract(_ failure: ContractLoader.Failure) -> DataError {
        switch failure {
        case .fixtureMissing(let name):
            return .cacheUnavailable("fixture \(name) is not in the bundle")
        case .undecodable(let why):
            return .decoding(reason: why)
        case .versionMismatch(let expected, let found):
            return .contractVersionMismatch(expected: expected, found: found)
        }
    }

    /// A decoding error, said in one line with the key path intact. The default
    /// `String(describing:)` spans a dozen lines and buries the path.
    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue)
            return keys.isEmpty ? "<root>" : keys.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(path(context))"
        case .typeMismatch(let type, let context):
            return "expected \(type) at \(path(context))"
        case .valueNotFound(let type, let context):
            return "null where \(type) was required at \(path(context))"
        case .dataCorrupted(let context):
            return "corrupt value at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }
}

/// So that a screen reaching for `error.localizedDescription` — which is what
/// SwiftUI's own alert does — gets the sentence above rather than
/// "The operation couldn't be completed. (TeesData.DataError error 2.)".
extension DataError: LocalizedError {
    public var errorDescription: String? { description }
}
