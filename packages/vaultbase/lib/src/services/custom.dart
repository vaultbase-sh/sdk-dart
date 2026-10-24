import '../cancel.dart';
import '../client.dart';

/// Custom routes, served under `/api/v1/custom/`.
class CustomRoutes {
  CustomRoutes(this._vb);

  final Vaultbase _vb;

  Future<dynamic> get(String path,
          {Map<String, Object?>? query,
          Map<String, String>? headers,
          CancelToken? cancelToken}) =>
      _send('GET', path,
          query: query, headers: headers, cancelToken: cancelToken);

  Future<dynamic> post(String path,
          {Object? body,
          Map<String, Object?>? query,
          Map<String, String>? headers,
          CancelToken? cancelToken}) =>
      _send('POST', path,
          body: body, query: query, headers: headers, cancelToken: cancelToken);

  Future<dynamic> patch(String path,
          {Object? body,
          Map<String, Object?>? query,
          Map<String, String>? headers,
          CancelToken? cancelToken}) =>
      _send('PATCH', path,
          body: body, query: query, headers: headers, cancelToken: cancelToken);

  Future<dynamic> put(String path,
          {Object? body,
          Map<String, Object?>? query,
          Map<String, String>? headers,
          CancelToken? cancelToken}) =>
      _send('PUT', path,
          body: body, query: query, headers: headers, cancelToken: cancelToken);

  Future<dynamic> delete(String path,
          {Map<String, Object?>? query,
          Map<String, String>? headers,
          CancelToken? cancelToken}) =>
      _send('DELETE', path,
          query: query, headers: headers, cancelToken: cancelToken);

  Future<dynamic> _send(String method, String path,
      {Object? body,
      Map<String, Object?>? query,
      Map<String, String>? headers,
      CancelToken? cancelToken}) {
    final clean = path.replaceFirst(RegExp(r'^/+'), '');
    return _vb.request('/api/v1/custom/$clean',
        method: method,
        body: body,
        query: query,
        headers: headers,
        cancelToken: cancelToken);
  }
}
