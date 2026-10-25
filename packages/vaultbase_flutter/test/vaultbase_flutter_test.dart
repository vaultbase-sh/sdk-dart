import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:vaultbase_flutter/vaultbase_flutter.dart';

String jwt(int expiresIn) {
  String part(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + expiresIn;
  return '${part({'alg': 'none'})}.${part({'exp': exp, 'aud': 'users'})}.sig';
}

http.Response ok(Object? data) => http.Response(jsonEncode({'data': data}), 200,
    headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SecureAuthStore', () {
    test('restores the saved session and writes changes back', () async {
      final token = jwt(3600);
      FlutterSecureStorage.setMockInitialValues({
        defaultAuthKey: jsonEncode({
          'token': token,
          'record': {'id': 'u1'}
        }),
      });
      final store = SecureAuthStore();
      await store.ready;
      expect(store.token, token);
      expect(store.record?['id'], 'u1');

      final next = jwt(7200);
      store.save(StoredAuth(next));
      await store.flushed;
      const storage = FlutterSecureStorage();
      expect(jsonDecode((await storage.read(key: defaultAuthKey))!),
          {'token': next});

      store.clear();
      await store.flushed;
      expect(await storage.read(key: defaultAuthKey), isNull);
    });

    test('keys keep sessions apart', () async {
      FlutterSecureStorage.setMockInitialValues({
        'a': jsonEncode({'token': jwt(60)}),
      });
      final b = SecureAuthStore(key: 'b');
      await b.ready;
      expect(b.current, isNull);
    });
  });

  group('PrefsAuthStore', () {
    setUp(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    test('round-trips through shared preferences', () async {
      final token = jwt(3600);
      final first = PrefsAuthStore();
      await first.ready;
      expect(first.current, isNull);
      first.save(StoredAuth(token, record: const {'id': 'u1'}));
      await first.flushed;

      final second = PrefsAuthStore();
      await second.ready;
      expect(second.token, token);
      expect(second.record?['id'], 'u1');

      second.clear();
      await second.flushed;
      expect(await SharedPreferencesAsync().getString(defaultAuthKey), isNull);
    });
  });

  group('VaultbaseLifecycle', () {
    testWidgets(
        'closes realtime after a while in the background, reopens on '
        'resume', (tester) async {
      final vb = Vaultbase('http://127.0.0.1:9');
      final lifecycle = VaultbaseLifecycle(vb,
          pauseAfter: const Duration(seconds: 30), binding: tester.binding);
      final sub = vb.realtime.subscribe('posts', (_) {});

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 29));
      expect(vb.realtime.state, isNot(RealtimeState.paused));
      await tester.pump(const Duration(seconds: 2));
      expect(vb.realtime.state, RealtimeState.paused);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(vb.realtime.state, isNot(RealtimeState.paused));

      sub.cancel();
      lifecycle.dispose();
      vb.close();
    });

    testWidgets('a short trip to the background keeps the connection',
        (tester) async {
      final vb = Vaultbase('http://127.0.0.1:9');
      final lifecycle = VaultbaseLifecycle(vb, binding: tester.binding);
      final states = <RealtimeState>[];
      vb.realtime.states.listen(states.add);
      final sub = vb.realtime.subscribe('posts', (_) {});
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump(const Duration(seconds: 10));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(minutes: 1));
      expect(states, isNotEmpty);
      expect(states, isNot(contains(RealtimeState.paused)));
      sub.cancel();
      lifecycle.dispose();
      vb.close();
    });

    testWidgets('refreshes on resume only when the session expires soon',
        (tester) async {
      final refreshed = <String>[];
      final fresh = jwt(7200);
      final vb =
          Vaultbase('https://vb.test', httpClient: MockClient((req) async {
        refreshed.add(req.url.path);
        return ok({'token': fresh});
      }));
      final lifecycle = VaultbaseLifecycle(vb, binding: tester.binding);
      void resume() {
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      }

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);

      vb.authStore.save(StoredAuth(jwt(3600)));
      resume();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(refreshed, isEmpty);

      vb.authStore.save(StoredAuth(jwt(120)));
      resume();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(refreshed, ['/api/v1/auth/refresh']);
      expect(vb.authStore.token, fresh);

      lifecycle.dispose();
      vb.close();
    });
  });

  group('signInWithOAuth2', () {
    Vaultbase server() =>
        Vaultbase('https://vb.test', httpClient: MockClient((req) async {
          if (req.url.path.endsWith('authorize')) {
            return ok({
              'authorize_url': 'https://provider.test/auth',
              'state': 's1',
              'state_secret': 'secret1',
              'pkce': 'server',
            });
          }
          final body = jsonDecode(req.body) as Map;
          expect(body['state_secret'], 'secret1');
          expect(body['code'], 'c1');
          return ok({
            'token': jwt(3600),
            'record': {'id': 'u1'}
          });
        }));

    test('opens the authorize URL and exchanges the redirect', () async {
      final vb = server();
      Uri? opened;
      String? scheme;
      final result = await vb.auth
          .collection('users')
          .signInWithOAuth2('github', redirectUri: 'com.example.app://oauth',
              browser: (url, s) async {
        opened = url;
        scheme = s;
        return 'com.example.app://oauth?code=c1&state=s1';
      });
      expect(opened?.host, 'provider.test');
      expect(scheme, 'com.example.app');
      expect(result, isA<SignedIn>());
      expect(vb.auth.isSignedIn, isTrue);
    });

    test('closing the browser is a cancellation', () async {
      final vb = server();
      await expectLater(
          vb.auth.collection('users').signInWithOAuth2('github',
              redirectUri: 'com.example.app://oauth',
              browser: (_, __) async =>
                  throw PlatformException(code: 'CANCELED')),
          throwsA(isA<CancelledException>()));
      expect(vb.auth.isSignedIn, isFalse);
    });
  });
}
