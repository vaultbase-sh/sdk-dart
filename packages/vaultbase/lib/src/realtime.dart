import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'client.dart';
import 'models.dart';

/// What happened to a record.
enum RealtimeAction { create, update, delete }

/// A change to a record, as realtime delivers it.
class RealtimeEvent {
  const RealtimeEvent(this.action, this.collection, this.id, this.record);

  final RealtimeAction action;
  final String collection;
  final String id;

  /// The record after the change; null for deletes.
  final RecordModel? record;

  @override
  String toString() => 'RealtimeEvent(${action.name} $collection/$id)';
}

/// The realtime connection's state.
enum RealtimeState {
  /// No subscriptions, so no connection.
  idle,
  connecting,
  open,

  /// The connection dropped; reconnecting with backoff.
  reconnecting,

  /// Paused by [Realtime.pause]; [Realtime.resume] reconnects.
  paused,
}

/// A live subscription. [cancel] it when done.
class RealtimeSubscription {
  RealtimeSubscription._(this._realtime, this._sub);

  final Realtime _realtime;
  final _Sub _sub;

  /// Completes when the server has confirmed the subscription; events
  /// from before then may be missed.
  Future<void> get ready => _sub.ready.future;

  void cancel() => _realtime._unsubscribe(_sub);
}

class _Sub {
  _Sub(this.collection, this.ids, this.onEvent);

  final String collection;

  /// Null for every record of the collection.
  final List<String>? ids;
  final void Function(RealtimeEvent) onEvent;
  final ready = Completer<void>();

  List<String> get topics =>
      ids == null ? [collection] : [for (final id in ids!) '$collection/$id'];
}

/// Record changes pushed over one WebSocket (`<baseUrl>/realtime`), shared
/// by every subscription of a client. It connects on the first subscription,
/// sends the session's token (and a new one after each refresh),
/// reconnects with backoff and subscribes again, and closes after the last
/// subscription is cancelled.
class Realtime {
  Realtime(this._vb);

  final Vaultbase _vb;

  static const _backoff = [250, 500, 1000, 2000, 5000, 10000];
  static const _heartbeat = Duration(seconds: 30);
  static const _connectTimeout = Duration(seconds: 5);

  final _subs = <_Sub>[];
  final _topicRefs = <String, int>{};
  final _states = StreamController<RealtimeState>.broadcast();
  final _random = Random();

  RealtimeState _state = RealtimeState.idle;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _messages;
  StreamSubscription<Object?>? _authWatch;
  Timer? _ping;
  Timer? _retry;
  int _attempt = 0;
  String? _sentToken;

  /// Bumped on every disconnect, so callbacks of an old connection can tell
  /// they are stale.
  int _generation = 0;

  RealtimeState get state => _state;

  Stream<RealtimeState> get states => _states.stream;

  /// Calls [onEvent] for changes to records of [collection] (`'*'` for every
  /// collection), or only to the records in [ids].
  RealtimeSubscription subscribe(
      String collection, void Function(RealtimeEvent) onEvent,
      {List<String>? ids}) {
    final sub =
        _Sub(collection, ids == null ? null : List.unmodifiable(ids), onEvent);
    _subs.add(sub);
    final added = <String>[];
    for (final t in sub.topics) {
      final n = (_topicRefs[t] ?? 0) + 1;
      _topicRefs[t] = n;
      if (n == 1) added.add(t);
    }
    _watchAuth();
    if (_state == RealtimeState.open) {
      if (added.isNotEmpty) _send({'type': 'subscribe', 'topics': added});
      // Every topic was already held: nothing to confirm.
      if (added.isEmpty) sub.ready.complete();
    } else if (_state == RealtimeState.idle) {
      _connect();
    }
    return RealtimeSubscription._(this, sub);
  }

  /// [subscribe] as a stream: subscribes on listen, cancels on cancel.
  Stream<RealtimeEvent> events(String collection, {List<String>? ids}) {
    RealtimeSubscription? sub;
    late final StreamController<RealtimeEvent> controller;
    controller = StreamController<RealtimeEvent>(
      onListen: () => sub = subscribe(collection, controller.add, ids: ids),
      onCancel: () => sub?.cancel(),
    );
    return controller.stream;
  }

  /// Drops the connection but keeps the subscriptions (an app going to the
  /// background). [resume] reconnects and subscribes again.
  void pause() {
    if (_subs.isEmpty) return;
    _disconnect();
    _setState(RealtimeState.paused);
  }

  void resume() {
    if (_state != RealtimeState.paused) return;
    _attempt = 0;
    _connect();
  }

  /// Cancels every subscription and closes the connection.
  void close() {
    _subs.clear();
    _topicRefs.clear();
    _authWatch?.cancel();
    _authWatch = null;
    _disconnect();
    _setState(RealtimeState.idle);
  }

