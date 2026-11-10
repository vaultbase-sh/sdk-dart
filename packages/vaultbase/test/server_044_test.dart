import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vaultbase/vaultbase.dart';

import 'helpers.dart';

typedef Handler = FutureOr<http.Response> Function(http.Request req);

({Vaultbase vb, List<http.Request> requests}) client(Handler handler,
    {AuthStore? store, Map<String, String> headers = const {}}) {
  final requests = <http.Request>[];
  final vb = Vaultbase('https://vb.test',
      authStore: store,
      headers: headers,
      printWarnings: PrintWarnings.never, httpClient: MockClient((req) async {
    requests.add(req);
    return handler(req);
  }));
  return (vb: vb, requests: requests);
}

MemoryAuthStore signedIn(String token) =>
    MemoryAuthStore()..save(StoredAuth(token, record: {'id': 'u1'}));

const refresh = '/api/v1/auth/refresh';

/// The 401 of server 0.44 for a Bearer token it doesn't accept, or with
/// [scope] for an API token without the scope for the request.
http.Response tokenInvalid({bool scope = false}) => json({
      'error': scope
          ? "This API token doesn't have the scope for this request"
          : 'Token expired or invalid',
      'code': 401,
      'reason': scope ? 'insufficient_scope' : 'token_invalid'
    }, status: 401);

/// An API token as the server hands it out.
String apiToken({int expiresIn = 3600}) =>
    'vbat_${jwtExpiringIn(expiresIn, aud: 'api')}';

Future<Object?> errorOf(Future<Object?> f) =>
    f.then<Object?>((_) => null, onError: (Object e) => e);

int count(List<http.Request> requests, String path) =>
    requests.where((r) => r.url.path == path).length;

