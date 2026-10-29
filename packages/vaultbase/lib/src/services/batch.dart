import '../client.dart';
import '../errors.dart';
import '../models.dart';
import 'collection.dart';

/// Several operations sent in one request and run in one transaction.
///
/// ```dart
/// final batch = vb.batch()
///   ..create('posts', {'title': 'One'})
///   ..delete('posts', oldId);
/// final results = await batch.run();
/// ```
class Batch {
  Batch(this._vb);

  /// The server's limit.
  static const maxOperations = 100;

  final Vaultbase _vb;
  final _ops = <Map<String, Object?>>[];

  int get length => _ops.length;

  Batch create(String collection, Map<String, dynamic> body) =>
      _add('POST', _path(collection), body);

  Batch update(String collection, String id, Map<String, dynamic> body) =>
      _add('PATCH', _path(collection, id), body);

  Batch delete(String collection, String id) =>
      _add('DELETE', _path(collection, id));

  /// [expand], [fields] and [exclude] as on `Collection.get` (server 0.31.0
  /// or later).
  Batch get(String collection, String id,
      {String? expand, String? fields, String? exclude}) {
    final query = {
      if (expand != null) 'expand': expand,
      if (fields != null) 'fields': fields,
      if (exclude != null) 'exclude': exclude,
    };
    final url = Uri(
        path: _path(collection, id),
        queryParameters: query.isEmpty ? null : query);
    return _add('GET', url.toString());
  }

  Batch list(
    String collection, {
    int? page,
    int? perPage,
    String? filter,
    String? sort,
    String? expand,
    String? fields,
    String? exclude,
    String? search,
    bool skipTotal = false,
  }) {
    final query = {
      for (final e in listQuery(
              page: page,
              perPage: perPage,
              filter: filter,
              sort: sort,
              expand: expand,
              fields: fields,
              exclude: exclude,
              search: search,
              skipTotal: skipTotal)
          .entries)
        if (e.value != null) e.key: '${e.value}',
    };
    final url = Uri(
        path: _path(collection), queryParameters: query.isEmpty ? null : query);
    return _add('GET', url.toString());
  }

  /// Sends the operations. Results are in the order they were added.
  Future<List<BatchResult>> run() async {
    if (_ops.isEmpty) return const [];
    if (_ops.length > maxOperations) {
      throw ValidationException('Batch exceeds $maxOperations operations',
          details: {'batch': 'Got ${_ops.length} operations'});
    }
    final data = await _vb
        .request('/api/v1/batch', method: 'POST', body: {'requests': _ops});
    return [
      for (final r in data as List)
        BatchResult.fromJson((r as Map).cast<String, dynamic>())
    ];
  }

  Batch _add(String method, String url, [Map<String, dynamic>? body]) {
    _ops.add({'method': method, 'url': url, if (body != null) 'body': body});
    return this;
  }

  static String _path(String collection, [String? id]) =>
      '/api/v1/${Uri.encodeComponent(collection)}'
      '${id == null ? '' : '/${Uri.encodeComponent(id)}'}';
}
