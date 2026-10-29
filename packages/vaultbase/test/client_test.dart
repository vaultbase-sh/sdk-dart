import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vaultbase/vaultbase.dart';

import 'helpers.dart';

typedef Handler = FutureOr<http.Response> Function(http.Request req);

/// A client whose requests go to [handler]; every request is recorded.
({Vaultbase vb, List<http.Request> requests}) client(Handler handler,
    {AuthStore? store, Duration? timeout, bool autoCancel = false}) {
  final requests = <http.Request>[];
  final vb = Vaultbase('https://vb.test/',
      authStore: store,
      timeout: timeout,
      autoCancel: autoCancel, httpClient: MockClient((req) async {
    requests.add(req);
    return handler(req);
  }));
  return (vb: vb, requests: requests);
}

MemoryAuthStore signedIn(String token) =>
    MemoryAuthStore()..save(StoredAuth(token, record: {'id': 'u1'}));

void main() {
  group('requests', () {
    test('strip the trailing slash, skip null query values', () {
      final vb = Vaultbase('https://vb.test///');
      expect(vb.baseUrl, 'https://vb.test');
      expect(vb.buildUrl('/api/x', {'a': 1, 'b': null}).toString(),
          'https://vb.test/api/x?a=1');
    });

    test('send the token, and JSON only with a body', () async {
      final c = client((_) => json({'data': <String, Object?>{}}),
          store: signedIn(jwtExpiringIn(3600)));
      await c.vb.send('/api/v1/x');
      await c.vb.send('/api/v1/x', method: 'POST', body: {'a': 1});
      expect(c.requests[0].headers['authorization'], startsWith('Bearer '));
      expect(c.requests[0].headers.containsKey('content-type'), isFalse);
      expect(
          c.requests[1].headers['content-type'], contains('application/json'));
      expect(jsonDecode(c.requests[1].body), {'a': 1});
    });

    test('unwrap the single-result envelope, not list pages', () async {
      final c = client((req) => req.url.path.endsWith('one')
          ? json({
              'data': {'id': 'r1'}
            })
          : json({
              'data': <Object?>[],
              'page': 1,
              'perPage': 20,
              'totalItems': 0,
              'totalPages': 0
            }));
      expect(await c.vb.send('/one'), {'id': 'r1'});
      expect((await c.vb.send('/list') as Map)['page'], 1);
    });
  });

  group('errors', () {
    Future<Object> errorFor(http.Response res) async {
      final c = client((_) => res, store: signedIn(jwtExpiringIn(3600)));
      try {
        await c.vb.send('/api/v1/x');
      } on VaultbaseException catch (e) {
        return e;
      }
      fail('no error');
    }

    test('422 keeps details and the server code', () async {
      final e = await errorFor(json({
        'error': 'Validation failed',
        'code': 422,
        'details': {'title': 'required'}
      }, status: 422)) as ValidationException;
      expect(e.details, {'title': 'required'});
      expect(e.code, 422);
      expect(e.message, 'Validation failed');
    });

    test('409, 412, 403, 500', () async {
      expect(await errorFor(json({'error': 'dup'}, status: 409)),
          isA<ConflictException>());
      final pre = await errorFor(
              json({'error': 'stale'}, status: 412, headers: {'etag': '"v2"'}))
          as PreconditionFailedException;
      expect(pre.currentEtag, '"v2"');
      final forbidden =
          await errorFor(json({'error': 'no'}, status: 403)) as AuthException;
      expect(forbidden.reason, AuthFailure.forbidden);
      final server = await errorFor(json({'error': 'boom'}, status: 500))
          as ServerException;
      expect(server.status, 500);
      expect(server.message, 'boom');
    });

    test('429 reads Retry-After, capped at 10 s', () async {
      final e =
          await errorFor(json({}, status: 429, headers: {'retry-after': '60'}))
              as RateLimitException;
      expect(e.retryAfter, const Duration(seconds: 10));
      final short =
          await errorFor(json({}, status: 429, headers: {'retry-after': '0.5'}))
              as RateLimitException;
      expect(short.retryAfter, const Duration(milliseconds: 500));
    });

    test('network failures are NetworkException', () async {
      final c = client((_) => throw http.ClientException('connection refused'));
      await expectLater(c.vb.send('/x'), throwsA(isA<NetworkException>()));
    });
  });

  group('session', () {
    test('a 401 refreshes once and retries with the new token', () async {
      final fresh = jwtExpiringIn(7200);
      final store = signedIn(jwtExpiringIn(3600));
      var calls = 0;
      final c = client((req) {
        if (req.url.path == '/api/v1/auth/refresh') {
          return json({
            'data': {'token': fresh}
          });
        }
        calls++;
        return calls == 1
            ? json({'error': 'expired'}, status: 401)
            : json({
                'data': {'ok': true}
              });
      }, store: store);
      expect(await c.vb.send('/api/v1/x'), {'ok': true});
      expect(c.requests.last.headers['authorization'], 'Bearer $fresh');
      expect(store.token, fresh);
      expect(store.record, {'id': 'u1'});
    });

    test('a refused refresh clears the session', () async {
      final store = signedIn(jwtExpiringIn(3600));
      final c =
          client((_) => json({'error': 'nope'}, status: 401), store: store);
      await expectLater(
          c.vb.send('/api/v1/x'),
          throwsA(isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.expired)));
      expect(store.current, isNull);
    });

    test('a 401 after a successful refresh keeps the session', () async {
      final store = signedIn(jwtExpiringIn(3600));
      final c = client(
          (req) => req.url.path == '/api/v1/auth/refresh'
              ? json({
                  'data': {'token': jwtExpiringIn(3600)}
                })
              : json({'error': 'guests not allowed'}, status: 401),
          store: store);
      await expectLater(
          c.vb.send('/api/v1/x'),
          throwsA(isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.forbidden)));
      expect(store.current, isNotNull);
      expect(c.requests.where((r) => r.url.path == '/api/v1/auth/refresh'),
          hasLength(1));
    });

    test('a 401 on a request sent without the session keeps it', () async {
      final store = signedIn(jwtExpiringIn(3600));
      final c = client((_) => json({'error': 'bad password'}, status: 401),
          store: store);
      await expectLater(
          c.vb.send('/login', method: 'POST', skipAuth: true),
          throwsA(isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.invalid)));
      expect(store.current, isNotNull);
      expect(c.requests, hasLength(1));
    });

    test(
        'a token close to expiry is refreshed first, once for concurrent requests',
        () async {
      final fresh = jwtExpiringIn(7200);
      final store = signedIn(jwtExpiringIn(30));
      final c = client((req) async {
        if (req.url.path == '/api/v1/auth/refresh') {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return json({
            'data': {'token': fresh}
          });
        }
        return json({'data': <String, Object?>{}});
      }, store: store);
      await Future.wait([c.vb.send('/a'), c.vb.send('/b'), c.vb.send('/c')]);
      expect(c.requests.where((r) => r.url.path == '/api/v1/auth/refresh'),
          hasLength(1));
      for (final r
          in c.requests.where((r) => r.url.path != '/api/v1/auth/refresh')) {
        expect(r.headers['authorization'], 'Bearer $fresh');
      }
    });

    test('an offline refresh keeps the session', () async {
      final old = jwtExpiringIn(30);
      final store = signedIn(old);
      final c = client((req) {
        if (req.url.path == '/api/v1/auth/refresh') {
          throw http.ClientException('offline');
        }
        return json({'data': <String, Object?>{}});
      }, store: store);
      await c.vb.send('/a');
      expect(store.token, old);
      expect(c.requests.last.headers['authorization'], 'Bearer $old');
    });

    test('auth.refresh stores the new token; logout clears even when offline',
        () async {
      final fresh = jwtExpiringIn(7200);
      final store = signedIn(jwtExpiringIn(3600));
      final c = client((req) {
        if (req.url.path == '/api/v1/auth/refresh') {
          return json({
            'data': {'token': fresh}
          });
        }
        throw http.ClientException('offline');
      }, store: store);
      expect(await c.vb.auth.refresh(), isTrue);
      expect(store.token, fresh);
      await c.vb.auth.logout();
      expect(store.current, isNull);
    });

    test('onChange emits sign-in and sign-out', () async {
      final store = MemoryAuthStore();
      final events = <StoredAuth?>[];
      final sub = store.onChange.listen(events.add);
      store.save(StoredAuth(jwtExpiringIn(60)));
      store.clear();
      await Future<void>.delayed(Duration.zero);
      expect(events.map((e) => e == null), [false, true]);
      await sub.cancel();
    });

    test('isValid looks at the token expiry', () {
      expect(signedIn(jwtExpiringIn(60)).isValid, isTrue);
      expect(signedIn(jwtExpiringIn(-1)).isValid, isFalse);
      expect(MemoryAuthStore().isValid, isFalse);
    });
  });

  group('cancellation', () {
    test('a cancelled token fails the request', () async {
      final c = client((_) => json({'data': <String, Object?>{}}));
      final token = CancelToken()..cancel();
      await expectLater(c.vb.send('/x', cancelToken: token),
          throwsA(isA<CancelledException>()));
      expect(c.requests, isEmpty);
    });

    test('a newer request with the same key cancels the older one', () async {
      final c = client((req) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return json({'data': req.url.query});
      });
      final first = c.vb.send('/search?q=a', requestKey: 'search');
      final second = c.vb.send('/search?q=ab', requestKey: 'search');
      await expectLater(first, throwsA(isA<CancelledException>()));
      expect(await second, 'q=ab');
    });

    test('autoCancel derives the key from method and path', () async {
      final c = client((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return json({'data': 1});
      }, autoCancel: true);
      final first = c.vb.send('/x');
      final second = c.vb.send('/x');
      await expectLater(first, throwsA(isA<CancelledException>()));
      expect(await second, 1);
    });

    test('a timeout is a NetworkException', () async {
      final c = client((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return json({'data': 1});
      }, timeout: const Duration(milliseconds: 20));
      await expectLater(c.vb.send('/x'), throwsA(isA<NetworkException>()));
    });
  });

  group('records', () {
    test('list sends its options; skipTotal as 1', () async {
      final c = client((_) => json({
            'data': <Object?>[],
            'page': 1,
            'perPage': 5,
            'totalItems': -1,
            'totalPages': -1
          }));
      await c.vb.collection('my posts').list(
          page: 2,
          perPage: 5,
          filter: 'a = 1',
          sort: '-created',
          expand: 'author',
          skipTotal: true);
      final url = c.requests.single.url;
      expect(url.path, '/api/v1/my%20posts');
      expect(url.queryParameters, {
        'page': '2',
        'perPage': '5',
        'filter': 'a = 1',
        'sort': '-created',
        'expand': 'author',
        'skipTotal': '1',
      });
    });

    test('iterate pages until a short page, measured by the server perPage',
        () async {
      final c = client((req) {
        final page = int.parse(req.url.queryParameters['page']!);
        final count = page < 3 ? 2 : 1;
        return json({
          'data': [
            for (var i = 0; i < count; i++) {'id': '$page-$i'}
          ],
          'page': page,
          'perPage': 2,
          'totalItems': -1,
          'totalPages': -1,
        });
      });
      final ids = await c.vb
          .collection('posts')
          .iterate(perPage: 1000, skipTotal: true)
          .map((r) => r.id)
          .toList();
      expect(ids, ['1-0', '1-1', '2-0', '2-1', '3-0']);
      expect(c.requests, hasLength(3));
    });

    test('the ETag from get is sent on update and dropped after delete',
        () async {
      final c = client((req) => req.method == 'DELETE'
          ? http.Response('', 204)
          : json({
              'data': {'id': 'r1'}
            }, headers: {
              'etag': '"v1"'
            }));
      final posts = c.vb.collection('posts');
      await posts.get('r1');
      await posts.update('r1', {'title': 'x'});
      await posts.update('r1', {'title': 'y'}, checkEtag: false);
      await posts.update('r1', {'title': 'z'}, ifMatch: '"mine"');
      await posts.delete('r1');
      expect(c.requests[1].headers['if-match'], '"v1"');
      expect(c.requests[2].headers.containsKey('if-match'), isFalse);
      expect(c.requests[3].headers['if-match'], '"mine"');
      expect(c.vb.etags.get('posts', 'r1'), isNull);
    });

    test('typed collections decode with fromJson', () async {
      final c = client((_) => json({
            'data': {'id': 'r1', 'title': 'Hi'}
          }));
      final title = await c.vb
          .collectionOf('posts', (m) => m['title'] as String)
          .get('r1');
      expect(title, 'Hi');
    });

    test('aggregate joins agg and groupBy', () async {
      final c = client((_) => json({
            'data': [
              {'status': 'a', 'count': 2}
            ]
          }));
      final rows = await c.vb
          .collection('posts')
          .aggregate(agg: ['count', 'avg(views)'], groupBy: ['status']);
      expect(rows.single['count'], 2);
      expect(c.requests.single.url.queryParameters['agg'], 'count,avg(views)');
      expect(c.requests.single.url.path, '/api/v1/posts/_aggregate');
    });

    test('singleton keeps its own ETag', () async {
      final c = client((_) => json({
            'data': {'id': 's'}
          }, headers: {
            'etag': '"s1"'
          }));
      final site = c.vb.singleton('site');
      await site.get();
      await site.update({'title': 'x'});
      expect(c.requests[1].method, 'PATCH');
      expect(c.requests[1].url.path, '/api/v1/site');
      expect(c.requests[1].headers['if-match'], '"s1"');
    });
  });

  group('batch', () {
    test('sends the operations in order and reads the results', () async {
      final c = client((_) => json({
            'data': [
              {
                'status': 200,
                'body': {
                  'data': {'id': 'n1'}
                }
              },
              {'status': 204, 'body': null},
            ]
          }));
      final batch = c.vb.batch()
        ..create('posts', {'title': 'a'})
        ..delete('posts', 'r1')
        ..list('posts', perPage: 5, skipTotal: true);
      final results = await batch.run();
      final sent = jsonDecode(c.requests.single.body) as Map;
      expect(sent['requests'], [
        {
          'method': 'POST',
          'url': '/api/v1/posts',
          'body': {'title': 'a'}
        },
        {'method': 'DELETE', 'url': '/api/v1/posts/r1'},
        {'method': 'GET', 'url': '/api/v1/posts?perPage=5&skipTotal=1'},
      ]);
      expect(results.first.record?.id, 'n1');
      expect(results[1].ok, isTrue);
    });

    test('get and list send expand, fields and exclude', () async {
      final c = client((_) => json({'data': <Object?>[]}));
      final batch = c.vb.batch()
        ..get('posts', 'p1', expand: 'author', exclude: 'body,meta')
        ..get('posts', 'p2')
        ..list('posts', exclude: 'body');
      await batch.run();
      final sent = jsonDecode(c.requests.single.body) as Map;
      final urls = [
        for (final r in sent['requests'] as List) (r as Map)['url']
      ];
      expect(urls, [
        '/api/v1/posts/p1?expand=author&exclude=body%2Cmeta',
        '/api/v1/posts/p2',
        '/api/v1/posts?exclude=body',
      ]);
    });

    test('empty sends nothing; over 100 throws before sending', () async {
      final c = client((_) => json({'data': <Object?>[]}));
      expect(await c.vb.batch().run(), isEmpty);
      final big = c.vb.batch();
      for (var i = 0; i < 101; i++) {
        big.delete('posts', '$i');
      }
      await expectLater(big.run(), throwsA(isA<ValidationException>()));
      expect(c.requests, isEmpty);
    });
  });

  test('custom routes go under /api/v1/custom', () async {
    final c = client((_) => json({'data': 'hi'}));
    expect(await c.vb.custom.post('/hello', body: {'a': 1}, query: {'x': 1}),
        'hi');
    expect(c.requests.single.url.toString(),
        'https://vb.test/api/v1/custom/hello?x=1');
  });
}
