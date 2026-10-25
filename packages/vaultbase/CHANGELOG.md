## 0.1.0-dev

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
