import 'dart:convert';

/// The payload of a JWT, without checking the signature (that is the
/// server's job). Null when [token] is not a JWT.
Map<String, dynamic>? decodeJwtPayload(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final json = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final payload = jsonDecode(json);
    return payload is Map<String, dynamic> ? payload : null;
  } on FormatException {
    return null;
  }
}

/// True when [token] is an API token (`vbat_...`, audience `api`): a
/// credential an admin minted, not a session. The server never refreshes
/// one.
bool isApiToken(String token) {
  if (token.startsWith('vbat_')) return true;
  final aud = decodeJwtPayload(token)?['aud'];
  return aud == 'api' || (aud is List && aud.isNotEmpty && aud.first == 'api');
}

/// Seconds until [token] expires, or null when it has no `exp`.
int? secondsUntilExpiry(String token, [DateTime? now]) {
  final exp = decodeJwtPayload(token)?['exp'];
  if (exp is! num) return null;
  final nowSeconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  return exp.toInt() - nowSeconds;
}
