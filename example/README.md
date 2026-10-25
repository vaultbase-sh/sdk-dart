# Vaultbase notes (example)

A small Flutter app on Vaultbase: email and password sign-in (with two-factor
codes), GitHub sign-in in the system browser, and a list of notes that updates
live. It shows the pieces `vaultbase_flutter` adds to the core client:

- `SecureAuthStore` (`PrefsAuthStore` on the web) keeps the session across
  restarts; `await vb.authStore.ready` before the first frame.
- `VaultbaseLifecycle` closes the realtime connection in the background and
  reconnects on resume.
- `signInWithOAuth2` runs the OAuth flow in the system browser.

## Server setup

Run a Vaultbase server on port 8091 and, in the admin UI:

1. Open sign-up on the `users` auth collection: set its create rule to empty
   (anyone).
2. Create a `notes` base collection:
   - fields: `body` (text, required), `owner` (relation to `users`, required);
   - list and view rules: `owner = @request.auth.id`;
   - create rule: `@request.auth.id != '' && owner = @request.auth.id`;
   - delete rule: `owner = @request.auth.id`.
3. For the web build, add the app's origin to the allowed origins.
4. For GitHub sign-in: configure the GitHub provider and add
   `dev.vaultbase.example://oauth` to the allowed OAuth redirects, and as the
   callback URL in the provider's app settings. Some providers accept only
   `https` callbacks; for those, use an https page that forwards to the app
   scheme.

## Run

```bash
flutter run                                   # http://localhost:8091
flutter run --dart-define=VAULTBASE_URL=https://api.example.com
```

The Android emulator reaches the host at `10.0.2.2`, which is the default
there. Debug builds allow plain `http`; release builds need `https`.
