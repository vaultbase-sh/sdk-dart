import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:vaultbase/vaultbase.dart';

/// Ties a client to the app's lifecycle.
///
/// When the app goes to the background, the realtime connection closes
/// after [pauseAfter] (mobile OSes drop idle sockets anyway; this makes it
/// predictable). When the app comes back, it reconnects and subscribes
/// again, and the session is refreshed if it expires within
/// [refreshWithin].
///
/// Create one after the client and [dispose] it with the client:
///
/// ```dart
/// final lifecycle = VaultbaseLifecycle(vb);
/// ```
class VaultbaseLifecycle {
  VaultbaseLifecycle(
    this.vb, {
    this.pauseAfter = const Duration(seconds: 30),
    this.refreshWithin = const Duration(minutes: 5),
    WidgetsBinding? binding,
  }) {
    _listener = AppLifecycleListener(
      binding: binding ?? WidgetsFlutterBinding.ensureInitialized(),
      onStateChange: _onState,
    );
  }

  final Vaultbase vb;
  final Duration pauseAfter;
  final Duration refreshWithin;
  late final AppLifecycleListener _listener;
  Timer? _pauseTimer;

  void _onState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _pauseTimer ??= Timer(pauseAfter, vb.realtime.pause);
      case AppLifecycleState.resumed:
        _pauseTimer?.cancel();
        _pauseTimer = null;
        _refreshIfDue();
        vb.realtime.resume();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _refreshIfDue() {
    final token = vb.authStore.token;
    if (token == null || token.isEmpty) return;
    final exp = decodeJwtPayload(token)?['exp'];
    if (exp is! num) return;
    final left = exp * 1000 - DateTime.now().millisecondsSinceEpoch;
    if (left > refreshWithin.inMilliseconds) return;
    // A failure is fine: an offline refresh keeps the session, and a
    // refused one already cleared it.
    unawaited(vb.refreshSession().then((_) {}, onError: (Object _) {}));
  }

  /// Stops following the lifecycle.
  void dispose() {
    _pauseTimer?.cancel();
    _listener.dispose();
  }
}
