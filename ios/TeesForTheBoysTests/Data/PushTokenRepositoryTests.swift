import XCTest
@testable import TeesData
import TeesContract
import Supabase

/// The `push_tokens` row, and the composite key that makes a shared iPhone
/// work.
final class PushTokenRepositoryTests: XCTestCase {

    private let token = "b4f0000000000000000000000000000000000000000000000000000000000001"

    override func setUp() {
        super.setUp()
        B4StubURLProtocol.respond(json: "[]")
    }

    override func tearDown() {
        B4StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeRepository(session: B4StubSession = .signedIn) -> PushTokenRepository {
        PushTokenRepository(
            client: B4Client.make(), session: session, now: { B4Fixtures.now })
    }

    // MARK: - The wall

    func testEveryMethodThrowsNotSignedInWithoutASession() async throws {
        let repository = makeRepository(session: .signedOut)

        await assertNotSignedIn {
            _ = try await repository.register(token: self.token, environment: .sandbox)
        }
        await assertNotSignedIn { try await repository.remove(token: self.token) }
        await assertNotSignedIn { _ = try await repository.registeredTokens() }

        XCTAssertTrue(B4StubURLProtocol.sent.isEmpty)
    }

    // MARK: - Registering

    /// The whole point of the ticket's fourth file. On the token alone, the
    /// second mate to sign in on a shared iPhone cannot register at all: the
    /// row belongs to the first, RLS hides it, and the upsert fails on a key
    /// they are not allowed to see.
    func testRegisterUpsertsOnTheCompositeKeyAndNotOnTheTokenAlone() async throws {
        B4StubURLProtocol.respond(status: 201, json: B4Fixtures.pushTokenRow)

        _ = try await makeRepository().register(token: token, environment: .sandbox)

        let sent = try XCTUnwrap(B4StubURLProtocol.sent(to: "push_tokens").first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.query("on_conflict"), "user_id,token")
        XCTAssertNotEqual(sent.query("on_conflict"), "token")
        XCTAssertEqual(sent.header("Prefer")?.contains("resolution=merge-duplicates"), true)
    }

    func testRegisterStoresPlatformAndEnvironment() async throws {
        B4StubURLProtocol.respond(
            status: 201,
            json: B4Fixtures.pushTokenRow.replacingOccurrences(
                of: "\"sandbox\"", with: "\"production\""))

        let stored = try await makeRepository().register(token: token, environment: .production)

        let body = try XCTUnwrap(B4StubURLProtocol.sent(to: "push_tokens").first?.json)
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["environment"] as? String, "production")
        XCTAssertEqual(
            (body["user_id"] as? String)?.lowercased(),
            B4Fixtures.userID.uuidString.lowercased())
        XCTAssertEqual(stored.environment, .production)
    }

    /// Registering on every launch has to be free. The same token upserts onto
    /// the same row and only moves `updated_at`.
    func testRegisteringTwiceIsTwoUpsertsAndNotAnError() async throws {
        B4StubURLProtocol.respond(status: 201, json: B4Fixtures.pushTokenRow)
        let repository = makeRepository()

        _ = try await repository.register(token: token, environment: .sandbox)
        _ = try await repository.register(token: token, environment: .sandbox)

        let sends = B4StubURLProtocol.sent(to: "push_tokens")
        XCTAssertEqual(sends.count, 2)
        XCTAssertTrue(sends.allSatisfy { $0.query("on_conflict") == "user_id,token" })
    }

    func testAnEmptyTokenIsRefusedWithoutNamingAValue() async throws {
        do {
            _ = try await makeRepository().register(token: "   ", environment: .sandbox)
            XCTFail("expected invalidInput")
        } catch let error as DataError {
            guard case .invalidInput(let field, let reason) = error else {
                return XCTFail("expected invalidInput, got \(error)")
            }
            XCTAssertEqual(field, "token")
            XCTAssertFalse(
                reason.contains(token), "a device token never appears in a message or a log")
        }
        XCTAssertTrue(B4StubURLProtocol.sent.isEmpty)
    }

