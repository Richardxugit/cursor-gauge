import XCTest
import SQLite3
@testable import CursorGaugeCore

final class TokenStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursorgauge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    /// Builds a stand-in for Cursor's `state.vscdb` with the same `ItemTable` shape.
    private func makeDatabase(token: String?) throws -> URL {
        let url = directory.appendingPathComponent("state.vscdb")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close_v2(handle) }

        XCTAssertEqual(
            sqlite3_exec(handle, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)", nil, nil, nil),
            SQLITE_OK
        )
        // A decoy row proves the query filters by key rather than taking the first row.
        XCTAssertEqual(
            sqlite3_exec(handle, "INSERT INTO ItemTable VALUES ('cursorAuth/cachedEmail', 'someone@example.com')", nil, nil, nil),
            SQLITE_OK
        )
        if let token {
            let sql = "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(token)')"
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        }
        return url
    }

    private func makeJWT(sub: String, expiresAt: Date) -> String {
        let payload = ["sub": sub, "exp": expiresAt.timeIntervalSince1970] as [String: Any]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")   // base64url drops padding
        return "header.\(encoded).signature"
    }

    private func store(at url: URL, now: Date = Date(timeIntervalSince1970: 1_785_658_392)) -> TokenStore {
        TokenStore(databaseURL: url, clock: { now })
    }

    // MARK: - Failure states

    func testMissingDatabaseReportsCursorNotInstalled() {
        let store = store(at: directory.appendingPathComponent("absent.vscdb"))
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? TokenError, .cursorNotInstalled)
        }
    }

    func testDatabaseWithoutTokenRowReportsNotSignedIn() throws {
        let url = try makeDatabase(token: nil)
        XCTAssertThrowsError(try store(at: url).load()) { error in
            XCTAssertEqual(error as? TokenError, .notSignedIn)
        }
    }

    func testExpiredTokenReportsExpired() throws {
        let now = Date(timeIntervalSince1970: 1_785_658_392)
        let expiry = now.addingTimeInterval(-60)
        let url = try makeDatabase(token: makeJWT(sub: "auth0|user_ABC", expiresAt: expiry))
        XCTAssertThrowsError(try store(at: url, now: now).load()) { error in
            guard case .expired(let reported)? = error as? TokenError else {
                return XCTFail("expected .expired, got \(error)")
            }
            XCTAssertEqual(reported.timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 1)
        }
    }

    func testNonJWTTokenReportsMalformed() throws {
        let url = try makeDatabase(token: "not-a-jwt")
        XCTAssertThrowsError(try store(at: url).load()) { error in
            XCTAssertEqual(error as? TokenError, .malformedToken)
        }
    }

    func testJWTWithoutRequiredClaimsReportsMalformed() throws {
        let data = try JSONSerialization.data(withJSONObject: ["nothing": "useful"])
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let url = try makeDatabase(token: "header.\(encoded).signature")
        XCTAssertThrowsError(try store(at: url).load()) { error in
            XCTAssertEqual(error as? TokenError, .malformedToken)
        }
    }

    // MARK: - Success

    func testReadsTokenAndStripsAuth0Prefix() throws {
        let now = Date(timeIntervalSince1970: 1_785_658_392)
        let expiry = Date(timeIntervalSince1970: 1_790_839_766)
        let token = makeJWT(sub: "auth0|user_01KBK90YXNWFCE45NE9M89HCYT", expiresAt: expiry)
        let url = try makeDatabase(token: token)

        let credentials = try store(at: url, now: now).load()

        XCTAssertEqual(credentials.accessToken, token)
        XCTAssertEqual(credentials.userSub, "user_01KBK90YXNWFCE45NE9M89HCYT")
        XCTAssertEqual(credentials.expiresAt.timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 1)
    }

    func testSubWithoutPrefixIsUsedVerbatim() throws {
        let url = try makeDatabase(
            token: makeJWT(sub: "user_PLAIN", expiresAt: Date(timeIntervalSince1970: 1_790_839_766))
        )
        XCTAssertEqual(try store(at: url).load().userSub, "user_PLAIN")
    }

    func testCookieHeaderUsesEncodedDoubleColon() {
        let credentials = CursorCredentials(
            accessToken: "TOKEN",
            userSub: "user_ABC",
            expiresAt: Date(timeIntervalSince1970: 1_790_839_766)
        )
        XCTAssertEqual(credentials.cookieHeader, "WorkosCursorSessionToken=user_ABC%3A%3ATOKEN")
    }

    // MARK: - Caching

    func testSecondLoadIsServedFromCache() throws {
        let url = try makeDatabase(
            token: makeJWT(sub: "auth0|user_ABC", expiresAt: Date(timeIntervalSince1970: 1_790_839_766))
        )
        let store = store(at: url)
        let first = try store.load()

        // Deleting the database proves the second read never touched disk.
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(try store.load(), first)
    }

    func testInvalidateForcesDiskRead() throws {
        let url = try makeDatabase(
            token: makeJWT(sub: "auth0|user_ABC", expiresAt: Date(timeIntervalSince1970: 1_790_839_766))
        )
        let store = store(at: url)
        _ = try store.load()

        try FileManager.default.removeItem(at: url)
        store.invalidate()

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? TokenError, .cursorNotInstalled)
        }
    }

    func testTokenNearingExpiryIsNotServedFromCache() throws {
        let now = Date(timeIntervalSince1970: 1_785_658_392)
        // Twelve hours out — inside the one-day window that forces a re-read.
        let url = try makeDatabase(
            token: makeJWT(sub: "auth0|user_ABC", expiresAt: now.addingTimeInterval(43_200))
        )
        let store = store(at: url, now: now)
        _ = try store.load()

        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? TokenError, .cursorNotInstalled)
        }
    }
}
