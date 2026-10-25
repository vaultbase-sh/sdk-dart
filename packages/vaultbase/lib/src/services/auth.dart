import '../auth_store.dart';
import '../client.dart';
import '../errors.dart';
import '../models.dart';

/// The outcome of a sign-in.
sealed class AuthResult {
  const AuthResult();
}

/// Signed in; the session is stored (except for [AdminAuth.impersonate]).
final class SignedIn extends AuthResult {
  const SignedIn(this.token, this.record,
      {this.linkedProvider, this.impersonatedBy});

  final String token;
  final RecordModel record;

  /// The provider just linked, after [CollectionAuth.oauth2MergeConfirm].
  final String? linkedProvider;

  /// The admin's id, after [AdminAuth.impersonate].
  final String? impersonatedBy;
}

/// The account has two-factor sign-in on: finish with
/// [CollectionAuth.loginMfa] and this [mfaToken]. Nothing is stored yet.
final class MfaRequired extends AuthResult {
  const MfaRequired(this.mfaToken, {this.linkedProvider});

  final String mfaToken;
  final String? linkedProvider;
}

/// An OAuth sign-in matched an existing account by email: confirm the link
/// with [CollectionAuth.oauth2MergeConfirm]. Nothing is stored yet.
final class MergeRequired extends AuthResult {
  const MergeRequired(this.mergeToken, this.email, this.provider);

  final String mergeToken;
  final String email;
  final String provider;
}

/// An OAuth provider enabled on the server.
class OAuth2Provider {
  const OAuth2Provider(this.name, {this.displayName, this.clientId});

  final String name;
  final String? displayName;
  final String? clientId;
}

/// The start of an OAuth sign-in: send the user to [authorizeUrl].
class OAuth2Authorization {
  const OAuth2Authorization({
    required this.authorizeUrl,
    required this.state,
    required this.stateSecret,
    required this.pkce,
    this.codeChallenge,
  });

  final Uri authorizeUrl;

  /// Comes back on the redirect; [CollectionAuth.oauth2Exchange] needs it.
  final String state;

  /// Proves the exchange comes from the client that started the flow. This
  /// client remembers it for [state]; pass it yourself if the redirect is
  /// handled by another client instance.
  final String stateSecret;

  /// `server`, `client` or `none`.
  final String pkce;
  final String? codeChallenge;
}

/// Sign-in and the session.
class AuthService {
  AuthService(this._vb);

  final Vaultbase _vb;
  final _collections = <String, CollectionAuth>{};
  final _stateSecrets = <String, String>{};

  /// Sign-in flows of the auth collection [name].
  CollectionAuth collection(String name) =>
      _collections[name] ??= CollectionAuth._(_vb, name, _stateSecrets);

  /// Admin sign-in and admin-only flows.
  late final AdminAuth admin = AdminAuth._(_vb);

  /// True when there is a session whose token has not expired.
  bool get isSignedIn => _vb.authStore.isValid;

  /// Swaps the token for a new one and stores it. False when the server
  /// refused (the session is then cleared); throws on a network error.
  Future<bool> refresh() => _vb.refreshSession();

  /// Ends the session on the server and clears it here, even when the
  /// server can't be reached.
  Future<void> logout() async {
    try {
      if (_vb.authStore.token?.isNotEmpty ?? false) {
        await _vb.request('/api/v1/auth/logout',
            method: 'POST', skipRefresh: true);
      }
    } on VaultbaseException {
      // Signed out locally either way.
    } finally {
      _vb.authStore.clear();
    }
  }

  /// The signed-in user or admin, as the server sees it.
  Future<Map<String, dynamic>> me() async =>
      _map(await _vb.request('/api/v1/auth/me'));
}

/// Sign-in flows of one auth collection: `vb.auth.collection('users')`.
class CollectionAuth {
  CollectionAuth._(this._vb, this.collection, this._stateSecrets);

  final Vaultbase _vb;
  final String collection;
  final Map<String, String> _stateSecrets;

  String _path(String action) =>
      '/api/v1/auth/${Uri.encodeComponent(collection)}/$action';

  Future<Map<String, dynamic>> _post(String action,
          {Object? body, bool skipAuth = true}) async =>
      _map(await _vb.request(_path(action),
          method: 'POST', body: body, skipAuth: skipAuth));

