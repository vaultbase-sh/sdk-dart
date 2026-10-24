/// ETags of the records this client has read, for `If-Match` on update and
/// delete. Filled from responses to single-record requests; per client.
class EtagCache {
  final _map = <String, String>{};

  String? get(String collection, String id) => _map['$collection:$id'];

  void set(String collection, String id, String etag) =>
      _map['$collection:$id'] = etag;

  void remove(String collection, String id) => _map.remove('$collection:$id');

  void clear() => _map.clear();
}
