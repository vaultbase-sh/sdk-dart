# vaultbase

The Dart client for [Vaultbase](https://vaultbase.dev), the single-binary
backend: records, auth, files, realtime and feature flags. Pure Dart: it runs
in Flutter apps, on the server, in command-line tools and in tests.

For a Flutter app, add [`vaultbase_flutter`](https://pub.dev/packages/vaultbase_flutter)
instead. It re-exports this package and adds sessions that survive restarts,
OAuth in the system browser, and app lifecycle handling.

```dart
import 'package:vaultbase/vaultbase.dart';

Future<void> main() async {
  final vb = Vaultbase('https://api.example.com');

  await vb.auth.collection('users').login('a@b.c', 'a-long-password');

  final page = await vb.collection('posts').list(
      filter: vb.filter('views > {:n}', {'n': 10}), sort: '-created');
  for (final post in page.items) {
    print(post.getString('title'));
  }

  final sub = vb.collection('posts').subscribe((e) => print('${e.action} ${e.id}'));
  await Future<void>.delayed(const Duration(minutes: 1));
  sub.cancel();
  vb.close();
}
```

## What's in it

- **Records:** list, iterate, get, create, update, delete, aggregate, with
  ETags sent as `If-Match` so concurrent edits don't overwrite each other.
  Singletons, batches of up to 100 operations, custom routes.
- **Auth:** email and password, two-factor (authenticator apps and recovery
  codes), one-time codes, anonymous users, OAuth, verification, password
  reset, email change, invitations, admin sign-in. Sessions refresh
  themselves.
- **Files:** uploads with progress, thumbnail URLs, tokens for protected files.
- **Realtime:** record changes over one WebSocket, with reconnects and the
  session's token kept current.
- **Feature flags:** evaluated by the server, read synchronously, pushed when
  they change.
- **Typed errors:** a sealed `VaultbaseException`, so a `switch` covers every case.
- **Typed records:** `dart run vaultbase:types --schema=vaultbase-schema.json`
  generates a class per collection.

Needs Dart 3.6 and a Vaultbase server 0.27 or later.

## Documentation

[docs.vaultbase.dev/sdk-dart/quick-start](https://docs.vaultbase.dev/sdk-dart/quick-start/)
