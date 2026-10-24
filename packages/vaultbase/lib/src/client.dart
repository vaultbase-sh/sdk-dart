import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_store.dart';
import 'cancel.dart';
import 'errors.dart';
import 'etag_cache.dart';
import 'filter.dart';
import 'jwt.dart';
import 'models.dart';
import 'realtime.dart';
import 'services/auth.dart';
import 'services/batch.dart';
import 'services/collection.dart';
import 'services/custom.dart';
import 'services/files.dart';
import 'services/singleton.dart';

/// Refresh the session this many seconds before its token expires.
const _refreshLeadSeconds = 60;

/// Builds the parts of a multipart body. Called again for the retry after a
/// token refresh, since a [http.MultipartFile] can only be sent once.
typedef MultipartBuilder = ({
  Map<String, String> fields,
  List<http.MultipartFile> files,
})
    Function();

/// The Vaultbase client.
///
/// ```dart
/// final vb = Vaultbase('https://api.example.com');
/// final posts = await vb.collection('posts').list(sort: '-created');
/// ```
class Vaultbase {
  Vaultbase(
    String baseUrl, {
    AuthStore? authStore,
    http.Client? httpClient,
    this.autoCancel = false,
    this.timeout,
    Map<String, String> headers = const {},
  })  : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
        authStore = authStore ?? MemoryAuthStore(),
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null,
        _headers = Map.of(headers);

  /// The server's address, without a trailing slash.
  final String baseUrl;

  /// Holds the session; [MemoryAuthStore] unless another is passed.
  final AuthStore authStore;

  /// When true, a request without a `requestKey` gets one from its method
  /// and path, so a newer identical request cancels the older one.
  final bool autoCancel;

  /// Time limit for each request; none when null.
  final Duration? timeout;

  final http.Client _http;
  final bool _ownsHttp;
  final Map<String, String> _headers;

  /// ETags of records read through this client, for `If-Match`.
  final etags = EtagCache();

  final _cancels = CancelRegistry();
  Future<bool>? _refreshing;

  /// Sign-in, refresh, sign-out.
  late final AuthService auth = AuthService(this);

  /// Record changes pushed over a WebSocket.
  late final Realtime realtime = Realtime(this);

  /// Upload, file URLs and access tokens.
  late final Files files = Files(this);

  /// Custom routes under `/api/v1/custom/`.
  late final CustomRoutes custom = CustomRoutes(this);

  /// Records of [name], as [RecordModel]s.
  Collection<RecordModel> collection(String name) =>
      Collection(this, name, RecordModel.fromJson);

  /// Records of [name], decoded with [fromJson].
  Collection<T> collectionOf<T>(
          String name, T Function(Map<String, dynamic>) fromJson) =>
      Collection(this, name, fromJson);

  /// The record of the singleton collection [name].
  Singleton<RecordModel> singleton(String name) =>
      Singleton(this, name, RecordModel.fromJson);

  /// The record of the singleton collection [name], decoded with [fromJson].
  Singleton<T> singletonOf<T>(
          String name, T Function(Map<String, dynamic>) fromJson) =>
      Singleton(this, name, fromJson);

  /// Several operations in one request (at most 100).
  Batch batch() => Batch(this);

  /// A filter expression with `{:name}` placeholders filled from [params],
  /// escaped. See [buildFilter].
  String filter(String expression, [Map<String, Object?> params = const {}]) =>
      buildFilter(expression, params);

  /// The full URL for [path] with [query] (null values skipped).
  Uri buildUrl(String path, [Map<String, Object?>? query]) {
    final uri = Uri.parse('$baseUrl${path.startsWith('/') ? '' : '/'}$path');
    final extra = <String, String>{
      for (final e in (query ?? const <String, Object?>{}).entries)
        if (e.value != null) e.key: e.value.toString(),
    };
    if (extra.isEmpty) return uri;
    return uri.replace(queryParameters: {...uri.queryParameters, ...extra});
  }

  /// Sends a request to any endpoint, with the session, error mapping and
  /// envelope unwrapping the typed methods use.
  Future<dynamic> send(
    String path, {
    String method = 'GET',
    Object? body,
    Map<String, String>? headers,
    Map<String, Object?>? query,
    CancelToken? cancelToken,
    String? requestKey,
    bool? autoCancel,
    bool skipAuth = false,
  }) =>
      request(path,
          method: method,
          body: body,
          headers: headers,
          query: query,
          cancelToken: cancelToken,
          requestKey: requestKey,
          autoCancel: autoCancel,
          skipAuth: skipAuth);

