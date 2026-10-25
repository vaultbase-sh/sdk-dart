import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:vaultbase/vaultbase.dart';

/// Opens [url] in the system's sign-in browser and returns the URL the
/// provider redirected to.
typedef OAuth2Browser = Future<String> Function(
    Uri url, String callbackUrlScheme);

/// OAuth sign-in through the system browser.
extension VaultbaseOAuth2 on CollectionAuth {
  /// Signs in with [provider] in the system's sign-in browser
  /// (ASWebAuthenticationSession on iOS and macOS, Custom Tabs on Android,
  /// a popup on the web) and finishes the exchange.
  ///
  /// [redirectUri] must be in the server's allowed redirects, and its
  /// scheme registered with the app (`com.example.app://oauth`, say); see
  /// the `flutter_web_auth_2` setup for each platform. Returns [SignedIn],
  /// [MfaRequired] or [MergeRequired]. Closing the browser throws
  /// [CancelledException]; a provider error throws [AuthException].
  ///
  /// The server keeps the PKCE verifier unless [usePkce] is false.
  /// [browser] replaces the system browser (tests, or a custom flow).
  Future<AuthResult> signInWithOAuth2(
    String provider, {
    required String redirectUri,
    bool usePkce = true,
    FlutterWebAuth2Options options = const FlutterWebAuth2Options(),
    OAuth2Browser? browser,
  }) async {
    final start =
        await oauth2Authorize(provider, redirectUri, usePkce: usePkce);
    final open = browser ??
        (url, scheme) => FlutterWebAuth2.authenticate(
            url: url.toString(), callbackUrlScheme: scheme, options: options);
    final String result;
    try {
      result = await open(start.authorizeUrl, Uri.parse(redirectUri).scheme);
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED') {
        throw const CancelledException('Sign-in cancelled');
      }
      throw AuthException(AuthFailure.invalid, e.message ?? e.code,
          code: e.code);
    }
    return oauth2ExchangeRedirect(provider, redirectUri, Uri.parse(result));
  }
}
