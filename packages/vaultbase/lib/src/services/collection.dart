import '../cancel.dart';
import '../client.dart';
import '../models.dart';
import '../realtime.dart';

/// Records of one collection.
class Collection<T> {
  Collection(this._vb, this.name, this._decode);

  final Vaultbase _vb;
  final String name;
  final T Function(Map<String, dynamic>) _decode;

  String get _path => '/api/v1/${Uri.encodeComponent(name)}';

  String _recordPath(String id) => '$_path/${Uri.encodeComponent(id)}';

  /// One page of records. [filter], [sort], [expand] and [fields] use the
  /// server's syntax; build filters with values safely with `vb.filter`.
  /// [exclude] leaves fields out, after [fields]; `id` is always returned
  /// (server 0.31.0 or later).
  /// With [skipTotal] the server doesn't count, and the totals are -1.
  Future<ListResult<T>> list({
    int? page,
    int? perPage,
    String? filter,
    String? sort,
    String? expand,
    String? fields,
    String? exclude,
    String? search,
    bool skipTotal = false,
    CancelToken? cancelToken,
    String? requestKey,
  }) async {
    final data = await _vb.request(_path,
        query: listQuery(
            page: page,
            perPage: perPage,
            filter: filter,
            sort: sort,
            expand: expand,
            fields: fields,
            exclude: exclude,
            search: search,
            skipTotal: skipTotal),
        cancelToken: cancelToken,
        requestKey: requestKey);
    return ListResult.fromJson((data as Map).cast<String, dynamic>(), _decode);
  }

  /// Every record matching the filter, a page at a time.
  Stream<T> iterate({
    int perPage = 100,
    String? filter,
    String? sort,
    String? expand,
    String? fields,
    String? exclude,
    String? search,
    bool skipTotal = false,
    CancelToken? cancelToken,
  }) async* {
    var page = 1;
    while (true) {
      final res = await list(
          page: page,
          perPage: perPage,
          filter: filter,
          sort: sort,
          expand: expand,
          fields: fields,
          exclude: exclude,
          search: search,
          skipTotal: skipTotal,
          cancelToken: cancelToken);
      for (final item in res.items) {
        yield item;
      }
      // The server caps perPage and echoes the size it used; a short page is
      // measured against that.
      final size = res.perPage > 0 ? res.perPage : perPage;
      if (res.items.isEmpty || res.items.length < size) return;
      // totalPages is -1 with skipTotal: unknown, keep going.
      if (res.totalPages >= 0 && page >= res.totalPages) return;
      page++;
    }
  }

  /// One record. Its ETag is kept for [update] and [delete].
  Future<T> get(String id,
      {String? expand,
      String? fields,
      String? exclude,
      CancelToken? cancelToken,
      String? requestKey}) async {
    final data = await _vb.request(_recordPath(id),
        query: {'expand': expand, 'fields': fields, 'exclude': exclude},
        cancelToken: cancelToken,
        requestKey: requestKey);
    return _decode((data as Map).cast<String, dynamic>());
  }

  Future<T> create(Map<String, dynamic> body,
      {CancelToken? cancelToken}) async {
    final data = await _vb.request(_path,
        method: 'POST', body: body, cancelToken: cancelToken);
    return _decode((data as Map).cast<String, dynamic>());
  }

  /// Updates the fields in [body]. By default the ETag from the last read
  /// of this record is sent as `If-Match`, so a record changed meanwhile
  /// throws `PreconditionFailedException`; pass [ifMatch] to send a
  /// specific ETag, or `checkEtag: false` to send none.
  Future<T> update(String id, Map<String, dynamic> body,
      {String? ifMatch,
      bool checkEtag = true,
      CancelToken? cancelToken}) async {
    final data = await _vb.request(_recordPath(id),
        method: 'PATCH',
        body: body,
        headers: _ifMatch(id, ifMatch, checkEtag),
        cancelToken: cancelToken);
    return _decode((data as Map).cast<String, dynamic>());
  }

  /// Deletes the record; `If-Match` works as in [update].
  Future<void> delete(String id,
      {String? ifMatch,
      bool checkEtag = true,
      CancelToken? cancelToken}) async {
    await _vb.request(_recordPath(id),
        method: 'DELETE',
        headers: _ifMatch(id, ifMatch, checkEtag),
        cancelToken: cancelToken);
    _vb.etags.remove(name, id);
  }

  /// `count`, `count(f)`, `sum(f)`, `avg(f)`, `min(f)`, `max(f)` over the records a list would return,
  /// optionally grouped: `aggregate(agg: ['count', 'avg(views)'],
  /// groupBy: ['status'])`.
  Future<List<Map<String, dynamic>>> aggregate({
    required List<String> agg,
    List<String>? groupBy,
    String? filter,
    String? search,
    String? sort,
    int? limit,
    CancelToken? cancelToken,
    String? requestKey,
  }) async {
    final data = await _vb.request('$_path/_aggregate',
        query: {
          'agg': agg.join(','),
          'groupBy': groupBy?.join(','),
          'filter': filter,
          'search': search,
          'sort': sort,
          'limit': limit,
        },
        cancelToken: cancelToken,
        requestKey: requestKey);
    return [
      for (final row in data as List) (row as Map).cast<String, dynamic>()
    ];
  }

  /// Calls [onEvent] for changes to this collection's records, or only to
  /// the records in [ids]. See [Realtime.subscribe].
  RealtimeSubscription subscribe(void Function(RealtimeEvent) onEvent,
          {List<String>? ids}) =>
      _vb.realtime.subscribe(name, onEvent, ids: ids);

  /// [subscribe] as a stream.
  Stream<RealtimeEvent> events({List<String>? ids}) =>
      _vb.realtime.events(name, ids: ids);

  Map<String, String>? _ifMatch(String id, String? explicit, bool check) {
    if (!check) return null;
    final etag = explicit ?? _vb.etags.get(name, id);
    return etag == null ? null : {'If-Match': etag};
  }
}

/// The query of a list request; shared with batch.
Map<String, Object?> listQuery({
  int? page,
  int? perPage,
  String? filter,
  String? sort,
  String? expand,
  String? fields,
  String? exclude,
  String? search,
  bool skipTotal = false,
}) =>
    {
      'page': page,
      'perPage': perPage,
      'filter': filter,
      'sort': sort,
      'expand': expand,
      'fields': fields,
      'exclude': exclude,
      'search': search,
      'skipTotal': skipTotal ? '1' : null,
    };