  /// Cancels every request that has a request key.
  void cancelAll() => _cancels.cancelAll();

  /// Closes the HTTP client, if this client created it.
  void close() {
    realtime.close();
    _cancels.cancelAll();
    if (_ownsHttp) _http.close();
  }

  /// The request pipeline behind every method. Not for direct use; see
  /// [send].
  Future<dynamic> request(
    String path, {
    String method = 'GET',
    Object? body,
    Map<String, String>? headers,
    Map<String, Object?>? query,
    CancelToken? cancelToken,
    String? requestKey,
    bool? autoCancel,
    bool skipAuth = false,
    bool skipRefresh = false,
    bool retried = false,
    MultipartBuilder? multipart,
    void Function(int sent, int total)? onProgress,
    void Function(http.Response)? onResponse,
  }) async {
    final uri = buildUrl(path, query);
    final hdrs = <String, String>{..._headers, ...?headers};
    if (!skipAuth) {
      if (!skipRefresh) await _maybeRefresh();
      final token = authStore.token;
      if (token != null && token.isNotEmpty) {
        hdrs['Authorization'] = 'Bearer $token';
      }
    }

    final key = requestKey ??
        ((autoCancel ?? this.autoCancel) ? '$method:$path' : null);
    final keyToken = key == null ? null : _cancels.acquire(key);
    final tokens = <CancelToken>[
      if (cancelToken != null) cancelToken,
      if (keyToken != null) keyToken,
    ];
    final cancel = switch (tokens.length) {
      0 => null,
      1 => tokens.first,
      _ => CancelToken.any(tokens),
    };

    var timedOut = false;
    Timer? timer;
    Completer<void>? abort;
    if (cancel != null || timeout != null) {
      final c = abort = Completer<void>();
      cancel?.whenCancelled.then((_) {
        if (!c.isCompleted) c.complete();
      });
      final t = timeout;
      if (t != null) {
        timer = Timer(t, () {
          timedOut = true;
          if (!c.isCompleted) c.complete();
        });
      }
    }

    final http.BaseRequest req;
    if (multipart != null) {
      final parts = multipart();
      final form = http.MultipartRequest(method, uri)
        ..fields.addAll(parts.fields)
        ..files.addAll(parts.files);
      final bytes = form.finalize();
      final total = form.contentLength;
      final streamed = http.AbortableStreamedRequest(method, uri,
          abortTrigger: abort?.future)
        ..contentLength = total;
      hdrs.addAll(form.headers);
      var sent = 0;
      // addStream follows the client's reads, so progress tracks the upload.
      streamed.sink.addStream(bytes.map((chunk) {
        sent += chunk.length;
        onProgress?.call(sent, total);
        return chunk;
      })).then((_) => streamed.sink.close(),
          onError: (Object e) => streamed.sink.close());
      req = streamed;
    } else {
      final r = http.AbortableRequest(method, uri, abortTrigger: abort?.future);
      if (body != null) {
        hdrs['Content-Type'] = 'application/json';
        r.body = jsonEncode(body);
      }
      req = r;
    }
    req.headers.addAll(hdrs);

    final http.Response res;
    try {
      if (cancel?.isCancelled ?? false) throw const CancelledException();
      final streamed = await _http.send(req);
      final bytes = await streamed.stream.toBytes();
      res = http.Response.bytes(bytes, streamed.statusCode,
          headers: streamed.headers, request: req);
    } on VaultbaseException {
      rethrow;
    } on http.RequestAbortedException {
      if (timedOut) throw const NetworkException('Request timed out');
      throw const CancelledException();
    } on Exception catch (e) {
      if (timedOut) throw const NetworkException('Request timed out');
      if (cancel?.isCancelled ?? false) throw const CancelledException();
      throw NetworkException(
          e is http.ClientException ? e.message : e.toString(),
          cause: e);
    } finally {
      timer?.cancel();
      if (key != null && keyToken != null) _cancels.release(key, keyToken);
    }
    // A client that can't abort still finishes the request; drop the answer.
    if (cancel?.isCancelled ?? false) throw const CancelledException();
    if (timedOut) throw const NetworkException('Request timed out');

    _captureEtag(uri.path, res);
    onResponse?.call(res);

    final data = _decode(res);
    final status = res.statusCode;
    if (status >= 200 && status < 300) return _unwrap(data);

    final message = _message(data);
    final code = data is Map ? data['code'] : null;
    switch (status) {
      case 429:
        final secs = double.tryParse(res.headers['retry-after'] ?? '') ?? 1;
        final ms = (secs * 1000).clamp(0, 10000).round();
        throw RateLimitException(Duration(milliseconds: ms),
            message: message ?? 'Too many requests',
            status: status,
            code: code,
            body: data);
      case 401:
        if (skipAuth) {
          throw AuthException(AuthFailure.invalid, message ?? 'Unauthorized',
              status: status, code: code, body: data);
        }
        if (!retried && !path.endsWith('/api/v1/auth/refresh')) {
          if (await refreshSession()) {
            return request(path,
                method: method,
                body: body,
                headers: headers,
                query: query,
                cancelToken: cancelToken,
                requestKey: requestKey,
                autoCancel: autoCancel,
                retried: true,
                multipart: multipart,
                onProgress: onProgress,
                onResponse: onResponse);
          }
        }
        // Refused with a token that was just refreshed: the session is fine,
        // this endpoint refuses the caller. Keep it.
        if (retried) {
          throw AuthException(AuthFailure.forbidden, message ?? 'Unauthorized',
              status: status, code: code, body: data);
        }
        authStore.clear();
        throw AuthException(AuthFailure.expired, message ?? 'Unauthorized',
            status: status, code: code, body: data);
      case 403:
        throw AuthException(AuthFailure.forbidden, message ?? 'Forbidden',
            status: status, code: code, body: data);
      case 422:
        final details = data is Map && data['details'] is Map
            ? {
                for (final e in (data['details'] as Map).entries)
                  '${e.key}': '${e.value}'
              }
            : const <String, String>{};
        throw ValidationException(message ?? 'Validation failed',
            details: details, status: status, code: code, body: data);
      case 409:
        throw ConflictException(message ?? 'Conflict',
            status: status, code: code, body: data);
      case 412:
        throw PreconditionFailedException(message ?? 'Precondition failed',
            currentEtag: res.headers['etag'],
            status: status,
            code: code,
            body: data);
      default:
        throw ServerException(message ?? 'HTTP $status',
            status: status, code: code, body: data);
    }
  }

