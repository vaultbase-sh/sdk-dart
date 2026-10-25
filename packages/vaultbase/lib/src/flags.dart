import 'dart:async';
import 'dart:convert';

import 'client.dart';
import 'realtime.dart';

/// Feature flags, evaluated by the server for this client's context.
///
/// [connect] fetches every flag once and keeps them current: the server
/// pushes changes over the realtime connection (the one record
/// subscriptions use), a periodic refetch is the fallback, and the flags are fetched again after a sign-in or sign-out
/// and after a reconnect. Reads are synchronous from that cache.
///
/// The context is whatever the app sends; only `auth`, which the server
/// fills from the session, can be trusted by rules.
class Flags {
  Flags(this._vb);

  final Vaultbase _vb;

  Map<String, Object?> _values = const {};
  Map<String, Object?> _context = const {};
  final _changes = StreamController<Set<String>>.broadcast();
  RealtimeSubscription? _live;
  StreamSubscription<RealtimeState>? _stateWatch;
  StreamSubscription<Object?>? _authWatch;
  Timer? _poll;
  int _seq = 0;
  bool _connected = false;

  /// Fetches the flags and keeps them current until [disconnect].
  ///
  /// [context] is the targeting context (`{'plan': 'pro'}`). [live]
  /// subscribes to changes over realtime; [pollInterval] (at least 10 s,
  /// null for none) refetches as a fallback. Calling it again replaces the
  /// options.
  Future<void> connect({
    Map<String, Object?>? context,
    bool live = true,
    Duration? pollInterval = const Duration(seconds: 60),
  }) async {
    disconnect();
    _connected = true;
    if (context != null) _context = Map.unmodifiable(context);
    _authWatch = _vb.authStore.onChange.listen((_) => refresh());
    if (pollInterval != null) {
      final every = pollInterval < const Duration(seconds: 10)
          ? const Duration(seconds: 10)
          : pollInterval;
      _poll = Timer.periodic(every, (_) => refresh());
    }
    if (live) {
      _live = _vb.realtime.subscribeTopic('__flags', (m) {
        // The message only says something changed; the server evaluates
        // again for this context.
        if (m['type'] == 'flag_changed' || m['type'] == 'flag_deleted') {
          refresh();
        }
      });
      var opened = _vb.realtime.state == RealtimeState.open;
      _stateWatch = _vb.realtime.states.listen((s) {
        if (s != RealtimeState.open) return;
        // Changes made while the connection was down were never pushed.
        if (opened) refresh();
        opened = true;
      });
    }
    await refresh();
  }

  /// Replaces the targeting context and fetches the flags for it.
  Future<void> setContext(Map<String, Object?> context) {
    _context = Map.unmodifiable(context);
    return refresh();
  }

  /// Fetches the flags now. A failure keeps the last values.
  Future<void> refresh() async {
    final seq = ++_seq;
    final Object? data;
    try {
      data = await _vb.request('/api/v1/flags/evaluate',
          method: 'POST', body: {'context': _context}, autoCancel: false);
    } on Object {
      return;
    }
    // An older fetch that answers late doesn't overwrite a newer one.
    if (seq != _seq) return;
    final next =
        data is Map ? data.cast<String, Object?>() : <String, Object?>{};
    final changed = <String>{
      for (final k in {..._values.keys, ...next.keys})
        if (!_same(_values[k], next[k]) ||
            _values.containsKey(k) != next.containsKey(k))
          k,
    };
    _values = Map.unmodifiable(next);
    if (changed.isNotEmpty) _changes.add(changed);
  }

  /// The flag's value when it is a bool, otherwise [fallback].
  bool isEnabled(String key, {bool fallback = false}) {
    final v = _values[key];
    return v is bool ? v : fallback;
  }

  /// The flag's value when it is a string, otherwise [fallback].
  String getString(String key, String fallback) {
    final v = _values[key];
    return v is String ? v : fallback;
  }

  /// The flag's value when it is a number, otherwise [fallback].
  num getNumber(String key, num fallback) {
    final v = _values[key];
    return v is num ? v : fallback;
  }

  /// The flag's value when it is a [T] (a JSON map or list, say),
  /// otherwise [fallback].
  T getJson<T>(String key, T fallback) {
    final v = _values[key];
    return v is T ? v : fallback;
  }

  /// Every flag's value.
  Map<String, Object?> get all => _values;

  bool get isConnected => _connected;

  /// The keys whose values changed, after each fetch that changed any.
  Stream<Set<String>> get changes => _changes.stream;

  /// Stops following changes. The last values stay readable.
  void disconnect() {
    _connected = false;
    _poll?.cancel();
    _poll = null;
    _live?.cancel();
    _live = null;
    _stateWatch?.cancel();
    _stateWatch = null;
    _authWatch?.cancel();
    _authWatch = null;
  }

  static bool _same(Object? a, Object? b) {
    if (a == b) return true;
    if (a is! Map && a is! List) return false;
    if (b is! Map && b is! List) return false;
    return jsonEncode(a) == jsonEncode(b);
  }
}
