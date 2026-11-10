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
- **Typed errors:** a sealed `VaultbaseException`, so a `switch` covers
  every case. A 403 says which operation was refused and why; a
  `ValidationException` names the fields, sort names or body keys the
  server refused.
- **Server warnings:** a subscription to a missing collection, and on
  servers 0.42 and 0.43 a sort field, expand or body key that doesn't exist
  (0.44 refuses those with a 400); printed in debug builds and passed to
  `onWarning`.
- **Typed records:** `dart run vaultbase:types --schema=vaultbase-schema.json`
  generates a class per collection.

Needs Dart 3.6 and a Vaultbase server 0.27 or later.

## Server 0.44

Two things a server from 0.44 refuses that older ones let through:

- **A token it doesn't accept is a 401**, on records, files and batch, even
  for data anyone can read. The client refreshes the session once and
  retries. If the refresh is refused, the session is cleared and the request
  throws `AuthException` with `reason: AuthFailure.expired`: show sign-in,
  or send the request again, now without the token.
- **Names that don't exist are a 400.** A list with a `sort`, `expand` or
  `fields` name that isn't a field, and a create or update with a body key
  that isn't a field, throw `ValidationException`; `details` is keyed by the
  query parameter (`sort`) or the body key. A record can still be saved
  back as it was read (`update(id, {...record.toJson(), 'title': 'New'})`).
  The client adds no keys of its own.

## API tokens

For a script or a server, an API token (`vbat_...`) goes in the auth store:

```dart
final vb = Vaultbase('https://api.example.com',
    authStore: MemoryAuthStore()..save(StoredAuth(apiToken)));
```

It is not a session, so the client never refreshes or clears it. When the
server refuses it, the request throws `AuthException` with the server's
message: `AuthFailure.forbidden` when the token doesn't have the scope for
the request (`serverReason: "insufficient_scope"`, server 0.44),
`AuthFailure.expired` when it expired or was revoked (`"token_invalid"`).

## Documentation

[docs.vaultbase.dev/sdk-dart/quick-start](https://docs.vaultbase.dev/sdk-dart/quick-start/)
