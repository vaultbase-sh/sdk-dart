## Unreleased

- `exclude` on `list`, `iterate`, `get`, `Singleton.get` and `Batch.list`:
  fields to leave out of the response, applied after `fields`. Needs server
  0.31.0.

## 0.2.0

- Native Apple and Google sign-in: `auth.collection(name).signInWithIdToken`
  with the ID token from the platform's sign-in sheet, and `idTokenNonce` for
  the single-use nonce (required for Apple). Needs server 0.28.

## 0.1.0

- The client: `Vaultbase(baseUrl)` with an `AuthStore` (memory by default),
  an optional `http.Client`, a per-request timeout and default headers.
- Records: `collection(name)` / `collectionOf(name, fromJson)` with `list`,
  `iterate`, `get`, `create`, `update`, `delete` and `aggregate`; ETags are
  kept from reads and sent as `If-Match` on update and delete.
- Singletons (`singleton(name)`), batches of up to 100 operations
  (`batch()`), custom routes (`custom`), and `send()` for any endpoint.
- `filter()` / `buildFilter()`: `{:name}` placeholders, escaped by type.
- Sessions: refreshed 60 s before the token expires and once on a 401,
  shared by concurrent requests; `auth.refresh()`, `auth.logout()`,
  `auth.me()`. A refresh that fails for lack of a connection keeps the
  session; only one the server refuses clears it.
- `CancelToken`, request keys and `autoCancel` to cancel requests.
- Typed errors: a sealed `VaultbaseException` with one subclass per kind;
  the server's error `code` is kept.
- Sign-in: `auth.collection(name)` with register, login, two-factor
  (`loginMfa`, TOTP setup / confirm / disable, recovery codes), one-time
  codes, anonymous sign-in and promote, email verification, password reset,
  email change, invitations, and OAuth (`oauth2Authorize`,
  `oauth2Exchange`, `oauth2ExchangeRedirect`, merge confirm, unlink).
  Results are a sealed `AuthResult`: `SignedIn`, `MfaRequired`,
  `MergeRequired`. `auth.admin` for admin setup, sign-in, invites and
  impersonation.
- Files: `files.upload` with `UploadFile.fromBytes` / `fromStream` and
  upload progress, `files.url` with thumbnails and formats, access tokens
  for protected files (`token`, `urlWithToken`), `files.delete`.
- Realtime over one WebSocket: `collection(name).subscribe` / `events()`,
  per-record subscriptions, `ready` once the server confirms, reconnect
  with backoff, the new token sent after each refresh, `pause` / `resume`,
  and a `states` stream.
- `AsyncAuthStore` for sessions kept in async storage: loads the saved
  session once, writes changes in order. Requests and the realtime
  connection wait for `authStore.ready`, so the first request after start
  carries the saved token.
- Feature flags: `vb.flags.connect(context: ...)` loads every flag the
  server evaluates for the context; `isEnabled`, `getString`, `getNumber`,
  `getJson` read them synchronously; `changes` names the keys that
  changed. Changes are pushed over the realtime connection record
  subscriptions use, with a periodic refetch as a fallback, and the flags
  are fetched again after sign-in, sign-out and a reconnect.
- `realtime.subscribeTopic` for server topics that aren't collections.
- Typed records: `dart run vaultbase:types --schema=vaultbase-schema.json`
  (or `--url` with `--admin-token`) writes `lib/vaultbase_schema.g.dart`:
  an `XRecord extends RecordModel` per collection with a getter per field,
  an `XCreate` with `toJson()`, and `vb.collections.<name>` returning
  `Collection<XRecord>` / `Singleton<XRecord>`.
- Realtime: closing the client while a connection is opening leaves no
  pending timer (widget tests failed on it), and a connection attempt that
  times out is closed.
