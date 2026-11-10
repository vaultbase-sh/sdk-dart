@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vaultbase/vaultbase.dart';

import 'helpers.dart';

/// A stand-in for the server's `/realtime` socket that records what clients
/// send and can push events or drop connections.
class FakeRealtimeServer {
  FakeRealtimeServer._(this._server) {
    _server.listen((req) async {
      if (req.uri.path != '/realtime') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      opened++;
      connections.add(ws);
      final refusal = refuse;
      if (refusal != null) {
        ws.add(jsonEncode(refusal));
        await ws.close();
        return;
      }
      sockets.add(ws);
      ws.add(jsonEncode({'type': 'connected'}));
      ws.listen((raw) {
        final m = jsonDecode(raw as String) as Map<String, dynamic>;
        received.add(m);
        if (confirm &&
            (m['type'] == 'subscribe' || m['type'] == 'unsubscribe')) {
          ws.add(jsonEncode({'type': '${m['type']}d', 'topics': m['topics']}));
        }
      });
    });
  }

  static Future<FakeRealtimeServer> start() async => FakeRealtimeServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final sockets = <WebSocket>[];
  final connections = StreamController<WebSocket>.broadcast();
  final received = <Map<String, dynamic>>[];

  /// Connections accepted so far.
  var opened = 0;

  /// When set, each connection gets this message and is closed at once.
  Map<String, Object?>? refuse;

  /// Whether subscribe and unsubscribe are answered.
  var confirm = true;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  void push(Map<String, Object?> event) {
    for (final s in sockets) {
      if (s.readyState == WebSocket.open) s.add(jsonEncode(event));
    }
  }

  Future<void> dropAll() async {
    for (final s in sockets) {
      await s.close();
    }
    sockets.clear();
  }

  Future<void> close() => _server.close(force: true);

