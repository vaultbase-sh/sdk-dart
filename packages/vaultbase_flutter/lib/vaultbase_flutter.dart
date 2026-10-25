/// Flutter helpers for the Vaultbase client: secure token storage, OAuth
/// sign-in in the system browser, and app lifecycle handling.
library;

export 'package:vaultbase/vaultbase.dart';

export 'src/lifecycle.dart' show VaultbaseLifecycle;
export 'src/oauth.dart' show OAuth2Browser, VaultbaseOAuth2;
export 'src/stores.dart' show PrefsAuthStore, SecureAuthStore, defaultAuthKey;