  /// Refreshes the session once, however many callers ask at the same time.
  /// True when a new token was stored. A refused refresh clears the session;
  /// a network error throws and keeps it.
  Future<bool> refreshSession() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<bool> _refresh() async {
    final previous = authStore.current;
    if (previous == null || previous.token.isEmpty) return false;
    final Object? data;
    try {
      data = await request('/api/v1/auth/refresh',
          method: 'POST', skipRefresh: true, autoCancel: false);
    } on AuthException {
      authStore.clear();
      return false;
    }
    final token = data is Map ? data['token'] : null;
    if (token is! String || token.isEmpty) {
      authStore.clear();
      return false;
    }
    // Keep the record of the session that was refreshed, unless another
    // sign-in replaced it meanwhile.
    final now = authStore.current;
    authStore.save(StoredAuth(token, record: (now ?? previous).record));
    return true;
  }

  Future<void> _maybeRefresh() async {
    final token = authStore.token;
    if (token == null || token.isEmpty) return;
    final left = secondsUntilExpiry(token);
    if (left == null || left > _refreshLeadSeconds) return;
    try {
      await refreshSession();
    } on VaultbaseException {
      // Offline or the server is down: send the request with the current
      // token; a 401 retries the refresh.
    }
  }

  static final _recordPath = RegExp(r'^/api/(?:v\d+/)?([^/]+)/([^/]+)$');

  void _captureEtag(String path, http.Response res) {
    final etag = res.headers['etag'];
    if (etag == null) return;
    final m = _recordPath.firstMatch(path);
    if (m == null) return;
    etags.set(Uri.decodeComponent(m[1]!), Uri.decodeComponent(m[2]!), etag);
  }

  static Object? _decode(http.Response res) {
    final type = res.headers['content-type'] ?? '';
    if (res.bodyBytes.isEmpty) return null;
    if (type.contains('application/json')) {
      try {
        return jsonDecode(utf8.decode(res.bodyBytes));
      } on FormatException {
        return null;
      }
    }
    if (type.contains('text/')) return utf8.decode(res.bodyBytes);
    return null;
  }

  /// `{data: x}` (alone, or with error / code / details) is the envelope of
  /// single results; list pages carry more keys and are returned whole.
  static Object? _unwrap(Object? data) {
    if (data is Map && data.containsKey('data')) {
      const envelope = {'data', 'error', 'code', 'details'};
      if (data.keys.every(envelope.contains)) return data['data'];
    }
    return data;
  }

  static String? _message(Object? data) {
    if (data is Map && data['error'] is String) return data['error'] as String;
    return null;
  }
}
