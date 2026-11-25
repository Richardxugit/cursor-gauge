# Plan: Decrypt Cursor 3.x encrypted-at-rest tokens

> For Hermes: implement task-by-task with test-driven development; run every Swift step on the
> Mac via the mac_ssh wrapper because the container has no Swift toolchain.

## Tasks

1. **Spec + plan docs (this file)** — commit as `docs:`.
2. **RED tests** in `Tests/CursorGaugeCoreTests/TokenStoreTests.swift`:
   - in-test safeStorage encryptor (CommonCrypto) mirroring Chromium (`pbkdf2-sha1 saltysalt
     1003 → aes-128-cbc, IV = 16 spaces, `v10` prefix, `cursor-safe-storage:v1:` wrapper);
   - static precomputed fixture decrypting to `sub: auth0|user_fixture`, `exp: 2000000000`;
   - wrong password → `.decryptionFailed`; missing/nil Keychain password →
     `.keychainUnavailable`; provider throw → `.keychainUnavailable`; malformed base64 and
     missing `v10` header → `.decryptionFailed`;
   - `load()` end-to-end with an encrypted row and injected password provider;
   - unprefixed-token behavior untouched (existing tests keep guarding).
   Run `swift test --filter TokenStore` on the Mac; record compile-error lines as RED evidence.
3. **Implement** in `Sources/CursorGaugeCore/TokenStore.swift`:
   - `TokenError.keychainUnavailable(String)` + `.decryptionFailed` with user-facing text;
   - `defaultKeychainPassword()` via `SecItemCopyMatching` (generic password, service
     `Cursor Safe Storage`, account `Cursor Key`);
   - `decryptSafeStorage(_:password:)` static helper: base64 decode → strip `v10` → PBKDF2 →
     AES-128-CBC decrypt with PKCS#7 padding;
   - wire into `load()` behind the prefix check; injectable
     `keychainPassword: () throws -> String?` init parameter (default = real Keychain).
   Commit `feat: decrypt Cursor encrypted-at-rest tokens` with the same-commit tests.
4. **Full verification on Mac**: filtered GREEN then full `swift test` (both bundles; expect the
   known `testBenchmark50KRows` skip).
5. **Release v1.2.0**: bump `VERSION`, run `./package.sh`, `hdiutil verify`, mount and confirm
   version/architecture/signature, then OpenCLI Chrome Release upload (user attaches the DMG),
   API verify, deliver DMG via MEDIA.
