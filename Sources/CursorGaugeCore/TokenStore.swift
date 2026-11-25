import Foundation
import SQLite3
import CommonCrypto
import Security

/// Credentials borrowed from the locally-installed Cursor app.
///
/// CursorGauge never mints or stores a secret of its own — it reads the token Cursor
/// already keeps on disk, so Cursor's own refresh cycle keeps us authenticated.
public struct CursorCredentials: Equatable {
    public let accessToken: String
    /// WorkOS-style user id, e.g. `user_01KBK90YXNWFCE45NE9M89HCYT`.
    /// This is the JWT `sub` with any `auth0|` prefix stripped.
    public let userSub: String
    public let expiresAt: Date

    public init(accessToken: String, userSub: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.userSub = userSub
        self.expiresAt = expiresAt
    }

    /// The exact cookie Cursor's web dashboard sends. `%3A%3A` is an encoded `::`.
    public var cookieHeader: String {
        "WorkosCursorSessionToken=\(userSub)%3A%3A\(accessToken)"
    }
}

public enum TokenError: Error, Equatable, CustomStringConvertible {
    case cursorNotInstalled
    case notSignedIn
    case expired(Date)
    case malformedToken
    case unreadable(String)
    case keychainUnavailable(String)
    case decryptionFailed

    public var description: String {
        switch self {
        case .cursorNotInstalled: return "Cursor isn't installed on this Mac"
        case .notSignedIn: return "Not signed in to Cursor"
        case .expired: return "Cursor session expired — open Cursor to sign in again"
        case .malformedToken: return "Cursor's stored token wasn't in the expected format"
        case .unreadable(let why): return "Couldn't read Cursor's data: \(why)"
        case .keychainUnavailable(let why):
            return "Cursor's login is encrypted at rest, but its Keychain key couldn't be read (\(why)). Allow CursorGauge Keychain access or sign in to Cursor again."
        case .decryptionFailed:
            return "Cursor's encrypted login couldn't be decrypted — sign in to Cursor again"
        }
    }
}

public protocol CredentialsProviding: AnyObject {
    func load() throws -> CursorCredentials
    /// Force the next `load()` to hit disk — call after a 401.
    func invalidate()
}

/// Reads `cursorAuth/accessToken` out of Cursor's SQLite state store.
///
/// That file is ~480 MB, so the result is cached: the token only rotates every few
/// months, and callers `invalidate()` on an auth failure rather than re-reading on
/// every poll.
public final class TokenStore: CredentialsProviding {
    private let databaseURL: URL
    private let clock: () -> Date
    private let keychainPassword: () throws -> String?
    private var cached: CursorCredentials?
    private let lock = NSLock()