  Future<Map<String, dynamic>> next(String type) async {
    for (var i = 0; i < 200; i++) {
      final hit = received.where((m) => m['type'] == type).toList();
      if (hit.isNotEmpty) {
        received.remove(hit.first);
        return hit.first;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('no $type message');
  }
}

void main() {
  late FakeRealtimeServer server;
  late Vaultbase vb;

  setUp(() async {
    server = await FakeRealtimeServer.start();
    vb = Vaultbase(server.baseUrl);
  });

  tearDown(() async {
    vb.close();
    await server.close();
  });

  test('subscribes, sends the token, delivers matching events', () async {
    final token = jwtExpiringIn(3600);
    vb.authStore.save(StoredAuth(token));
    final all = <RealtimeEvent>[];
    final one = <RealtimeEvent>[];
    final a = vb.collection('posts').subscribe(all.add);
    final b = vb.collection('posts').subscribe(one.add, ids: ['r1']);
    await a.ready;
    await b.ready;
    expect((await server.next('auth'))['token'], token);

    server.push({
      'type': 'create',
      'collection': 'posts',
      'record': {'id': 'r1', 'title': 'x'}
    });
    server.push({
      'type': 'update',
      'collection': 'posts',
      'record': {'id': 'r2'}
    });
    server.push({'type': 'delete', 'collection': 'posts', 'id': 'r1'});
    server.push({
      'type': 'create',
      'collection': 'other',
      'record': {'id': 'r1'}
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(all.map((e) => '${e.action.name}:${e.id}'),
        ['create:r1', 'update:r2', 'delete:r1']);
    expect(all.first.record?.getString('title'), 'x');
    expect(all.last.record, isNull);
    expect(
        one.map((e) => '${e.action.name}:${e.id}'), ['create:r1', 'delete:r1']);
  });

  test('a topic stays while another subscription holds it', () async {
    final a = vb.collection('posts').subscribe((_) {});
    final b = vb.collection('posts').subscribe((_) {});
    await a.ready;
    await b.ready;
    final c = vb.collection('posts').subscribe((_) {}, ids: ['r9']);
    await c.ready;
    a.cancel();
    c.cancel();
    final unsub = await server.next('unsubscribe');
    expect(unsub['topics'], ['posts/r9']);
    expect(vb.realtime.state, RealtimeState.open);
    b.cancel();
    expect(vb.realtime.state, RealtimeState.idle);
  });

  test('reconnects after a drop and subscribes again', () async {
    final states = <RealtimeState>[];
    vb.realtime.states.listen(states.add);
    final events = <RealtimeEvent>[];
    await vb.collection('posts').subscribe(events.add).ready;
    await server.next('subscribe');

    final reconnected = server.connections.stream.first;
    await server.dropAll();
    await reconnected.timeout(const Duration(seconds: 3));
    expect((await server.next('subscribe'))['topics'], ['posts']);
    server.push({
      'type': 'create',
      'collection': 'posts',
      'record': {'id': 'r1'}
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(events.single.id, 'r1');
    expect(
        states,
        containsAllInOrder([
          RealtimeState.open,
          RealtimeState.reconnecting,
          RealtimeState.open
        ]));
  });

  test('a server that closes at once is retried with growing delays', () async {
    server.refuse = {'type': 'error', 'reason': 'too_many_connections'};
    vb.collection('posts').subscribe((_) {});
    await Future<void>.delayed(const Duration(seconds: 2));
    // 250, 500, 1000 ms apart; without the backoff, ~250 ms apart.
    expect(server.opened, inInclusiveRange(2, 5));
  });

  test('a refused origin is not retried', () async {
    server.refuse = {'type': 'error', 'reason': 'origin_not_allowed'};
    final sub = vb.collection('posts').subscribe((_) {});
    await sub.ready.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(server.opened, 1);
    expect(vb.realtime.state, RealtimeState.idle);
  });

  test('ready completes on cancel and on close', () async {
    server.confirm = false;
    final a = vb.collection('posts').subscribe((_) {});
    final b = vb.collection('other').subscribe((_) {});
    await server.next('subscribe');
    a.cancel();
    await a.ready.timeout(const Duration(seconds: 1));
    vb.realtime.close();
    await b.ready.timeout(const Duration(seconds: 1));
  });

  test('a new token is sent on the open connection', () async {
    vb.authStore.save(StoredAuth(jwtExpiringIn(3600)));
    await vb.collection('posts').subscribe((_) {}).ready;
    await server.next('auth');
    final fresh = jwtExpiringIn(7200);
    vb.authStore.save(StoredAuth(fresh));
    expect((await server.next('auth'))['token'], fresh);
  });

  test('pause drops the connection; resume subscribes again', () async {
    await vb.collection('posts').subscribe((_) {}).ready;
    await server.next('subscribe');
    vb.realtime.pause();
    expect(vb.realtime.state, RealtimeState.paused);
    final again = server.connections.stream.first;
    vb.realtime.resume();
    await again.timeout(const Duration(seconds: 3));
    expect((await server.next('subscribe'))['topics'], ['posts']);
  });

  test('events() subscribes on listen and cancels on cancel', () async {
    final stream = vb.collection('posts').events();
    final first = stream.first;
    await server.next('subscribe');
    server.push({
      'type': 'create',
      'collection': 'posts',
      'record': {'id': 'r5'}
    });
    expect((await first).id, 'r5');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(vb.realtime.state, RealtimeState.idle);
  });

  test('a warning frame calls onWarning and is not an event', () async {
    final warnings = <VaultbaseWarning>[];
    final warned = Vaultbase(server.baseUrl,
        onWarning: warnings.add, printWarnings: PrintWarnings.never);
    addTearDown(warned.close);
    final events = <RealtimeEvent>[];
    final flags = <Map<String, dynamic>>[];
    final sub = warned.collection('postz').subscribe(events.add);
    warned.realtime.subscribeTopic('__flags', flags.add);
    await sub.ready;
    server.push({
      'type': 'warning',
      'reason': 'unknown_collection',
      'topic': '__flags',
      'message': "No collection named '__flags'",
    });
    server.push({
      'type': 'warning',
      'reason': 'unknown_collection',
      'topic': 'postz',
      'message': "No collection named 'postz': this subscription will never "
          'receive events.',
    });
    for (var i = 0; i < 100 && warnings.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(warnings, hasLength(1));
    final w = warnings.single;
    expect(w.source, WarningSource.realtime);
    expect(w.reason, 'unknown_collection');
    expect(w.topic, 'postz');
    expect(w.message, startsWith("No collection named 'postz'"));
    expect(events, isEmpty);
    expect(flags, isEmpty);
  });
}
