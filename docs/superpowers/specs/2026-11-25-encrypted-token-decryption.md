# Spec: Decrypt Cursor 3.x encrypted-at-rest tokens

**Date:** 2026-11-25
**Status:** Confirmed — approved by user 2026-11-25

## Problem

Cursor 3.x (observed 3.29.15) enables `cursor.storage.authTokenEncryptionAtRest` and stores
`cursorAuth/accessToken` in `state.vscdb` as:

```text
cursor-safe-storage:v1:<base64>
```

The base64 payload is an Electron safeStorage blob: a 3-byte `v10` header followed by
AES-128-CBC ciphertext. The key is derived with PBKDF2-HMAC-SHA1 (`saltysalt`, 1003 rounds,
16 bytes) from the password stored in the macOS Keychain item `Cursor Safe Storage` /
`Cursor Key`; the IV is sixteen space characters.

CursorGauge reads that value as a raw JWT, so `decodeJWTClaims` throws `.malformedToken` and
the menu bar shows "Cursor's stored token wasn't in the expected format" — i.e. the gauge
stops loading on machines that auto-updated Cursor.

## Decision

Detect the `cursor-safe-storage:v1:` prefix in `TokenStore.load()` and, on macOS, decrypt the
value with the Cursor Keychain password before JWT parsing. Unprefixed tokens keep the exact
current behavior. Decrypted plaintext stays in memory only — nothing is written back to disk,
logged, or persisted; the existing in-memory cache and `invalidate()` semantics are unchanged.

## Requirements

- R1. `cursor-safe-storage:v1:` values decrypt to the original JWT and flow through the
  existing claim/expiry/cookie path unchanged.
- R2. Unprefixed values are treated exactly as today (no regression for older Cursor installs).
- R3. Keychain read errors and decryption failures surface as distinct, actionable messages —
  never as "signed out" or "wrong format".
- R4. The plaintext token is never persisted, logged, or exposed in any new surface.
- R5. All existing TokenStore behavior (cache, expiry re-read, auth0 prefix stripping) keeps
  its current contract and tests.

## Verification

- RED: new TokenStore tests fail to compile/assert against the missing decrypt path.
- GREEN: the same tests pass; full `swift test` suite green on both bundles.
- Fixture independence: at least one test decrypts a static precomputed ciphertext fixture
  (generated externally with Node `crypto`, algorithm identical to Chromium safeStorage) so
  production decryption is not validated only against its own mirror.
- Manual acceptance on the user's machine: `--dry-run` prints usage after the user allows the
  one-time Keychain prompt for `Cursor Safe Storage`.