  /// Creates an account. Doesn't sign in; call [login] next. Extra fields
  /// of the collection go in [data].
  Future<RecordModel> register(String email, String password,
          {Map<String, dynamic> data = const {}}) async =>
      RecordModel(await _post('register',
          body: {...data, 'email': email, 'password': password}));

  /// Signs in with email and password: [SignedIn], or [MfaRequired].
  Future<AuthResult> login(String email, String password) async => _store(
      await _post('login', body: {'email': email, 'password': password}));

  /// Finishes a sign-in that returned [MfaRequired], with an authenticator
  /// [code] or a [recoveryCode].
  Future<SignedIn> loginMfa(String mfaToken,
      {String? code, String? recoveryCode}) async {
    final result = _store(await _post('login/mfa', body: {
      'mfa_token': mfaToken,
      if (code != null) 'code': code,
      if (recoveryCode != null) 'recovery_code': recoveryCode,
    }));
    return result as SignedIn;
  }

  /// Signs in as a new anonymous user; [promote] turns it into a real one.
  Future<SignedIn> anonymous() async =>
      _store(await _post('anonymous')) as SignedIn;

  /// Gives the signed-in anonymous user an email and password, keeping its
  /// records.
  Future<SignedIn> promote(String email, String password,
          {Map<String, dynamic> data = const {}}) async =>
      _store(await _post('promote',
          body: {...data, 'email': email, 'password': password},
          skipAuth: false)) as SignedIn;

  /// Emails the signed-in user a verification link. False when the email
  /// was already verified.
  Future<bool> requestVerification() async =>
      (await _post('request-verify', skipAuth: false))['sent'] == true;

  /// Confirms an email with the token from the verification link.
  Future<void> confirmVerification(String token) =>
      _post('verify-email', body: {'token': token});

  Future<void> requestPasswordReset(String email) =>
      _post('request-password-reset', body: {'email': email});

  Future<void> confirmPasswordReset(String token, String password) =>
      _post('confirm-password-reset',
          body: {'token': token, 'password': password});

  /// Emails a confirmation link to [newEmail] (signed-in user).
  Future<void> requestEmailChange(String newEmail) =>
      _post('request-email-change',
          body: {'newEmail': newEmail}, skipAuth: false);

  /// Applies an email change with the link's token and the current
  /// password. Every session of the account ends, this one included; returns
  /// the new email.
  Future<String> confirmEmailChange(String token, String password) async {
    final data = await _post('confirm-email-change',
        body: {'token': token, 'password': password});
    _vb.authStore.clear();
    return data['email'] as String? ?? '';
  }

  /// Sets a password from an invitation link; also verifies the email.
  Future<void> acceptInvite(String token, String password) =>
      _post('accept-invite', body: {'token': token, 'password': password});

  /// Emails a one-time sign-in code and link.
  Future<void> requestOtp(String email) =>
      _post('otp/request', body: {'email': email});

  /// Signs in with the emailed [code] (and [email]) or the link's [token].
  Future<AuthResult> authWithOtp(
          {String? email, String? code, String? token}) async =>
      _store(await _post('otp/auth', body: {
        if (email != null) 'email': email,
        if (code != null) 'code': code,
        if (token != null) 'token': token,
      }));

  /// Starts authenticator (TOTP) setup: show [secret] or [otpauthUrl] as a
  /// QR code, then call [confirmTotp] with a code from the app.
  Future<({String secret, String otpauthUrl})> setupTotp() async {
    final data = await _post('totp/setup', skipAuth: false);
    return (
      secret: data['secret'] as String,
      otpauthUrl: data['otpauth_url'] as String
    );
  }

  /// Turns TOTP on. Returns the recovery codes: show them once.
  Future<List<String>> confirmTotp(String code) async {
    final data =
        await _post('totp/confirm', body: {'code': code}, skipAuth: false);
    return _strings(data['recovery_codes']);
  }

  Future<void> disableTotp(String code) =>
      _post('totp/disable', body: {'code': code}, skipAuth: false);

  /// A new set of recovery codes; needs a current authenticator [code].
  Future<List<String>> regenerateRecoveryCodes(String code) async {
    final data = await _post('totp/recovery/regenerate',
        body: {'code': code}, skipAuth: false);
    return _strings(data['codes']);
  }

