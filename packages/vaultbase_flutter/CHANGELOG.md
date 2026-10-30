## 0.1.3

- Works with `vaultbase` 0.4.0 (typed group fields from
  `dart run vaultbase:types`).

## 0.1.2

- Works with `vaultbase` 0.3.0 (`exclude` on reads).

## 0.1.1

- Works with `vaultbase` 0.2.0 (native Apple and Google sign-in:
  `signInWithIdToken`).

## 0.1.0

- `SecureAuthStore` (Keychain / Keystore via `flutter_secure_storage`) and
  `PrefsAuthStore` (shared preferences, for the web) keep the session
  across restarts.
- `VaultbaseLifecycle`: closes the realtime connection after 30 s in the
  background, reconnects and resubscribes on resume, and refreshes a
  session that expires within 5 minutes.
- `signInWithOAuth2` on `auth.collection(name)`: OAuth in the system's
  sign-in browser via `flutter_web_auth_2`, with server-kept PKCE. Closing
  the browser throws `CancelledException`.
- Re-exports `package:vaultbase`.
