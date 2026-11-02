/// ETags of the records this client has read, for `If-Match` on update and
/// delete. Filled from responses to single-record requests; per client.
/// Holds the latest [maxEntries]; older ones are dropped.
class EtagCache {
  static const maxEntries = 1000;

  // Insertion-ordered, so the first key is the oldest.
  final _map = <String, String>{};

  String? get(String collection, String id) => _map['$collection:$id'];

  void set(String collection, String id, String etag) {
    final key = '$collection:$id';
    _map.remove(key);
    _map[key] = etag;
    if (_map.length > maxEntries) _map.remove(_map.keys.first);
  }

  void remove(String collection, String id) => _map.remove('$collection:$id');

  void clear() => _map.clear();
}