  void _unsubscribe(_Sub sub) {
    if (!_subs.remove(sub)) return;
    // Another subscription may hold the same topic; the server only hears
    // about the ones nobody holds any more.
    final released = <String>[];
    for (final t in sub.topics) {
      final n = (_topicRefs[t] ?? 1) - 1;
      if (n <= 0) {
        _topicRefs.remove(t);
        released.add(t);
      } else {
        _topicRefs[t] = n;
      }
    }
    if (_subs.isEmpty) {
      close();
    } else if (released.isNotEmpty && _state == RealtimeState.open) {
      _send({'type': 'unsubscribe', 'topics': released});
    }
  }

  void _watchAuth() {
    _authWatch ??= _vb.authStore.onChange.listen((auth) {
      final token = auth?.token;
      if (token == _sentToken || _state != RealtimeState.open) return;
      if (token == null || token.isEmpty) {
        // The server keeps the old identity until its token expires;
        // reconnect to drop it now.
        _disconnect();
        _connect();
      } else {
        _sentToken = token;
        _send({'type': 'auth', 'token': token});
      }
    });
  }

  Future<void> _connect() async {
    if (_subs.isEmpty) return;
    final gen = ++_generation;
    _setState(
        _attempt == 0 ? RealtimeState.connecting : RealtimeState.reconnecting);
    await _vb.authStore.ready;
    if (gen != _generation || _subs.isEmpty) return;
    final base = Uri.parse(_vb.baseUrl);
    final uri = base.replace(
        scheme: base.scheme == 'https' ? 'wss' : 'ws',
        path: '${base.path}/realtime');
    final WebSocketChannel channel;
    try {
      channel = WebSocketChannel.connect(uri);
      await channel.ready.timeout(_connectTimeout);
    } on Object {
      if (gen == _generation) _scheduleReconnect();
      return;
    }
    if (gen != _generation || _subs.isEmpty) {
      channel.sink.close();
      return;
    }
    _channel = channel;
    _attempt = 0;
    _messages = channel.stream.listen(
      (m) => _onMessage(m),
      onDone: () => _onDropped(gen),
      onError: (Object _) => _onDropped(gen),
      cancelOnError: true,
    );
    final token = _vb.authStore.token;
    _sentToken = token;
    if (token != null && token.isNotEmpty) {
      _send({'type': 'auth', 'token': token});
    }
    if (_topicRefs.isNotEmpty) {
      _send({'type': 'subscribe', 'topics': _topicRefs.keys.toList()});
    }
    _ping = Timer.periodic(_heartbeat, (_) => _send({'type': 'ping'}));
    _setState(RealtimeState.open);
  }

  void _onDropped(int gen) {
    if (gen != _generation) return;
    _disconnect();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_subs.isEmpty || _state == RealtimeState.paused) return;
    final base = _backoff[min(_attempt, _backoff.length - 1)];
    final delay = (base * (0.8 + _random.nextDouble() * 0.4)).round();
    _attempt++;
    _setState(RealtimeState.reconnecting);
    _retry?.cancel();
    _retry = Timer(Duration(milliseconds: delay), _connect);
  }

  void _disconnect() {
    _generation++;
    _retry?.cancel();
    _retry = null;
    _ping?.cancel();
    _ping = null;
    _messages?.cancel();
    _messages = null;
    _channel?.sink.close();
    _channel = null;
    _sentToken = null;
  }

  void _send(Map<String, Object?> message) {
    try {
      _channel?.sink.add(jsonEncode(message));
    } on Object {
      // Closed; the reconnect sends the state again.
    }
  }

  void _onMessage(dynamic raw) {
    final Object? m;
    try {
      m = jsonDecode(raw is String ? raw : utf8.decode(raw as List<int>));
    } on Object {
      return;
    }
    if (m is! Map) return;
    switch (m['type']) {
      case 'subscribed':
        final topics = {
          for (final t in (m['topics'] as List? ?? const [])) '$t'
        };
        for (final s in _subs) {
          if (!s.ready.isCompleted && s.topics.every(topics.contains)) {
            s.ready.complete();
          }
        }
      case 'auth_expired':
        if (_vb.authStore.token?.isNotEmpty ?? false) {
          // The new token goes out through the auth watch.
          _vb.refreshSession().catchError((Object _) => false);
        }
      case 'create' || 'update' || 'delete':
        _deliver(m);
    }
  }

  /// The server sends each event once per connection, however many of its
  /// topics match, so there is nothing to de-duplicate.
  void _deliver(Map<dynamic, dynamic> m) {
    final collection = m['collection'];
    if (collection is! String) return;
    final action = RealtimeAction.values.byName(m['type'] as String);
    final recordJson = m['record'];
    final record = recordJson is Map
        ? RecordModel(recordJson.cast<String, dynamic>())
        : null;
    final id = (m['id'] as String?) ?? record?.id ?? '';
    final event = RealtimeEvent(action, collection, id,
        action == RealtimeAction.delete ? null : record);
    for (final s in List.of(_subs)) {
      if (s.collection != '*' && s.collection != collection) continue;
      if (s.ids != null && !s.ids!.contains(id)) continue;
      s.onEvent(event);
    }
  }

  void _setState(RealtimeState s) {
    if (s == _state) return;
    _state = s;
    _states.add(s);
  }
}
