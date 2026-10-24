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