  Future<({int total, int remaining})> recoveryCodeStatus() async {
    final data = _map(await _vb.request(_path('totp/recovery/status')));
    return (
      total: (data['total'] as num).toInt(),
      remaining: (data['remaining'] as num).toInt()
    );
  }

  /// The OAuth providers enabled on the server.
  Future<List<OAuth2Provider>> oauth2Providers() async {
    final data = await _vb.request(_path('oauth2/providers'), skipAuth: true);
    return [
      for (final p in data as List)
        if (p is Map)
          OAuth2Provider(p['name'] as String,
              displayName: p['displayName'] as String?,
              clientId: p['clientId'] as String?)
    ];
  }

  /// Starts an OAuth sign-in. [redirectUri] must be on the server's
  /// allow-list; an app scheme (`com.example.app://oauth`) works.
  /// [usePkce] has the server keep a PKCE verifier; pass [codeChallenge] to
  /// keep your own.
  Future<OAuth2Authorization> oauth2Authorize(
      String provider, String redirectUri,
      {String? state, bool usePkce = false, String? codeChallenge}) async {
    final data = _map(await _vb.request(_path('oauth2/authorize'),
        query: {
          'provider': provider,
          'redirectUri': redirectUri,
          'state': state,
          'use_pkce': usePkce ? '1' : null,
          'code_challenge': codeChallenge,
        },
        skipAuth: true));
    final auth = OAuth2Authorization(
      authorizeUrl: Uri.parse(data['authorize_url'] as String),
      state: data['state'] as String,
      stateSecret: data['state_secret'] as String,
      pkce: data['pkce'] as String? ?? 'none',
      codeChallenge: data['code_challenge'] as String?,
    );
    _stateSecrets[auth.state] = auth.stateSecret;
    return auth;
  }

  /// Finishes an OAuth sign-in with the `code` and `state` from the
  /// redirect: [SignedIn], [MfaRequired] or [MergeRequired].
  Future<AuthResult> oauth2Exchange(
      String provider, String code, String redirectUri, String state,
      {String? stateSecret, String? codeVerifier}) async {
    final secret = stateSecret ?? _stateSecrets.remove(state);
    final data = await _post('oauth2/exchange', body: {
      'provider': provider,
      'code': code,
      'redirectUri': redirectUri,
      'state': state,
      if (secret != null) 'state_secret': secret,
      if (codeVerifier != null) 'code_verifier': codeVerifier,
    });
    return _store(data);
  }

  /// Finishes an OAuth sign-in from the URL the provider redirected to.
  /// A redirect that carries an `error` throws [AuthException].
  Future<AuthResult> oauth2ExchangeRedirect(
      String provider, String redirectUri, Uri redirect,
      {String? stateSecret, String? codeVerifier}) async {
    final params = {
      ...Uri.splitQueryString(redirect.fragment),
      ...redirect.queryParameters,
    };
    final error = params['error'];
    if (error != null) {
      throw AuthException(
          AuthFailure.invalid, params['error_description'] ?? error,
          code: error);
    }
    final code = params['code'];
    final state = params['state'];
    if (code == null || state == null) {
      throw const AuthException(
          AuthFailure.invalid, 'The redirect has no code or state');
    }
    return oauth2Exchange(provider, code, redirectUri, state,
        stateSecret: stateSecret, codeVerifier: codeVerifier);
  }

  /// Links the provider from a [MergeRequired] to the existing account,
  /// with its [password] when the server asks for it.
  Future<AuthResult> oauth2MergeConfirm(String mergeToken,
          {String? password}) async =>
      _store(await _post('oauth2/merge-confirm',
          body: {
            'merge_token': mergeToken,
            if (password != null) 'password': password,
          },
          skipAuth: false));

  /// A single-use nonce for [signInWithIdToken] with [provider] (`apple`
  /// or `google`), valid for 10 minutes. Give it to the platform's sign-in
  /// sheet as it is; the server also accepts its SHA-256 in hex. Required
  /// for Apple; optional for Google.
  Future<String> idTokenNonce(String provider) async =>
      (await _post('oauth2/id-token/nonce',
          body: {'provider': provider}))['nonce'] as String;

