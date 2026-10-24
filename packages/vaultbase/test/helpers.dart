import 'dart:convert';

import 'package:http/http.dart' as http;

/// An unsigned JWT with [claims], enough for the client's expiry checks.
String fakeJwt(Map<String, Object?> claims) {
  String part(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part(claims)}.sig';
}

/// A token that expires [inSeconds] from now.
String jwtExpiringIn(int inSeconds, {String aud = 'users'}) => fakeJwt({
      'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + inSeconds,
      'aud': aud,
    });

http.Response json(Object? body,
        {int status = 200, Map<String, String> headers = const {}}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json', ...headers});
