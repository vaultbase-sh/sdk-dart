# vaultbase_flutter

The [Vaultbase](https://vaultbase.dev) client for Flutter apps. It re-exports
[`vaultbase`](https://pub.dev/packages/vaultbase) and adds:

- **Sessions that survive restarts:** `SecureAuthStore` (Keychain / Keystore)
  and `PrefsAuthStore` (shared preferences, for the web).
- **OAuth in the system browser:** `signInWithOAuth2`, through
  ASWebAuthenticationSession on iOS and macOS and Custom Tabs on Android.
- **App lifecycle:** `VaultbaseLifecycle` closes the realtime connection in
  the background, reconnects on resume, and refreshes a session close to
  expiry.

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vaultbase_flutter/vaultbase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final vb = Vaultbase('https://api.example.com',
      authStore: kIsWeb ? PrefsAuthStore() : SecureAuthStore());
  await vb.authStore.ready;
  VaultbaseLifecycle(vb);
  runApp(MyApp(vb: vb));
}

// Later, on a button:
final result = await vb.auth
    .collection('users')
    .signInWithOAuth2('github', redirectUri: 'com.example.app://oauth');
```

OAuth needs the redirect scheme registered on Android and the redirect allowed
on the server: see [Flutter set-up](https://docs.vaultbase.dev/sdk-dart/flutter/).

Needs Flutter 3.27 (Dart 3.6), iOS 13, and a Vaultbase server 0.27 or later.
A complete app (sign-in, GitHub sign-in, a live list) is in
[the example](https://github.com/vaultbase-sh/sdk-dart/tree/main/example).

## Documentation

[docs.vaultbase.dev/sdk-dart/quick-start](https://docs.vaultbase.dev/sdk-dart/quick-start/)
