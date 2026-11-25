import XCTest
import SQLite3
import CommonCrypto
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

    // MARK: - Cursor 3.x encrypted-at-rest tokens (cursor-safe-storage:v1)

    /// Encrypts exactly the way Electron safeStorage does: PBKDF2-HMAC-SHA1
    /// (`saltysalt`, 1003 rounds, 16 bytes) → AES-128-CBC with an IV of 16 spaces,
    /// a `v10` header, then the `cursor-safe-storage:v1:` base64 wrapper.
    private func encryptSafeStorage(_ plaintext: String, password: String) -> String {
        var key = [UInt8](repeating: 0, count: 16)
        let passwordBytes = Array(password.utf8)
        let salt = Array("saltysalt".utf8)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes, passwordBytes.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1003,
            &key, key.count
        )
        XCTAssertTrue(status == kCCSuccess)

        let iv = [UInt8](repeating: 0x20, count: 16)
        let input = Array(plaintext.utf8)
        var output = [UInt8](repeating: 0, count: input.count + 16)
        var outputLength = 0
        let cryptStatus = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES128),
            CCOptions(kCCOptionPKCS7Padding),
            key, key.count,
            iv,
            input, input.count,
            &output, output.count,
            &outputLength
        )
        XCTAssertTrue(cryptStatus == kCCSuccess)

        let blob = Data("v10".utf8) + Data(output.prefix(outputLength))
        return "cursor-safe-storage:v1:" + blob.base64EncodedString()
    }

    private func storeWithPassword(_ passwordProvider: @escaping () throws -> String?, at url: URL) -> TokenStore {
        TokenStore(
            databaseURL: url,
            clock: { Date(timeIntervalSince1970: 1_785_658_392) },
            keychainPassword: passwordProvider
        )
    }

    /// Generated externally with Node `crypto` (Chromium-compatible algorithm), so this
    /// test does not merely mirror the in-test encryptor.
    private static let staticStoredToken =
        "cursor-safe-storage:v1:djEwKNhbi0bmNkwfeYMpivV3Hr4onuZlNQ1lE+tVRvd6drcP5ziEICAl0qQAlsMHaftKDWq+ql57a7VhE3IB2SxrhiTBB6glxm9i9ciP6nUe1Jw="

    func testDecryptsStaticSafeStorageFixture() throws {
        let plaintext = try TokenStore.decryptSafeStorage(Self.staticStoredToken, password: "cursor-key")
        let claims = try TokenStore.decodeJWTClaims(plaintext)
        XCTAssertEqual(claims.sub, "user_fixture")
        XCTAssertEqual(claims.expiresAt.timeIntervalSince1970, 2_000_000_000, accuracy: 1)
    }

    func testLoadDecryptsEncryptedDatabaseToken() throws {
        let expiry = Date(timeIntervalSince1970: 1_790_839_766)
        let stored = encryptSafeStorage(
            makeJWT(sub: "auth0|user_ENC", expiresAt: expiry),
            password: "cursor-key"
        )
        let url = try makeDatabase(token: stored)
        let store = storeWithPassword({ "cursor-key" }, at: url)

        let credentials = try store.load()

        XCTAssertEqual(credentials.userSub, "user_ENC")
        XCTAssertEqual(credentials.expiresAt.timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(credentials.accessToken.hasPrefix("header."))
    }

    func testLoadReportsDecryptionFailedForWrongPassword() throws {
        let stored = encryptSafeStorage(makeJWT(sub: "auth0|user_X", expiresAt: Date(timeIntervalSince1970: 1_790_839_766)), password: "right-key")
        let url = try makeDatabase(token: stored)
        let store = storeWithPassword({ "wrong-key" }, at: url)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? TokenError, .decryptionFailed)
        }
    }

    func testLoadReportsKeychainUnavailableWhenPasswordMissing() throws {
        let stored = encryptSafeStorage(makeJWT(sub: "auth0|user_X", expiresAt: Date(timeIntervalSince1970: 1_790_839_766)), password: "cursor-key")
        let url = try makeDatabase(token: stored)
        let store = storeWithPassword({ nil }, at: url)

        XCTAssertThrowsError(try store.load()) { error in
            guard case .keychainUnavailable(let reason)? = error as? TokenError else {
                return XCTFail("expected .keychainUnavailable, got \(error)")
            }
            XCTAssertTrue(reason.contains("Cursor Safe Storage"))
        }
    }

    func testLoadReportsKeychainUnavailableWhenProviderThrows() throws {
        let stored = encryptSafeStorage(makeJWT(sub: "auth0|user_X", expiresAt: Date(timeIntervalSince1970: 1_790_839_766)), password: "cursor-key")
        let url = try makeDatabase(token: stored)
        let store = storeWithPassword({ throw NSError(domain: "Keychain", code: -128, userInfo: nil) }, at: url)

        XCTAssertThrowsError(try store.load()) { error in
            guard case .keychainUnavailable = error as? TokenError else {
                return XCTFail("expected .keychainUnavailable, got \(error)")
            }
        }
    }

    func testMalformedSafeStoragePayloadReportsDecryptionFailed() throws {
        let url = try makeDatabase(token: "cursor-safe-storage:v1:not-base64!!")
        let store = storeWithPassword({ "cursor-key" }, at: url)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? TokenError, .decryptionFailed)
        }
    }

    func testSafeStoragePayloadWithoutV10HeaderReportsDecryptionFailed() throws {
        let junk = Data("no-v10-header-here".utf8).base64EncodedString()
        let url = try makeDatabase(token: "cursor-safe-storage:v1:\(junk)")
        let store = storeWithPassword({ "cursor-key" }, at: url)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? TokenError, .decryptionFailed)
        }
    }
}
