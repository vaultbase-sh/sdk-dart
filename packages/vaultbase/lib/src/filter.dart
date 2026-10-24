/// A field name or dotted path, inserted into a filter without quotes.
///
/// ```dart
/// vb.filter('{:f} = {:v}', {'f': Field('meta.color'), 'v': 'red'});
/// ```
class Field {
  Field(this.name) {
    if (!_identPath.hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'not a valid field name');
    }
  }

  final String name;

  static final _identPath =
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$');
}

final _placeholder = RegExp(r'\{:([A-Za-z_][A-Za-z0-9_]*)\}');

/// Builds a filter expression, inserting each `{:name}` from [params]
/// escaped for the server's filter grammar:
///
/// * `String` quoted, with `\` and `"` escaped
/// * `int`, `double` (finite), `BigInt` bare
/// * `bool` as `true` / `false`, `null` as `null`
/// * `DateTime` as a quoted ISO 8601 UTC string
/// * `Iterable` as `(a, b, c)`
/// * [Field] as a bare field name
///
/// Anything else, or a placeholder missing from [params], throws.
String buildFilter(String expression,
    [Map<String, Object?> params = const {}]) {
  return expression.replaceAllMapped(_placeholder, (m) {
    final key = m[1]!;
    if (!params.containsKey(key)) {
      throw ArgumentError('filter: no value for {:$key}');
    }
    return _encode(params[key]);
  });
}

String _encode(Object? v) => switch (v) {
      null => 'null',
      String s => _quote(s),
      bool b => b ? 'true' : 'false',
      int i => '$i',
      BigInt i => '$i',
      double d when d.isFinite => '$d',
      double d => throw ArgumentError('filter: non-finite number ($d)'),
      DateTime d => _quote(_iso(d)),
      Field f => f.name,
      Iterable<Object?> list => '(${list.map(_encode).join(', ')})',
      _ =>
        throw ArgumentError('filter: unsupported value type ${v.runtimeType}'),
    };

String _quote(String s) =>
    '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// Millisecond precision, like JavaScript's `toISOString`.
String _iso(DateTime d) {
  final u = d.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final ms = u.millisecond.toString().padLeft(3, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}.${ms}Z';
}
