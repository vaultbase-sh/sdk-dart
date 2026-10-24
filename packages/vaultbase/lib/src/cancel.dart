import 'dart:async';

/// Cancels the requests it is passed to.
///
/// ```dart
/// final token = CancelToken();
/// vb.collection('posts').list(cancelToken: token);
/// token.cancel(); // the list throws CancelledException
/// ```
class CancelToken {
  CancelToken();

  /// A token that is cancelled as soon as any of [tokens] is.
  factory CancelToken.any(Iterable<CancelToken> tokens) {
    final combined = CancelToken();
    for (final t in tokens) {
      if (t.isCancelled) {
        combined.cancel();
        break;
      }
      t.whenCancelled.then((_) => combined.cancel());
    }
    return combined;
  }

  final _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;

  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// One live token per request key: a new request with the key cancels the
/// previous one.
class CancelRegistry {
  final _tokens = <String, CancelToken>{};

  CancelToken acquire(String key) {
    _tokens[key]?.cancel();
    return _tokens[key] = CancelToken();
  }

  void release(String key, CancelToken token) {
    if (identical(_tokens[key], token)) _tokens.remove(key);
  }

  void cancelAll() {
    for (final t in _tokens.values) {
      t.cancel();
    }
    _tokens.clear();
  }
}