  /// Signs in with an ID token from the platform's own sign-in sheet (Sign
  /// in with Apple, Google sign-in): [SignedIn], [MfaRequired] or
  /// [MergeRequired], as for OAuth in the browser. Each token works once.
  ///
  /// [nonce] is the one from [idTokenNonce] that the token carries.
  /// Required for Apple. Google's Flutter plugin fixes its nonce when it is
  /// initialized, once per launch, so leave it out for Google unless the
  /// token carries one from [idTokenNonce].
  ///
  /// Apple gives the app the user's [name] only on the first sign-in, and
  /// never in the token; pass it on so a new account gets it. Needs server
  /// 0.28 or later.
  Future<AuthResult> signInWithIdToken(String provider, String idToken,
          {String? nonce, String? name}) async =>
      _store(await _post('oauth2/id-token', body: {
        'provider': provider,
        'id_token': idToken,
        if (nonce != null) 'nonce': nonce,
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      }));

  Future<void> oauth2Unlink(String provider) async {
    await _vb.request(_path('oauth2/${Uri.encodeComponent(provider)}/unlink'),
        method: 'DELETE');
  }

  AuthResult _store(Map<String, dynamic> data) {
    final result = parseAuthResult(data);
    if (result is SignedIn) {
      _vb.authStore.save(StoredAuth(result.token, record: result.record.data));
    }
    return result;
  }
}

/// Admin sign-in and admin-only flows: `vb.auth.admin`.
class AdminAuth {
  AdminAuth._(this._vb);

  final Vaultbase _vb;

  /// Whether the server has an admin yet, and whether setup needs the key
  /// it printed at first start.
  Future<({bool hasAdmin, bool keyRequired})> setupStatus() async {
    final data =
        _map(await _vb.request('/api/v1/admin/setup/status', skipAuth: true));
    return (
      hasAdmin: data['has_admin'] == true,
      keyRequired: data['key_required'] == true
    );
  }

  /// Creates the first admin.
  Future<void> setup(String email, String password, {String? setupKey}) =>
      _vb.request('/api/v1/admin/setup',
          method: 'POST',
          body: {'email': email, 'password': password},
          headers: setupKey == null ? null : {'x-setup-key': setupKey},
          skipAuth: true);

  /// Signs in as an admin and stores the session.
  Future<SignedIn> login(String email, String password) async {
    final data = _map(await _vb.request('/api/v1/admin/auth/login',
        method: 'POST',
        body: {'email': email, 'password': password},
        skipAuth: true));
    final record = (data['admin'] as Map).cast<String, dynamic>();
    final token = data['token'] as String;
    _vb.authStore.save(StoredAuth(token, record: record));
    return SignedIn(token, RecordModel(record));
  }

  Future<Map<String, dynamic>> me() async =>
      _map(await _vb.request('/api/v1/admin/auth/me'));

  /// Creates a user without a password and emails an invitation link.
  Future<RecordModel> invite(String collection, String email,
          {Map<String, dynamic> data = const {}}) async =>
      RecordModel(_map(await _vb.request(
          '/api/v1/admin/users/${Uri.encodeComponent(collection)}/invite',
          method: 'POST',
          body: {'email': email, 'data': data})));

  /// A session for the user, without storing it (the admin stays signed
  /// in here). Use the token in another client.
  Future<SignedIn> impersonate(String collection, String userId) async {
    final data = _map(await _vb.request(
        '/api/v1/admin/impersonate/${Uri.encodeComponent(collection)}/${Uri.encodeComponent(userId)}',
        method: 'POST'));
    return parseAuthResult(data) as SignedIn;
  }
}

/// Reads a sign-in response.
AuthResult parseAuthResult(Map<String, dynamic> data) {
  final linked = data['linked_provider'] as String?;
  if (data['mfa_required'] == true) {
    return MfaRequired(data['mfa_token'] as String, linkedProvider: linked);
  }
  if (data['merge_required'] == true) {
    return MergeRequired(data['merge_token'] as String,
        data['email'] as String? ?? '', data['provider'] as String? ?? '');
  }
  final token = data['token'];
  if (token is! String || token.isEmpty) {
    throw ServerException('The sign-in response has no token', body: data);
  }
  return SignedIn(token,
      RecordModel((data['record'] as Map?)?.cast<String, dynamic>() ?? {}),
      linkedProvider: linked,
      impersonatedBy: data['impersonated_by'] as String?);
}

Map<String, dynamic> _map(Object? data) =>
    data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};

List<String> _strings(Object? v) =>
    v is List ? [for (final e in v) '$e'] : const [];