    /// A token with whitespace through the middle of it is not a token — it is
    /// something that was mangled on the way here. It never reaches the table,
    /// and the refusal still does not quote it.
    func testAMangledTokenIsRefusedBeforeTheNetwork() async throws {
        do {
            _ = try await makeRepository().register(
                token: "b4f00000 00000001", environment: .sandbox)
            XCTFail("expected invalidInput")
        } catch let error as DataError {
            guard case .invalidInput(let field, let reason) = error else {
                return XCTFail("expected invalidInput, got \(error.diagnostic)")
            }
            XCTAssertEqual(field, "token")
            XCTAssertFalse(reason.contains("b4f00000"), "never quote a device token")
        }
        XCTAssertTrue(B4StubURLProtocol.sent.isEmpty)
    }

    /// A newline around a token is not a reason to refuse it: it is still this
    /// device's token, and refusing means no alerts at all.
    func testSurroundingWhitespaceIsTrimmedRatherThanRefused() async throws {
        B4StubURLProtocol.respond(status: 201, json: B4Fixtures.pushTokenRow)

        _ = try await makeRepository().register(token: "\n  \(token)\t", environment: .sandbox)

        let body = try XCTUnwrap(B4StubURLProtocol.sent(to: "push_tokens").first?.json)
        XCTAssertEqual(body["token"] as? String, token)
    }

    /// Two mates, one iPhone. Each registration carries its own owner and
    /// conflicts only on the pair, so the second to sign in writes their own row
    /// instead of colliding with one RLS will not even show them.
    func testASharedPhoneRegistersOneRowPerUserOnTheSameToken() async throws {
        B4StubURLProtocol.respond(status: 201, json: B4Fixtures.pushTokenRow)

        _ = try await makeRepository().register(token: token, environment: .sandbox)
        _ = try await makeRepository(session: .mate).register(token: token, environment: .sandbox)

        let sends = B4StubURLProtocol.sent(to: "push_tokens")
        XCTAssertEqual(sends.count, 2)

        let owners = try sends.map {
            try XCTUnwrap(($0.json?["user_id"] as? String)?.lowercased())
        }
        XCTAssertEqual(
            owners,
            [
                B4Fixtures.userID.uuidString.lowercased(),
                B4StubSession.mate.userID!.uuidString.lowercased(),
            ])
        XCTAssertTrue(sends.allSatisfy { $0.json?["token"] as? String == self.token })
        XCTAssertTrue(sends.allSatisfy { $0.query("on_conflict") == "user_id,token" })
    }

    // MARK: - Removing

    /// Sign-out has the same guard as registration: a device that never handed
    /// over a token must not send a DELETE that matches every row it can see.
    func testABlankTokenIsRefusedOnRemovalToo() async throws {
        do {
            try await makeRepository().remove(token: "  \n ")
            XCTFail("expected invalidInput")
        } catch let error as DataError {
            guard case .invalidInput(let field, _) = error else {
                return XCTFail("expected invalidInput, got \(error.diagnostic)")
            }
            XCTAssertEqual(field, "token")
        }
        XCTAssertTrue(B4StubURLProtocol.sent.isEmpty)
    }

    /// Signing out on a shared phone removes your row and leaves your mate's.
    func testRemoveIsScopedToBothHalvesOfTheKey() async throws {
        B4StubURLProtocol.respond(json: "[]")

        try await makeRepository().remove(token: token)

        let sent = try XCTUnwrap(B4StubURLProtocol.sent(to: "push_tokens").first)
        XCTAssertEqual(sent.method, "DELETE")
        XCTAssertEqual(sent.query("user_id"), "eq.\(B4Fixtures.userID.uuidString)")
        XCTAssertEqual(sent.query("token"), "eq.\(token)")
    }

    func testRegisteredTokensReadsOnlyThisUsersRows() async throws {
        B4StubURLProtocol.respond(json: "[\(B4Fixtures.pushTokenRow)]")

        let tokens = try await makeRepository().registeredTokens()
        XCTAssertEqual(tokens.count, 1)

        let sent = try XCTUnwrap(B4StubURLProtocol.sent(to: "push_tokens").first)
        XCTAssertEqual(sent.method, "GET")
        XCTAssertEqual(sent.query("user_id"), "eq.\(B4Fixtures.userID.uuidString)")
    }

    // MARK: - Helper

    private func assertNotSignedIn(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected DataError.notSignedIn", file: file, line: line)
        } catch let error as DataError {
            XCTAssertEqual(error, .notSignedIn, file: file, line: line)
        } catch {
            XCTFail("expected DataError.notSignedIn, got \(error)", file: file, line: line)
        }
    }
}
