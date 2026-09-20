import Foundation

/// Date handling for the contract.
///
/// Both a fixture file and PostgREST emit ISO-8601 with an offset, but not the
/// same spelling of it: the fixtures carry `+10:00` and Supabase usually
/// returns `+00:00` with fractional seconds. Both have to parse, and a value
/// that parses must round-trip.
public enum ContractDate {
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let encoder: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "Australia/Sydney") ?? .gmt
        return f
    }()

    public static func date(from string: String) -> Date? {
        withFractional.date(from: string) ?? plain.date(from: string)
    }

    public static func string(from date: Date) -> String {
        encoder.string(from: date)
    }

    static func decode<K: CodingKey>(
        from container: KeyedDecodingContainer<K>, forKey key: K
    ) throws -> Date {
        let raw = try container.decode(String.self, forKey: key)
        guard let parsed = date(from: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container,
                debugDescription: "\(raw) is not ISO-8601 with an offset")
        }
        return parsed
    }

    static func decodeIfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>, forKey key: K
    ) throws -> Date? {
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let parsed = date(from: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container,
                debugDescription: "\(raw) is not ISO-8601 with an offset")
        }
        return parsed
    }
}

extension KeyedDecodingContainer {
    /// Read a number that may arrive as a JSON number or, from some Postgres
    /// clients, as a numeric string. A price that arrives as "55.00" is worth
    /// reading, not worth crashing over.
    func decodeNumber(forKey key: Key) throws -> Double {
        if let d = try? decode(Double.self, forKey: key), d.isFinite { return d }
        if let s = try? decode(String.self, forKey: key), let d = Double(s), d.isFinite { return d }
        throw DecodingError.dataCorruptedError(
            forKey: key, in: self, debugDescription: "expected a finite number")
    }

    func decodeNumberIfPresent(forKey key: Key) throws -> Double? {
        if try decodeNil(forKey: key) { return nil }
        if let d = try? decode(Double.self, forKey: key) {
            guard d.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: self, debugDescription: "expected a finite number, got \(d)")
            }
            return d
        }
        if let s = try? decode(String.self, forKey: key) {
            // A numeric-looking string that fails to parse at all (garbage,
            // not a number) still reads as "no price" — the pre-existing,
            // deliberate behaviour. But `Double("NaN")`, `Double("Infinity")`
            // and an overflowing literal like `Double("1e400")` all SUCCEED
            // in Swift while being non-finite. Those are not a real price
            // either, so they must fail the decode rather than pass through.
            guard let d = Double(s) else { return nil }
            guard d.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: self, debugDescription: "expected a finite number, got \"\(s)\"")
            }
            return d
        }
        return nil
    }

    /// Decode an array element by element, dropping the ones that fail rather
    /// than losing the whole payload to a single bad row. One club changing its
    /// HTML must not blank out the other fourteen.
    func decodeLenient<T: Decodable>(
        _ type: [T].Type, forKey key: Key, into issues: inout [DecodingIssue]
    ) throws -> [T] {
        guard contains(key), try !decodeNil(forKey: key) else { return [] }
        // The container itself can be the wrong JSON type (an object where an
        // array was expected, say). That is still just this one collection
        // being bad — not a reason to fail every other collection in the
        // payload, the same principle applied below to a single element.
        var unkeyed: UnkeyedDecodingContainer
        do {
            unkeyed = try nestedUnkeyedContainer(forKey: key)
        } catch {
            issues.append(DecodingIssue(
                collection: key.stringValue,
                index: -1,
                reason: String(describing: error)))
            return []
        }
        var result: [T] = []
        if let count = unkeyed.count { result.reserveCapacity(count) }
        var index = 0
        while !unkeyed.isAtEnd {
            do {
                result.append(try unkeyed.decode(T.self))
            } catch {
                // Consume the element so the loop can advance past it.
                _ = try? unkeyed.decode(AnyDecodableSkip.self)
                issues.append(DecodingIssue(
                    collection: key.stringValue,
                    index: index,
                    reason: String(describing: error)))
            }
            index += 1
        }
        return result
    }
}

/// Swallows any JSON value. Used only to step over an element that failed to
/// decode, because an unkeyed container has no other way to advance.
private struct AnyDecodableSkip: Decodable {
    init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer(), c.decodeNil() { return }
        _ = try? decoder.container(keyedBy: SkipKey.self)
    }
    private struct SkipKey: CodingKey {
        var stringValue: String; var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
        init?(intValue: Int) { self.intValue = intValue; stringValue = String(intValue) }
    }
}

// MARK: - Loading

public enum ContractLoader {
    public enum Failure: Error, CustomStringConvertible {
        case fixtureMissing(String)
        case undecodable(String)
        case versionMismatch(expected: String, found: String)

        public var description: String {
            switch self {
            case .fixtureMissing(let name): return "fixture \(name) is not in the bundle"
            case .undecodable(let why): return "payload could not be decoded: \(why)"
            case .versionMismatch(let expected, let found):
                return "payload is contract \(found) but this build expects \(expected)"
            }
        }
    }

    public static func decode(_ data: Data) throws -> ContractPayload {
        let payload: ContractPayload
        do {
            payload = try JSONDecoder().decode(ContractPayload.self, from: data)
        } catch {
            throw Failure.undecodable(String(describing: error))
        }
        guard payload.contractVersion == Contract.version else {
            throw Failure.versionMismatch(expected: Contract.version, found: payload.contractVersion)
        }
        return payload
    }

    /// Load a fixture bundled with the contract framework.
    /// `minimal` is deterministic and small — assert against it.
    /// `golden` is a real 15-course scrape — build and scroll against it.
    public static func fixture(_ name: String, bundle: Bundle = .contract) throws -> ContractPayload {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw Failure.fixtureMissing(name)
        }
        return try decode(try Data(contentsOf: url))
    }
}

extension Bundle {
    /// The framework bundle, whichever target is asking.
    public static let contract = Bundle(for: ContractBundleToken.self)
}

final class ContractBundleToken {}
