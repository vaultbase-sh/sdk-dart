import 'dart:async';
import 'dart:convert';

import 'jwt.dart';

/// A signed-in session: the token, and the user or admin record it belongs to.
class StoredAuth {
  const StoredAuth(this.token, {this.record});

  factory StoredAuth.fromJson(Map<String, dynamic> json) => StoredAuth(
        json['token'] as String,
        record: (json['record'] as Map?)?.cast<String, dynamic>(),
      );

  final String token;
  final Map<String, dynamic>? record;

  /// The token's audience: `"admin"` for an admin, otherwise the collection.
  String? get audience => decodeJwtPayload(token)?['aud'] as String?;

  bool get isAdmin => audience == 'admin';

  Map<String, dynamic> toJson() =>
      {'token': token, if (record != null) 'record': record};

  @override
  String toString() => 'StoredAuth(${jsonEncode(record)})';
}

/// Holds the session. Requests read [current] synchronously; [onChange]
/// emits every change (sign-in, refresh, sign-out).
///
/// Persistent stores (`vaultbase_flutter`) override [persist] to write the
/// session and complete [ready] once the saved one is loaded; await
/// [ready] before the first request.
abstract class AuthStore {
  StoredAuth? _current;
  final _changes = StreamController<StoredAuth?>.broadcast();

  StoredAuth? get current => _current;

  String? get token => _current?.token;

  Map<String, dynamic>? get record => _current?.record;

  /// True when there is a token that has not expired.
  bool get isValid {
    final t = token;
    if (t == null || t.isEmpty) return false;
    final left = secondsUntilExpiry(t);
    return left == null || left > 0;
  }

  Stream<StoredAuth?> get onChange => _changes.stream;

  /// Completes once the store holds its saved session (at once for memory).
  Future<void> get ready => Future.value();

  void save(StoredAuth? auth) {
    _current = auth;
    persist(auth);
    _changes.add(auth);
  }

  void clear() => save(null);

  /// Sets the session loaded from storage, without writing it back.
  void restore(StoredAuth? auth) {
    _current = auth;
    _changes.add(auth);
  }

  /// Writes the session to storage. Nothing for the memory store.
  void persist(StoredAuth? auth) {}
}

/// Keeps the session in memory only; it is gone when the app exits.
class MemoryAuthStore extends AuthStore {}

/// A store backed by async storage: [read] loads the saved session (a JSON
/// string, or null) once at construction, [write] saves each change (null
/// to delete).
///
/// Writes run one at a time in the order of the changes. A session saved
/// before the load finishes wins over the loaded one. Saved data that
/// doesn't parse is treated as no session.
class AsyncAuthStore extends AuthStore {
  AsyncAuthStore({
    required Future<String?> Function() read,
    required Future<void> Function(String? value) write,
  }) : _write = write {
    _ready = _load(read);
  }

  final Future<void> Function(String? value) _write;
  late final Future<void> _ready;
  bool _changed = false;
  Future<void> _writes = Future.value();

  @override
  Future<void> get ready => _ready;

  /// Completes once every change so far is written.
  Future<void> get flushed => _writes;

  Future<void> _load(Future<String?> Function() read) async {
    StoredAuth? saved;
    try {
      final raw = await read();
      if (raw != null && raw.isNotEmpty) {
        saved = StoredAuth.fromJson(
            (jsonDecode(raw) as Map).cast<String, dynamic>());
      }
    } on Object {
      saved = null;
    }
    if (!_changed && saved != null) restore(saved);
  }

  @override
  void persist(StoredAuth? auth) {
    _changed = true;
    final value = auth == null ? null : jsonEncode(auth.toJson());
    _writes = _writes.then((_) => _write(value)).catchError((Object _) {});
  }
}