    static let safeStoragePrefix = "cursor-safe-storage:v1:"

    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    public init(
        databaseURL: URL = TokenStore.defaultDatabaseURL,
        clock: @escaping () -> Date = Date.init,
        keychainPassword: (() throws -> String?)? = nil
    ) {
        self.databaseURL = databaseURL
        self.clock = clock
        self.keychainPassword = keychainPassword ?? TokenStore.defaultKeychainPassword
    }

    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cached = nil
    }

    public func load() throws -> CursorCredentials {
        lock.lock(); defer { lock.unlock() }

        // Re-read if we're within a day of expiry, in case Cursor has rotated it.
        if let cached, cached.expiresAt.timeIntervalSince(clock()) > 86_400 {
            return cached
        }

        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw TokenError.cursorNotInstalled
        }

        let stored = try readValue(forKey: "cursorAuth/accessToken")
        guard let stored, !stored.isEmpty else { throw TokenError.notSignedIn }

        let raw: String
        if stored.hasPrefix(Self.safeStoragePrefix) {
            do {
                guard let password = try keychainPassword(), !password.isEmpty else {
                    throw TokenError.keychainUnavailable("Keychain item 'Cursor Safe Storage' is missing or empty")
                }
                raw = try Self.decryptSafeStorage(stored, password: password)
            } catch let error as TokenError {
                throw error
            } catch {
                throw TokenError.keychainUnavailable(error.localizedDescription)
            }
        } else {
            raw = stored
        }

        let claims = try Self.decodeJWTClaims(raw)
        let credentials = CursorCredentials(
            accessToken: raw,
            userSub: claims.sub,
            expiresAt: claims.expiresAt
        )
        guard credentials.expiresAt > clock() else { throw TokenError.expired(credentials.expiresAt) }

        cached = credentials
        return credentials
    }

    // MARK: - SQLite

    private func readValue(forKey key: String) throws -> String? {
        // `mode=ro` keeps us off Cursor's write-ahead log. Opening read-only still
        // sees WAL-resident writes, so the token stays current.
        var uri = URLComponents()
        uri.scheme = "file"
        uri.path = databaseURL.path
        uri.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        guard let uriString = uri.string else { throw TokenError.unreadable("bad database path") }

        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            uriString, &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil
        )
        defer { if handle != nil { sqlite3_close_v2(handle) } }

        guard openResult == SQLITE_OK, let handle else {
            throw TokenError.unreadable(String(cString: sqlite3_errstr(openResult)))
        }

        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw TokenError.unreadable(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        // SQLITE_TRANSIENT: let SQLite copy the bytes; `key` doesn't outlive this call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let bytes = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: bytes)
        case SQLITE_DONE:
            return nil
        default:
            throw TokenError.unreadable(String(cString: sqlite3_errmsg(handle)))
        }
    }

    // MARK: - Cursor safeStorage decryption

    /// Reads the password Cursor's Electron safeStorage keeps in the macOS Keychain.
    /// Returns `nil` when the item is absent (older Cursor installs never created it).
    static func defaultKeychainPassword() throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Cursor Safe Storage",
            kSecAttrAccount as String: "Cursor Key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw TokenError.keychainUnavailable(message)
        }
    }

    /// Decrypts a `cursor-safe-storage:v1:` value (Electron safeStorage: `v10` header +
    /// AES-128-CBC, PBKDF2-HMAC-SHA1 key from `saltysalt`/1003 rounds, IV of 16 spaces).
    /// Unprefixed values are returned unchanged. Throws `TokenError.decryptionFailed` when
    /// the payload is not a well-formed, decryptable blob.
    static func decryptSafeStorage(_ stored: String, password: String) throws -> String {
        guard stored.hasPrefix(safeStoragePrefix) else { return stored }

        let encoded = String(stored.dropFirst(safeStoragePrefix.count))
        guard let payload = Data(base64Encoded: encoded), payload.count > 3 else {
            throw TokenError.decryptionFailed
        }
        guard String(data: payload.prefix(3), encoding: .utf8) == "v10" else {
            throw TokenError.decryptionFailed
        }
        let ciphertext = Data(payload.dropFirst(3))

        var key = [UInt8](repeating: 0, count: 16)
        let passwordBytes = Array(password.utf8)
        let salt = Array("saltysalt".utf8)
        let derived = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes, passwordBytes.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1003,
            &key, key.count
        )
        guard derived == kCCSuccess else { throw TokenError.decryptionFailed }

        let iv = [UInt8](repeating: 0x20, count: 16)
        var output = [UInt8](repeating: 0, count: ciphertext.count + 16)
        var outputLength = 0
        let status = ciphertext.withUnsafeBytes { buffer -> CCCryptorStatus in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                key, key.count,
                iv,
                buffer.baseAddress, ciphertext.count,
                &output, output.count,
                &outputLength
            )
        }
        guard status == kCCSuccess else { throw TokenError.decryptionFailed }

        guard let plaintext = String(bytes: output.prefix(outputLength), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !plaintext.isEmpty
        else { throw TokenError.decryptionFailed }

        return plaintext
    }

    // MARK: - JWT

    struct Claims: Equatable {
        let sub: String
        let expiresAt: Date
    }

    /// Decodes the payload only. We never verify the signature — Cursor's own server
    /// does that, and a forged token here would only fool the user's own menu bar.
    static func decodeJWTClaims(_ token: String) throws -> Claims {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { throw TokenError.malformedToken }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Base64url drops padding; Foundation's decoder requires it.
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = object["sub"] as? String,
              let exp = object["exp"] as? TimeInterval
        else { throw TokenError.malformedToken }

        // Cursor stores `auth0|user_01ABC…`; the cookie wants just the `user_…` half.
        let bareSub = sub.split(separator: "|").last.map(String.init) ?? sub
        guard !bareSub.isEmpty else { throw TokenError.malformedToken }

        return Claims(sub: bareSub, expiresAt: Date(timeIntervalSince1970: exp))
    }
}
