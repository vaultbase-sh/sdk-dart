import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vaultbase/vaultbase.dart';

import 'helpers.dart';

void main() {
  late List<http.Request> requests;
  late FutureOr<http.Response> Function(http.Request) answer;
  late Vaultbase vb;

  setUp(() {
    requests = [];
    vb = Vaultbase('https://vb.test', httpClient: MockClient((req) async {
      requests.add(req);
      return answer(req);
    }));
  });

  tearDown(() => vb.close());

  test('typed reads, with fallbacks for missing or mistyped flags', () async {
    answer = (_) => json({
          'data': {
            'beta': true,
            'theme': 'dark',
            'limit': 25,
            'layout': {'cols': 3},
            'nothing': null,
          }
        });
    await vb.flags.connect(live: false, pollInterval: null);
    final f = vb.flags;
    expect(f.isEnabled('beta'), isTrue);
    expect(f.isEnabled('theme'), isFalse);
    expect(f.isEnabled('missing', fallback: true), isTrue);
    expect(f.getString('theme', 'light'), 'dark');
    expect(f.getString('limit', 'x'), 'x');
    expect(f.getNumber('limit', 10), 25);
    expect(f.getJson<Map<String, dynamic>>('layout', const {}), {'cols': 3});
    expect(f.getJson<List<Object?>>('layout', const []), isEmpty);
    expect(f.getJson<Object?>('nothing', 'fb'), isNull);
    expect(f.all.keys, hasLength(5));
    expect(requests.single.url.path, '/api/v1/flags/evaluate');
    expect(requests.single.method, 'POST');
  });

  test('changes names the keys that changed, and only those', () async {
    var values = <String, Object?>{
      'a': 1,
      'b': {'x': 1},
      'c': true
    };
    answer = (_) => json({'data': values});
    final seen = <Set<String>>[];
    vb.flags.changes.listen(seen.add);
    await vb.flags.connect(live: false, pollInterval: null);
    values = {
      'a': 1,
      'b': {'x': 1},
      'd': 'new'
    };
    await vb.flags.refresh();
    await vb.flags.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(seen, [
      {'a', 'b', 'c'},
      {'c', 'd'},
    ]);
  });

  test('the context goes with each fetch; setContext fetches again', () async {
    answer = (_) => json({'data': <String, Object?>{}});
    await vb.flags
        .connect(context: {'plan': 'free'}, live: false, pollInterval: null);
    await vb.flags.setContext({'plan': 'pro'});
    expect([
      for (final r in requests) jsonDecode(r.body)
    ], [
      {
        'context': {'plan': 'free'}
      },
      {
        'context': {'plan': 'pro'}
      },
    ]);
  });

  test('a failed fetch keeps the last values', () async {
    answer = (_) => json({
          'data': {'beta': true}
        });
    await vb.flags.connect(live: false, pollInterval: null);
    answer = (_) => json({'error': 'down'}, status: 503);
    await vb.flags.refresh();
    expect(vb.flags.isEnabled('beta'), isTrue);
  });

  test('a slow older fetch does not overwrite a newer one', () async {
    final slow = Completer<http.Response>();
    var n = 0;
    answer = (_) => n++ == 0
        ? slow.future
        : json({
            'data': {'v': 'new'}
          });
    final first = vb.flags.refresh();
    await vb.flags.refresh();
    slow.complete(json({
      'data': {'v': 'old'}
    }));
    await first;
    expect(vb.flags.getString('v', ''), 'new');
  });

  test('signing in or out fetches again; disconnect stops it', () async {
    answer = (_) => json({'data': <String, Object?>{}});
    await vb.flags.connect(live: false, pollInterval: null);
    vb.authStore.save(StoredAuth(jwtExpiringIn(3600)));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(requests, hasLength(2));
    expect(requests.last.headers['authorization'], startsWith('Bearer '));
    vb.flags.disconnect();
    vb.authStore.clear();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(requests, hasLength(2));
    expect(vb.flags.isConnected, isFalse);
  });
}
