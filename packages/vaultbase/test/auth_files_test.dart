import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vaultbase/vaultbase.dart';

import 'helpers.dart';

({Vaultbase vb, List<http.Request> requests}) client(
    FutureOr<http.Response> Function(http.Request req) handler) {
  final requests = <http.Request>[];
  final vb = Vaultbase('https://vb.test', httpClient: MockClient((req) async {
    requests.add(req);
    return handler(req);
  }));
  return (vb: vb, requests: requests);
}

void main() {
  group('auth flows', () {
    test('login stores the session; MFA stores nothing', () async {
      final token = jwtExpiringIn(3600);
      final c = client((req) {
        final body = jsonDecode(req.body) as Map;
        return body['password'] == 'mfa'
            ? json({
                'data': {'mfa_required': true, 'mfa_token': 't1'}
              })
            : json({
                'data': {
                  'token': token,
                  'record': {'id': 'u1', 'email': 'a@b.c'}
                }
              });
      });
      final users = c.vb.auth.collection('users');
      final ok = await users.login('a@b.c', 'pw');
      expect(ok, isA<SignedIn>().having((s) => s.record.id, 'id', 'u1'));
      expect(c.vb.authStore.token, token);
      expect(c.requests.single.headers.containsKey('authorization'), isFalse);

      c.vb.authStore.clear();
      final mfa = await users.login('a@b.c', 'mfa');
      expect(mfa, isA<MfaRequired>().having((m) => m.mfaToken, 'token', 't1'));
      expect(c.vb.authStore.current, isNull);
      expect(c.requests.last.url.path, '/api/v1/auth/users/login');
    });

    test('register does not sign in', () async {
      final c = client((_) => json({
            'data': {'id': 'u1', 'email': 'a@b.c'}
          }));
      final user = await c.vb.auth
          .collection('users')
          .register('a@b.c', 'pw', data: {'name': 'Ann'});
      expect(user.id, 'u1');
      expect(c.vb.authStore.current, isNull);
      expect(jsonDecode(c.requests.single.body),
          {'name': 'Ann', 'email': 'a@b.c', 'password': 'pw'});
    });

    test('the OAuth state secret from authorize goes with the exchange',
        () async {
      final c = client((req) => req.url.path.endsWith('authorize')
          ? json({
              'data': {
                'authorize_url': 'https://provider.test/auth?x=1',
                'state': 's1',
                'state_secret': 'secret1',
                'pkce': 'server',
              }
            })
          : json({
              'data': {
                'token': jwtExpiringIn(60),
                'record': {'id': 'u1'}
              }
            }));
      final users = c.vb.auth.collection('users');
      final start = await users.oauth2Authorize('github', 'com.app://oauth',
          usePkce: true);
      expect(start.authorizeUrl.host, 'provider.test');
      expect(c.requests.first.url.queryParameters, {
        'provider': 'github',
        'redirectUri': 'com.app://oauth',
        'use_pkce': '1'
      });

      final result = await users.oauth2ExchangeRedirect('github',
          'com.app://oauth', Uri.parse('com.app://oauth?code=c1&state=s1'));
      expect(result, isA<SignedIn>());
      expect(jsonDecode(c.requests.last.body), {
        'provider': 'github',
        'code': 'c1',
        'redirectUri': 'com.app://oauth',
        'state': 's1',
        'state_secret': 'secret1',
      });
    });

    test('a provider error on the redirect throws without a request', () async {
      final c = client((_) => json({}));
      await expectLater(
          c.vb.auth.collection('users').oauth2ExchangeRedirect(
              'github',
              'x://y',
              Uri.parse('x://y?error=access_denied&error_description=Denied')),
          throwsA(isA<AuthException>()
              .having((e) => e.message, 'message', 'Denied')));
      expect(c.requests, isEmpty);
    });

    test('a merge prompt is returned, not stored', () async {
      final c = client((_) => json({
            'data': {
              'merge_required': true,
              'merge_token': 'm1',
              'email': 'a@b.c',
              'provider': 'google'
            }
          }));
      final r = await c.vb.auth
          .collection('users')
          .oauth2Exchange('google', 'c', 'x://y', 's', stateSecret: 'z');
      expect(r,
          isA<MergeRequired>().having((m) => m.provider, 'provider', 'google'));
      expect(c.vb.authStore.current, isNull);
    });

    test('admin login stores the admin; impersonate stores nothing', () async {
      final adminToken = jwtExpiringIn(3600, aud: 'admin');
      final c = client((req) => req.url.path.endsWith('login')
          ? json({
              'data': {
                'token': adminToken,
                'admin': {'id': 'a1', 'email': 'admin@x'}
              }
            })
          : json({
              'data': {
                'token': jwtExpiringIn(60),
                'record': {'id': 'u1'},
                'impersonated_by': 'a1'
              }
            }));
      await c.vb.auth.admin.login('admin@x', 'pw');
      expect(c.vb.authStore.current?.isAdmin, isTrue);
      expect(c.vb.authStore.record?['email'], 'admin@x');
      final imp = await c.vb.auth.admin.impersonate('users', 'u1');
      expect(imp.impersonatedBy, 'a1');
      expect(c.vb.authStore.token, adminToken);
    });

    test('native sign-in: a nonce, then the ID token with it', () async {
      final token = jwtExpiringIn(3600);
      final c = client((req) => req.url.path.endsWith('/nonce')
          ? json({
              'data': {'nonce': 'n1', 'expires_at': 1}
            })
          : json({
              'data': {
                'token': token,
                'record': {'id': 'u1'}
              }
            }));
      final users = c.vb.auth.collection('users');
      final nonce = await users.idTokenNonce('apple');
      expect(nonce, 'n1');
      expect(c.requests.first.url.path,
          '/api/v1/auth/users/oauth2/id-token/nonce');
      expect(jsonDecode(c.requests.first.body), {'provider': 'apple'});

      final result = await users.signInWithIdToken('apple', 'id.tok.en',
          nonce: nonce, name: '  Ann  ');
      expect(result, isA<SignedIn>());
      expect(c.vb.authStore.token, token);
      expect(c.requests.last.url.path, '/api/v1/auth/users/oauth2/id-token');
      expect(c.requests.last.headers.containsKey('authorization'), isFalse);
      expect(jsonDecode(c.requests.last.body), {
        'provider': 'apple',
        'id_token': 'id.tok.en',
        'nonce': 'n1',
        'name': 'Ann',
      });
    });

    test('native sign-in into an existing email returns the merge, unstored',
        () async {
      final c = client((_) => json({
            'data': {
              'merge_required': true,
              'merge_token': 'm1',
              'email': 'a@b.c',
              'provider': 'google'
            }
          }));
      final r =
          await c.vb.auth.collection('users').signInWithIdToken('google', 't');
      expect(r, isA<MergeRequired>());
      expect(c.vb.authStore.current, isNull);
      expect(jsonDecode(c.requests.single.body),
          {'provider': 'google', 'id_token': 't'});
    });

    test('confirming an email change signs out', () async {
      final c = client((_) => json({
            'data': {'changed': true, 'email': 'new@x'}
          }));
      c.vb.authStore.save(StoredAuth(jwtExpiringIn(60)));
      expect(await c.vb.auth.collection('users').confirmEmailChange('t', 'pw'),
          'new@x');
      expect(c.vb.authStore.current, isNull);
    });
  });

  group('files', () {
    test('URLs carry thumb, fit, format and quality', () {
      final vb = Vaultbase('https://vb.test');
      expect(vb.files.url('a b.png').toString(),
          'https://vb.test/api/v1/files/a%20b.png');
      expect(
          vb.files
              .url('a.png',
                  thumb: '200x100',
                  fit: ThumbFit.cover,
                  format: ImageFormat.webp,
                  quality: 80)
              .queryParameters,
          {'thumb': '200x100_cover', 'format': 'webp', 'quality': '80'});
      expect(
          vb.files
              .url('a.png', thumb: '200x0', fit: ThumbFit.contain)
              .queryParameters['thumb'],
          '200x0');
    });

    test('upload sends multipart, reports progress, returns a list', () async {
      final c = client((req) => json({
            'data': {
              'id': 'f1',
              'filename': 'stored.txt',
              'originalName': 'hello.txt',
              'size': 5,
              'mimeType': 'text/plain'
            }
          }));
      final progress = <int>[];
      int? total;
      final metas = await c.vb.files.upload('posts', 'r1', 'doc', [
        UploadFile.fromBytes('hello.txt', utf8.encode('hello'),
            contentType: 'text/plain')
      ], onProgress: (sent, t) {
        progress.add(sent);
        total = t;
      });
      expect(metas.single.filename, 'stored.txt');
      final req = c.requests.single;
      expect(req.url.path, '/api/v1/files/posts/r1/doc');
      expect(req.headers['content-type'],
          startsWith('multipart/form-data; boundary='));
      expect(req.body, contains('filename="hello.txt"'));
      expect(req.body, contains('hello'));
      expect(progress.last, total);
    });

    test('tokens are cached, except one-time ones and across sign-ins',
        () async {
      var n = 0;
      final c = client((req) {
        n++;
        final oneTime = req.url.path.contains('once');
        return json({
          'data': {
            'token': 'tok$n',
            'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
            'one_time': oneTime,
          }
        });
      });
      c.vb.authStore.save(StoredAuth(fakeJwt({'aud': 'users', 'id': 'u1'})));
      expect((await c.vb.files.token('c', 'r', 'f', 'a.png')).token, 'tok1');
      expect((await c.vb.files.token('c', 'r', 'f', 'a.png')).token, 'tok1');
      expect((await c.vb.files.token('c', 'r', 'f', 'once.png')).token, 'tok2');
      expect((await c.vb.files.token('c', 'r', 'f', 'once.png')).token, 'tok3');
      c.vb.authStore.save(StoredAuth(fakeJwt({'aud': 'users', 'id': 'u2'})));
      expect((await c.vb.files.token('c', 'r', 'f', 'a.png')).token, 'tok4');
      final url =
          await c.vb.files.urlWithToken('c', 'r', 'f', 'a.png', thumb: '10x10');
      expect(url.queryParameters, {'thumb': '10x10', 'token': 'tok4'});
    });
  });
}
