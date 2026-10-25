import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultbase/vaultbase.dart';

/// The key both stores save the session under, unless told otherwise.
const defaultAuthKey = 'vaultbase_auth';

/// Keeps the session in the Keychain (iOS, macOS) or the Keystore-backed
/// storage (Android), so it survives restarts and stays out of backups.
///
/// The saved session loads when the store is created; requests wait for
/// it. Pass [storage] to set platform options, and [key] to keep more than
/// one session (one per server, say).
class SecureAuthStore extends AsyncAuthStore {
  SecureAuthStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
    String key = defaultAuthKey,
  }) : super(
          read: () {
            WidgetsFlutterBinding.ensureInitialized();
            return storage.read(key: key);
          },
          write: (value) => value == null
              ? storage.delete(key: key)
              : storage.write(key: key, value: value),
        );
}

/// Keeps the session in shared preferences: `localStorage` on the web,
/// plain app storage elsewhere. Prefer [SecureAuthStore] on mobile and
/// desktop; use this where secure storage isn't available.
class PrefsAuthStore extends AsyncAuthStore {
  PrefsAuthStore({SharedPreferencesAsync? prefs, String key = defaultAuthKey})
      : super(
          read: () {
            WidgetsFlutterBinding.ensureInitialized();
            return (prefs ??= SharedPreferencesAsync()).getString(key);
          },
          write: (value) {
            final p = prefs ??= SharedPreferencesAsync();
            return value == null ? p.remove(key) : p.setString(key, value);
          },
        );
}
