import 'dart:async';
import 'dart:convert';

import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vaultbase/vaultbase.dart';

import 'helpers.dart';

void main() {
  group('AsyncAuthStore', () {
    test('loads the saved session once, then writes each change in order',
        () async {
      final token = jwtExpiringIn(3600);
      final writes = <String?>[];
      final store = AsyncAuthStore(
        read: () async => jsonEncode({
          'token': token,
          'record': {'id': 'u1'}
        }),
        write: (v) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          writes.add(v);
        },
      );
      expect(store.current, isNull);
      await store.ready;
      expect(store.token, token);
      expect(store.record?['id'], 'u1');
      expect(writes, isEmpty);

      final next = jwtExpiringIn(7200);
      store.save(StoredAuth(next));
      store.clear();
      await store.flushed;
      expect(writes, [
        jsonEncode({'token': next}),
        null
      ]);
    });

    test('a session saved before the load finishes wins', () async {
      final load = Completer<String?>();
      final store =
          AsyncAuthStore(read: () => load.future, write: (_) async {});
      final mine = jwtExpiringIn(3600);
      store.save(StoredAuth(mine));
      load.complete(jsonEncode({'token': jwtExpiringIn(60)}));
      await store.ready;
      expect(store.token, mine);
    });

    test('unreadable data and a failing read mean no session', () async {
      final garbled =
          AsyncAuthStore(read: () async => '{not json', write: (_) async {});
      await garbled.ready;
      expect(garbled.current, isNull);

      final failing = AsyncAuthStore(
          read: () async => throw StateError('keychain locked'),
          write: (_) async {});
      await failing.ready;
      expect(failing.current, isNull);
    });

    test('a failed write does not stop the next one', () async {
      var n = 0;
      final written = <String?>[];
      final store = AsyncAuthStore(
          read: () async => null,
          write: (v) async {
            if (n++ == 0) throw StateError('disk full');
            written.add(v);
          });
      store.save(StoredAuth(jwtExpiringIn(60)));
      store.clear();
      await store.flushed;
      expect(written, [null]);
    });

    test('the first request waits for the saved session', () async {
      final load = Completer<String?>();
      final token = jwtExpiringIn(3600);
      String? sent;
      final vb = Vaultbase('https://vb.test',
          authStore:
              AsyncAuthStore(read: () => load.future, write: (_) async {}),
          httpClient: MockClient((req) async {
        sent = req.headers['authorization'];
        return json({'data': <String, Object?>{}});
      }));
      final pending = vb.send('/api/v1/posts');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(sent, isNull);
      load.complete(jsonEncode({'token': token}));
      await pending;
      expect(sent, 'Bearer $token');
    });
  });
}
