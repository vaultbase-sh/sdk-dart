/// Where a server warning came from.
enum WarningSource {
  /// A `Vaultbase-Warning` response header (servers 0.42 and 0.43).
  http,

  /// A realtime `warning` frame.
  realtime,
}

/// When the client prints server warnings.
enum PrintWarnings {
  /// When assertions are on: `dart run`, `dart test`, a Flutter debug
  /// build. Not in a release build or a compiled executable.
  debug,

  /// Always.
  always,

  /// Never; `onWarning` still gets them.
  never,
}

/// A warning the server sent (server 0.42+): a request that works but
/// probably doesn't do what was meant, such as a realtime subscription to a
/// collection that doesn't exist. Servers 0.42 and 0.43 also warn about a
/// sort field, expand, `fields` name or body key that doesn't exist; from
/// 0.44 those requests throw a `ValidationException` instead.
class VaultbaseWarning {
  const VaultbaseWarning(this.source, this.message,
      {this.method, this.path, this.reason, this.topic});

  final WarningSource source;
  final String message;

  /// [WarningSource.http]: the request's method and path.
  final String? method;
  final String? path;

  /// [WarningSource.realtime]: the frame's reason (`unknown_collection`)
  /// and topic.
  final String? reason;
  final String? topic;

  @override
  String toString() => source == WarningSource.realtime
      ? 'realtime: $message'
      : '${method ?? 'GET'} ${path ?? ''}: $message';
}
