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
  /// The session expired and could not be refreshed; it was cleared.
  expired,

  /// A request sent without the session was refused (bad credentials).
  invalid,

  /// The session is valid but not allowed to do this (403, or a 401 after a
  /// successful refresh). The session is kept.
  forbidden,
}

/// 401 / 403.
final class AuthException extends VaultbaseException {
  const AuthException(this.reason, super.message,
      {super.status, super.code, super.body});

  final AuthFailure reason;
}

/// 422: the body failed validation. [details] maps field names to messages.
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

/// Any other non-2xx response.
final class ServerException extends VaultbaseException {
  const ServerException(super.message, {super.status, super.code, super.body});
}

/// The request was cancelled: by its [CancelToken], or by a newer request
/// with the same request key.
final class CancelledException extends VaultbaseException {
  const CancelledException([super.message = 'Request cancelled']);
}
