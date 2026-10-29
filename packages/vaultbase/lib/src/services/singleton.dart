import 'package:http/http.dart' as http;

import '../cancel.dart';
import '../client.dart';

/// The ETag cache key of a singleton's record. Not a valid record id, so it
/// can't collide with one.
const singletonEtagKey = '@singleton';

/// The one record of a singleton collection, at the collection's own path.
class Singleton<T> {
  Singleton(this._vb, this.name, this._decode);

  final Vaultbase _vb;
  final String name;
  final T Function(Map<String, dynamic>) _decode;

  String get _path => '/api/v1/${Uri.encodeComponent(name)}';

  Future<T> get(
      {String? expand,
      String? fields,
      String? exclude,
      CancelToken? cancelToken}) async {
    final data = await _vb.request(_path,
        query: {'expand': expand, 'fields': fields, 'exclude': exclude},
        cancelToken: cancelToken,
        onResponse: _captureEtag);
    return _decode((data as Map).cast<String, dynamic>());
  }

  /// `If-Match` works as in `Collection.update`, with the ETag from this
  /// singleton's last [get] or [update].
  Future<T> update(Map<String, dynamic> body,
      {String? ifMatch,
      bool checkEtag = true,
      CancelToken? cancelToken}) async {
    final etag =
        checkEtag ? ifMatch ?? _vb.etags.get(name, singletonEtagKey) : null;
    final data = await _vb.request(_path,
        method: 'PATCH',
        body: body,
        headers: etag == null ? null : {'If-Match': etag},
        cancelToken: cancelToken,
        onResponse: _captureEtag);
    return _decode((data as Map).cast<String, dynamic>());
  }

  void _captureEtag(http.Response res) {
    final etag = res.headers['etag'];
    if (etag != null) _vb.etags.set(name, singletonEtagKey, etag);
  }
}
