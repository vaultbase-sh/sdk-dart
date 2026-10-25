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