void main() {
  group('401 token_invalid', () {
    test('refreshes once and retries with the new token', () async {
      final fresh = jwtExpiringIn(7200);
      final store = signedIn(jwtExpiringIn(3600));
      final c = client((req) {
        if (req.url.path == refresh) {
          return json({
            'data': {'token': fresh}
          });
        }
        return req.headers['authorization'] == 'Bearer $fresh'
            ? json({
                'data': <Object?>[],
                'page': 1,
                'perPage': 30,
                'totalItems': 0,
                'totalPages': 0
              })
            : tokenInvalid();
      }, store: store);
      expect((await c.vb.collection('posts').list()).items, isEmpty);
      expect(c.requests.map((r) => r.url.path),
          ['/api/v1/posts', refresh, '/api/v1/posts']);
      expect(store.token, fresh);
    });

    test('a refused refresh clears the session and throws expired, once',
        () async {
      final store = signedIn(jwtExpiringIn(3600));
      final c = client((_) => tokenInvalid(), store: store);
      final e = await errorOf(c.vb.collection('posts').list());
      expect(
          e,
          isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.expired)
              .having((e) => e.status, 'status', 401)
              .having((e) => e.message, 'message', 'Token expired or invalid')
              .having((e) => e.serverReason, 'serverReason', 'token_invalid'));
      expect(store.current, isNull);
      expect(c.requests.map((r) => r.url.path), ['/api/v1/posts', refresh]);
      // The next request goes without the token.
      await errorOf(c.vb.collection('posts').list());
      expect(c.requests.last.headers.containsKey('authorization'), isFalse);
    });

    test('refused again after a refresh: forbidden, session kept, no loop',
        () async {
      final store = signedIn(jwtExpiringIn(3600));
      final c = client(
          (req) => req.url.path == refresh
              ? json({
                  'data': {'token': jwtExpiringIn(7200)}
                })
              : tokenInvalid(),
          store: store);
      final e = await errorOf(c.vb.collection('posts').create({'title': 'x'}));
      expect(
          e,
          isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.forbidden)
              .having((e) => e.serverReason, 'serverReason', 'token_invalid'));
      expect(store.current, isNotNull);
      expect(count(c.requests, refresh), 1);
      expect(count(c.requests, '/api/v1/posts'), 2);
    });

    test('files and batch requests refresh and retry too', () async {
      final fresh = jwtExpiringIn(7200);
      final store = signedIn(jwtExpiringIn(3600));
      final c = client((req) {
        if (req.url.path == refresh) {
          return json({
            'data': {'token': fresh}
          });
        }
        if (req.headers['authorization'] != 'Bearer $fresh') {
          return tokenInvalid();
        }
        return req.url.path == '/api/v1/batch'
            ? json({
                'data': [
                  {
                    'status': 200,
                    'body': {'id': 'p1'}
                  }
                ]
              })
            : json({
                'data': {'token': 'file-token', 'expires_at': 1900000000}
              });
      }, store: store);
      final results = await (c.vb.batch()..get('posts', 'p1')).run();
      expect(results.single.ok, isTrue);
      final t = await c.vb.files.token('posts', 'p1', 'cover', 'a.png');
      expect(t.token, 'file-token');
      // One refresh served both: the second request already had the token.
      expect(count(c.requests, refresh), 1);
    });
  });

  group('API token', () {
    test('without the scope: forbidden with the server\'s message, kept',
        () async {
      final token = apiToken();
      final store = signedIn(token);
      final c = client((_) => tokenInvalid(scope: true), store: store);
      final e = await errorOf(c.vb.collection('posts').create({'title': 'x'}));
      expect(
          e,
          isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.forbidden)
              .having((e) => e.status, 'status', 401)
              .having((e) => e.message, 'message',
                  "This API token doesn't have the scope for this request")
              .having(
                  (e) => e.serverReason, 'serverReason', 'insufficient_scope'));
      expect(store.token, token);
      expect(c.requests.map((r) => r.url.path), ['/api/v1/posts']);
    });

    test('the reason decides, not the message or the token\'s shape', () async {
      // insufficient_scope: forbidden and kept, whatever the token looks like.
      final session = jwtExpiringIn(3600);
      final store = signedIn(session);
      final c = client(
          (_) => json(
              {'error': 'No', 'code': 401, 'reason': 'insufficient_scope'},
              status: 401),
          store: store);
      expect(
          await errorOf(c.vb.collection('posts').create({})),
          isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.forbidden)
              .having((e) => e.message, 'message', 'No'));
      expect(store.token, session);
      expect(c.requests, hasLength(1));

      // token_invalid stays expired, even with "scope" in its message.
      final token = apiToken();
      final apiStore = signedIn(token);
      final d = client(
          (_) => json({
                'error': 'A token out of scope',
                'code': 401,
                'reason': 'token_invalid'
              }, status: 401),
          store: apiStore);
      expect(
          await errorOf(d.vb.collection('posts').create({})),
          isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.expired)
              .having((e) => e.serverReason, 'serverReason', 'token_invalid'));
      expect(apiStore.token, token);
      expect(d.requests, hasLength(1));
    });

    test('one the server no longer accepts: expired, kept, no refresh',
        () async {
      final token = apiToken();
      final store = signedIn(token);
      final c = client((_) => tokenInvalid(), store: store);
      final e = await errorOf(c.vb.collection('posts').list());
      expect(
          e,
          isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.expired)
              .having((e) => e.message, 'message', 'Token expired or invalid'));
      expect(store.token, token);
      expect(c.requests.map((r) => r.url.path), ['/api/v1/posts']);
    });

    test('set with the client\'s headers, or without the vbat_ prefix',
        () async {
      final token = apiToken();
      final byHeader = client((_) => tokenInvalid(scope: true),
          headers: {'authorization': 'Bearer $token'});
      expect(
          await errorOf(byHeader.vb.collection('posts').create({})),
          isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.forbidden));
      expect(byHeader.requests, hasLength(1));

      final bare = token.substring('vbat_'.length);
      final store = signedIn(bare);
      final c = client((_) => tokenInvalid(scope: true), store: store);
      expect(
          await errorOf(c.vb.collection('posts').create({})),
          isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.forbidden));
      expect(store.token, bare);
      expect(c.requests, hasLength(1));
    });

    test('is not refreshed before it expires, or by auth.refresh', () async {
      final token = apiToken(expiresIn: 20);
      final store = signedIn(token);
      final c = client(
          (req) => req.url.path == refresh
              ? json({'error': 'Unauthorized', 'code': 401}, status: 401)
              : json({
                  'data': {'id': 'p1'}
                }),
          store: store);
      expect((await c.vb.collection('posts').get('p1')).id, 'p1');
      expect(c.requests.single.headers['authorization'], 'Bearer $token');
      expect(await c.vb.auth.refresh(), isFalse);
      expect(count(c.requests, refresh), 0);
      expect(store.token, token);
    });

    test('a 403 token_invalid (servers 0.42 and 0.43) keeps it too', () async {
      final token = apiToken();
      final store = signedIn(token);
      final c = client(
          (_) => json({
                'error': 'Forbidden',
                'code': 403,
                'operation': 'create',
                'reason': 'token_invalid'
              }, status: 403),
          store: store);
      expect(
          await errorOf(c.vb.collection('posts').create({})),
          isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.expired)
              .having((e) => e.operation, 'operation', AuthOperation.create));
      expect(store.token, token);
      expect(c.requests, hasLength(1));
    });
  });

  group('400 unknown keys', () {
    test('a list: ValidationException with details by query parameter',
        () async {
      final c = client((_) => json({
            'error': "Unknown sort field 'titel'; unknown expand 'autor' "
                '(not a relation field)',
            'code': 400,
            'details': {
              'sort': "unknown sort field 'titel'",
              'expand': "unknown expand 'autor' (not a relation field)"
            }
          }, status: 400));
      final e = await errorOf(
          c.vb.collection('posts').list(sort: '-titel', expand: 'autor'));
      expect(
          e,
          isA<ValidationException>()
              .having((e) => e.status, 'status', 400)
              .having((e) => e.code, 'code', 400)
              .having((e) => e.message, 'message',
                  startsWith("Unknown sort field 'titel'"))
              .having((e) => e.details, 'details', {
            'sort': "unknown sort field 'titel'",
            'expand': "unknown expand 'autor' (not a relation field)"
          }));
    });

    test('a create or update: details by body key', () async {
      final c = client((_) => json({
            'error': "Unknown field 'colour' in body",
            'code': 400,
            'details': {'colour': "unknown field 'colour' in body"}
          }, status: 400));
      for (final call in [
        () => c.vb.collection('posts').create({'colour': 'red'}),
        () => c.vb.collection('posts').update('p1', {'colour': 'red'}),
        () => c.vb.singleton('site').update({'colour': 'red'}),
      ]) {
        expect(
            await errorOf(call()),
            isA<ValidationException>().having((e) => e.details, 'details',
                {'colour': "unknown field 'colour' in body"}));
      }
    });
  });

  group('what the client sends', () {
    test('no sort, expand or fields unless asked for', () async {
      final c = client((req) => req.url.pathSegments.length > 3
          ? json({
              'data': {'id': 'p1'}
            })
          : json({
              'data': <Object?>[],
              'page': 1,
              'perPage': 30,
              'totalItems': 0,
              'totalPages': 0
            }));
      await c.vb.collection('posts').list();
      await c.vb.collection('posts').get('p1');
      await c.vb.collection('posts').iterate().toList();
      await c.vb.singleton('site').get();
      expect(c.requests[0].url.query, isEmpty);
      expect(c.requests[1].url.query, isEmpty);
      expect(
          c.requests[2].url.queryParameters, {'page': '1', 'perPage': '100'});
      expect(c.requests[3].url.query, isEmpty);
    });

    test('create, update and batch bodies go as given', () async {
      final c = client((req) => req.url.path == '/api/v1/batch'
          ? json({'data': <Object?>[]})
          : json({
              'data': {'id': 'p1'}
            }));
      const body = {'title': 'Hello', 'views': 3};
      await c.vb.collection('posts').create(body);
      await c.vb.collection('posts').update('p1', body);
      await c.vb.singleton('site').update(body);
      await (c.vb.batch()
            ..create('posts', body)
            ..update('posts', 'p1', body)
            ..list('posts')
            ..get('posts', 'p1'))
          .run();
      for (final r in c.requests.take(3)) {
        expect(jsonDecode(r.body), body);
      }
      expect(jsonDecode(c.requests[3].body), {
        'requests': [
          {'method': 'POST', 'url': '/api/v1/posts', 'body': body},
          {'method': 'PATCH', 'url': '/api/v1/posts/p1', 'body': body},
          {'method': 'GET', 'url': '/api/v1/posts'},
          {'method': 'GET', 'url': '/api/v1/posts/p1'},
        ]
      });
    });
  });
}
