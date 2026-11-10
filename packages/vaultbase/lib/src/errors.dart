/// Every error the client throws is a [VaultbaseException]; `switch` over
/// the subclasses is exhaustive.
sealed class VaultbaseException implements Exception {
  const VaultbaseException(this.message, {this.status, this.code, this.body});

  final String message;

  /// The HTTP status, when the error came from a response.
  final int? status;

  /// The `code` field of the server's error body, when it sent one.
  final Object? code;

  /// The decoded response body, when there was one.
  final Object? body;

  @override
  String toString() =>
      '$runtimeType(${status == null ? '' : '$status: '}$message)';
}

/// The request never got a response: no connection, DNS, TLS, a timeout.
final class NetworkException extends VaultbaseException {
  const NetworkException(super.message, {this.cause});

  final Object? cause;
}

/// Why a request was refused for its credentials.
enum AuthFailure {
  /// The session ended: its token expired and could not be refreshed, or
  /// the server refused it (a 401; servers 0.42 and 0.43 also answer 403
  /// with `token_invalid`). It was cleared; show sign-in.
  ///
  /// Also an API token the server no longer accepts (expired or revoked).
  /// That one is not cleared: replace it.
  expired,

  /// A request sent without the session was refused (bad credentials).
  invalid,

  /// The caller is not allowed to do this: a collection rule or an
  /// admin-only endpoint refused it (403), a 401 came after a successful
  /// refresh, or an API token doesn't have the scope for the request (a
  /// 401 with `insufficient_scope`, server 0.44+). The session is kept.
  forbidden,

  /// The request had no session and the collection's rule needs one (a 403
  /// with `not_signed_in`, server 0.42+). Show sign-in.
  notSignedIn,
}

/// The operation a 403 refused, as the server names it (server 0.42+).
enum AuthOperation { list, view, create, update, delete }

/// 401 / 403.
///
/// On server 0.42+ a 403 from the records and file APIs also says what was
/// refused ([operation]) and why ([serverReason]). Both are null on older
/// servers and on other endpoints. On server 0.44+ a 401 from the records,
/// files and batch APIs has a [serverReason] too: `token_invalid` for a
/// token the server doesn't accept, `insufficient_scope` for an API token
/// without the scope for the request.
final class AuthException extends VaultbaseException {
  const AuthException(this.reason, super.message,
      {this.operation,
      this.serverReason,
      super.status,
      super.code,
      super.body});

  final AuthFailure reason;

  /// The refused operation, from a 403 body.
  final AuthOperation? operation;

  /// The server's own reason: `not_signed_in`, `rule_denied` or
  /// `admin_only` from a 403 body; `token_invalid` or `insufficient_scope`
  /// from a 401 body (server 0.44+; `token_invalid` came on a 403 from
  /// 0.42 and 0.43).
  final String? serverReason;
}

/// 422, or 400 (a bad filter, sort or body). [details] maps field names to
/// messages when the server sends them.
///
/// Server 0.44+ answers 400 for a list with a `sort`, `expand` or `fields`
/// name that doesn't exist and for a create or update with a body key that
/// isn't a field; [details] is then keyed by the query parameter (`sort`)
/// or the body key.
final class ValidationException extends VaultbaseException {
  const ValidationException(super.message,
      {this.details = const {}, super.status, super.code, super.body});

  final Map<String, String> details;
}

/// 429. [retryAfter] is the server's `Retry-After`, capped at 10 seconds.
final class RateLimitException extends VaultbaseException {
  const RateLimitException(this.retryAfter,
      {String message = 'Too many requests',
      super.status,
      super.code,
      super.body})
      : super(message);

  final Duration retryAfter;
}

/// 409.
final class ConflictException extends VaultbaseException {
  const ConflictException(super.message,
      {super.status, super.code, super.body});
}

/// 412: the record changed since its ETag was read. [currentEtag] is the
/// record's ETag now, when the server sent it.
final class PreconditionFailedException extends VaultbaseException {
  const PreconditionFailedException(super.message,
      {this.currentEtag, super.status, super.code, super.body});

  final String? currentEtag;
}

/// The level of a server's maintenance mode.
enum MaintenanceLevel {
  /// Every client request is refused.
  full,

  /// Reads still work; writes are refused.
  readOnly,
}

/// 503 from a server in maintenance mode. [until] and [retryAfter] are set
/// when the admin said when it should be back.
final class MaintenanceException extends VaultbaseException {
  const MaintenanceException(super.message,
      {this.level = MaintenanceLevel.full,
      this.until,
      this.retryAfter,
      super.status,
      super.code,
      super.body});

  final MaintenanceLevel level;

  /// When the admin expects to be back.
  final DateTime? until;

  /// How long until then.
  final Duration? retryAfter;
}

/// Any other non-2xx response; [NotFoundException] for a 404.
class ServerException extends VaultbaseException {
  const ServerException(super.message, {super.status, super.code, super.body});
}

/// 404: the record, collection or route doesn't exist, or the caller can't
/// see it. A [ServerException], so `on ServerException` still catches it.
final class NotFoundException extends ServerException {
  const NotFoundException(super.message,
      {super.status, super.code, super.body});
}

/// The request was cancelled: by its [CancelToken], or by a newer request
/// with the same request key.
final class CancelledException extends VaultbaseException {
  const CancelledException([super.message = 'Request cancelled']);
}
