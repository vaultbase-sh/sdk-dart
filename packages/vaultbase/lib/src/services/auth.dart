import '../client.dart';
import '../errors.dart';

/// The session: refresh, sign-out, the signed-in identity. Sign-in flows
/// come in a later version.
class AuthService {
  AuthService(this._vb);

  final Vaultbase _vb;

  /// True when there is a session whose token has not expired.
  bool get isSignedIn => _vb.authStore.isValid;

  /// Swaps the token for a new one and stores it. False when the server
  /// refused (the session is then cleared); throws on a network error.
  Future<bool> refresh() => _vb.refreshSession();

  /// Ends the session on the server and clears it here, even when the
  /// server can't be reached.
  Future<void> logout() async {
    try {
      if (_vb.authStore.token?.isNotEmpty ?? false) {
        await _vb.request('/api/v1/auth/logout',
            method: 'POST', skipRefresh: true);
      }
    } on VaultbaseException {
      // Signed out locally either way.
    } finally {
      _vb.authStore.clear();
    }
  }

  /// The signed-in user or admin, as the server sees it.
  Future<Map<String, dynamic>> me() async {
    final data = await _vb.request('/api/v1/auth/me');
    return (data as Map).cast<String, dynamic>();
  }
}
