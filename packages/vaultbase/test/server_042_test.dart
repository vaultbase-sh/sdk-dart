import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vaultbase/vaultbase.dart';

import 'helpers.dart';

typedef Handler = FutureOr<http.Response> Function(http.Request req);

({Vaultbase vb, List<http.Request> requests, List<VaultbaseWarning> warnings})
    client(Handler handler, {AuthStore? store}) {
  final requests = <http.Request>[];
  final warnings = <VaultbaseWarning>[];
  final vb = Vaultbase('https://vb.test',
      authStore: store,
      onWarning: warnings.add,
      printWarnings: PrintWarnings.never, httpClient: MockClient((req) async {
    requests.add(req);
    return handler(req);
  }));
  return (vb: vb, requests: requests, warnings: warnings);
}

MemoryAuthStore signedIn(String token) =>
    MemoryAuthStore()..save(StoredAuth(token, record: {'id': 'u1'}));

http.Response forbidden(String reason, {String operation = 'create'}) => json({
      'error': 'Forbidden',
      'code': 403,
      'operation': operation,
      'reason': reason
    }, status: 403);

void main() {
  group('403 token_invalid', () {
    test('refreshes once and retries with the new token', () async {
      final old = jwtExpiringIn(3600);
      final fresh = jwtExpiringIn(7200);
      final store = signedIn(old);
      final c = client((req) {
        if (req.url.path == '/api/v1/auth/refresh') {
          return json({
            'data': {'token': fresh}
          });
        }
        return req.headers['authorization'] == 'Bearer $fresh'
            ? json({
                'data': {'id': 'p1'}
              })
            : forbidden('token_invalid');
      }, store: store);
      expect(await c.vb.send('/api/v1/posts', method: 'POST', body: {}),
          {'id': 'p1'});
      expect(c.requests.map((r) => r.url.path),
          ['/api/v1/posts', '/api/v1/auth/refresh', '/api/v1/posts']);
      expect(store.token, fresh);
    });

    test('a refused refresh clears the session and throws expired', () async {
      final store = signedIn(jwtExpiringIn(3600));
      final c = client(
          (req) => req.url.path == '/api/v1/auth/refresh'
              ? json({'error': 'Invalid token'}, status: 401)
              : forbidden('token_invalid'),
          store: store);
      final e = await c.vb.send('/api/v1/posts',
          method: 'POST',
          body: {}).then<Object?>((_) => null, onError: (Object e) => e);
      expect(
          e,
          isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.expired)
              .having((e) => e.status, 'status', 403)
              .having((e) => e.operation, 'operation', AuthOperation.create)
              .having((e) => e.serverReason, 'serverReason', 'token_invalid'));
      expect(store.current, isNull);
      expect(
          c.requests.where((r) => r.url.path == '/api/v1/posts'), hasLength(1));
    });

    test('refused again after a refresh keeps the session', () async {
      final store = signedIn(jwtExpiringIn(3600));
      final c = client(
          (req) => req.url.path == '/api/v1/auth/refresh'
              ? json({
                  'data': {'token': jwtExpiringIn(7200)}
                })
              : forbidden('token_invalid'),
          store: store);
      await expectLater(
          c.vb.send('/api/v1/posts'),
          throwsA(isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.forbidden)));
      expect(store.current, isNotNull);
      expect(c.requests.where((r) => r.url.path == '/api/v1/auth/refresh'),
          hasLength(1));
    });
  });

  group('403 reasons', () {
    test('not_signed_in is AuthFailure.notSignedIn', () async {
      final c = client((_) => forbidden('not_signed_in', operation: 'list'));
      await expectLater(
          c.vb.send('/api/v1/posts'),
          throwsA(isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.notSignedIn)
              .having((e) => e.operation, 'operation', AuthOperation.list)
              .having((e) => e.serverReason, 'serverReason', 'not_signed_in')
              .having((e) => e.status, 'status', 403)));
      expect(c.requests, hasLength(1));
    });

    test('rule_denied and a bare 403 stay forbidden, session kept', () async {
      final token = jwtExpiringIn(3600);
      final store = signedIn(token);
      final c = client(
          (req) => req.url.path.endsWith('/a')
              ? forbidden('rule_denied', operation: 'update')
              : json({'error': 'Forbidden'}, status: 403),
          store: store);
      await expectLater(
          c.vb.send('/api/v1/x/a'),
          throwsA(isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.forbidden)
              .having((e) => e.operation, 'operation', AuthOperation.update)
              .having((e) => e.serverReason, 'serverReason', 'rule_denied')));
      await expectLater(
          c.vb.send('/api/v1/x/b'),
          throwsA(isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.forbidden)
              .having((e) => e.operation, 'operation', isNull)
              .having((e) => e.serverReason, 'serverReason', isNull)));
      expect(store.token, token);
      expect(c.requests, hasLength(2));
    });
  });

  group('error classes', () {
    test('400 is ValidationException, 404 is NotFoundException', () async {
      final c = client((req) => req.url.path.endsWith('/bad')
          ? json({'error': 'Invalid filter: unknown field: titel', 'code': 400},
              status: 400)
          : json({'error': 'Collection not found', 'code': 404}, status: 404));
      await expectLater(
          c.vb.send('/api/v1/bad'),
          throwsA(isA<ValidationException>()
              .having((e) => e.status, 'status', 400)
              .having((e) => e.message, 'message',
                  'Invalid filter: unknown field: titel')
              .having((e) => e.details, 'details', isEmpty)));
      await expectLater(
          c.vb.send('/api/v1/missing'),
          throwsA(isA<NotFoundException>()
              .having((e) => e.status, 'status', 404)
              .having((e) => e.message, 'message', 'Collection not found')));
      // Still a ServerException for code that catches those.
      await expectLater(
          c.vb.send('/api/v1/missing'), throwsA(isA<ServerException>()));
    });

    test('registering a taken email is a ConflictException', () async {
      final c = client((_) => json(
          {'error': 'Email already registered', 'code': 409},
          status: 409));
      await expectLater(
          c.vb.auth.collection('users').register('a@b.co', 'longpassword1'),
          throwsA(isA<ConflictException>()
              .having((e) => e.status, 'status', 409)
              .having(
                  (e) => e.message, 'message', 'Email already registered')));
    });
  });

  group('pre-request refresh', () {
    test('a refused refresh throws expired without sending the request',
        () async {
      final store = signedIn(jwtExpiringIn(10));
      final c = client(
          (req) => req.url.path == '/api/v1/auth/refresh'
              ? json({'error': 'Invalid token'}, status: 401)
              : json({
                  'data': {'ok': true}
                }),
          store: store);
      await expectLater(
          c.vb.send('/api/v1/posts', method: 'POST', body: {}),
          throwsA(isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.expired)));
      expect(c.requests.map((r) => r.url.path), ['/api/v1/auth/refresh']);
      expect(store.current, isNull);
    });

    test('a refresh that can\'t be answered keeps the session', () async {
      final token = jwtExpiringIn(10);
      final store = signedIn(token);
      final c = client(
          (req) => req.url.path == '/api/v1/auth/refresh'
              ? json({'error': 'boom'}, status: 500)
              : json({
                  'data': {'ok': true}
                }),
          store: store);
      expect(await c.vb.send('/api/v1/posts'), {'ok': true});
      expect(c.requests.last.headers['authorization'], 'Bearer $token');
      expect(store.token, token);
    });
  });

  group('warnings', () {
    test('a Vaultbase-Warning header calls onWarning once per message',
        () async {
      final c = client((_) => json({
            'data': <Object?>[],
            'page': 1
          }, headers: {
            'vaultbase-warning':
                "unknown sort field 'titel' | unknown expand 'autor'"
          }));
      await c.vb.send('/api/v1/posts', query: {'sort': '-titel'});
      expect(c.warnings.map((w) => w.message),
          ["unknown sort field 'titel'", "unknown expand 'autor'"]);
      final w = c.warnings.first;
      expect(w.source, WarningSource.http);
      expect(w.method, 'GET');
      expect(w.path, '/api/v1/posts');
      expect(w.toString(), "GET /api/v1/posts: unknown sort field 'titel'");
    });

    test('an error response\'s warning is reported too', () async {
      final c = client((_) => json({'error': 'nope'},
          status: 422, headers: {'vaultbase-warning': 'x'}));
      await expectLater(c.vb.send('/api/v1/posts', method: 'POST', body: {}),
          throwsA(isA<ValidationException>()));
      expect(c.warnings.single.method, 'POST');
    });

    test('a throwing onWarning does not break the request', () async {
      final vb = Vaultbase('https://vb.test',
          onWarning: (_) => throw StateError('app bug'),
          printWarnings: PrintWarnings.never,
          httpClient: MockClient((_) async => json({
                'data': {'ok': true}
              }, headers: {
                'vaultbase-warning': 'x'
              })));
      expect(await vb.send('/api/v1/posts/1'), {'ok': true});
    });

    test('printWarnings: debug prints with asserts on, never does not',
        () async {
      final printed = <String>[];
      Future<void> run(PrintWarnings mode) => runZoned(
          () => Vaultbase('https://vb.test',
              printWarnings: mode,
              httpClient: MockClient((_) async => json({
                    'data': {'ok': true}
                  }, headers: {
                    'vaultbase-warning': "unknown expand 'autor'"
                  }))).send('/api/v1/posts/1'),
          zoneSpecification: ZoneSpecification(
              print: (_, __, ___, line) => printed.add(line)));
      await run(PrintWarnings.never);
      expect(printed, isEmpty);
      // `dart test` runs with assertions on, like a debug build.
      await run(PrintWarnings.debug);
      await run(PrintWarnings.always);
      expect(printed, [
        "[vaultbase] GET /api/v1/posts/1: unknown expand 'autor'",
        "[vaultbase] GET /api/v1/posts/1: unknown expand 'autor'",
      ]);
    });
  });
}
