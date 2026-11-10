## 0.7.0

For server 0.42: the reasons a 403 gives, the server's warnings, and error
classes for 400 and 404.

- **Breaking:** `AuthFailure.notSignedIn`: a 403 whose rule needs a
  signed-in caller and the request had no session (`reason:
  "not_signed_in"`). An exhaustive `switch` over `AuthFailure` needs the new
  case. Rules that refuse a signed-in caller and admin-only endpoints stay
  `forbidden`.
- A 403 with `reason: "token_invalid"` (the server didn't accept the token
  and ran the request as anonymous) is handled like a 401: one refresh and
  a retry; if the refresh is refused, the session is cleared and the
  request throws `AuthException(AuthFailure.expired)`.
- `AuthException.operation` (`AuthOperation.list`, `view`, `create`,
  `update`, `delete`) and `AuthException.serverReason` (`not_signed_in`,
  `rule_denied`, `admin_only`, `token_invalid`) from a 403 body; null on
  older servers.
- A token close to expiry whose refresh is refused throws
  `AuthException(AuthFailure.expired)` instead of sending the request
  without the session (it came back as a 403 that looked like a rule).
- **Breaking:** a 400 (a bad filter, sort or body) is a
  `ValidationException` with `status` 400; it was a `ServerException`.
- `NotFoundException` for a 404. It extends `ServerException`, so
  `on ServerException` and an exhaustive `switch` with a `ServerException`
  case still cover it.
- Server warnings: `Vaultbase(onWarning:)` is called with a
  `VaultbaseWarning` for each message of a `Vaultbase-Warning` response
  header (an unknown sort field, expand or body key) and for a realtime
  `warning` frame (a subscription to a collection that doesn't exist).
  `printWarnings` prints them as `[vaultbase] ...`: `debug` (the default,
  only with assertions on, so not in release builds), `always` or `never`.
- Registering an email that already has an account is a
  `ConflictException` (server 0.42 answers 409).
- `Batch.list` documents that a batch that writes can't list.

## 0.6.0

- `buildFilter` throws on a list (the filter language has no list value;
  the server answered 400) and writes doubles as plain decimals
  (`1e21`, `1e-7` were sent in exponent form, which the server refuses).
- Realtime: a server that accepts and then closes at once (connection cap,
  maintenance) is retried with growing delays instead of about four times
  a second; the backoff starts over once a connection stays up 5 s. A
  server that refuses the app's origin isn't retried.
- `RealtimeSubscription.ready` completes when the subscription is
  cancelled, the client is closed or the origin is refused, instead of
  never.
- A token refresh that ends after a sign-out or a new sign-in leaves that
  session alone (it used to store the refreshed token, or clear the new
  session when the refresh was refused).
- Only a successful response's ETag is cached: a 412's let a blind retry of
  the same update overwrite the other write. The cache keeps the latest
  1000 records.
- `BatchResult.record` returns the operation's record; a record with a
  JSON field named `data` returned that field.
- `Batch.list(search:)` is deprecated and no longer sent: the server's
  batch list ignores it.
- `dart run vaultbase:types`: a collection whose name doesn't start with a
  letter (`_2fa`) gets a valid class name (`C2faRecord`).

## 0.5.0

- `params:` on `list`, `iterate`, `get` and `aggregate` fills a view
  collection's parameters (`:name` in its query), sent as `params[name]`; a
  `DateTime` as UTC ISO 8601. `dart run vaultbase:types` emits a
  `<View>Params` class per view with parameters (required ones `required`;
  the one from the signed-in user left out): `list(params:
  RevenueParams(status: 'paid').toMap())`.
- `MaintenanceException`: a 503 from a server in maintenance mode, with
  its `level` (`full` or `readOnly`) and, when the admin set a time,
  `until` and `retryAfter`. `VaultbaseException` is sealed, so an
  exhaustive `switch` over it needs the new case.

## 0.4.0

- `dart run vaultbase:types` generates a class per group field, named after
  the collection and field (`OrdersItemsItem`, or `OrdersAddress` for a
  single object), with a member per subfield, the item's `id`, `fromJson`
  and `toJson`. Records get `List<OrdersItemsItem>` (or `OrdersAddress?`)
  getters; create classes take them. Group fields need server 0.32.0.

## 0.3.0

- `exclude` on `list`, `iterate`, `get`, `Singleton.get` and `Batch.list`:
  fields to leave out of the response, applied after `fields`.
- `Batch.get` takes `expand`, `fields` and `exclude`.
- Both need server 0.31.0.

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
