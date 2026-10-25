# Example

A complete Flutter app on Vaultbase lives in the repository's
[`example/`](https://github.com/vaultbase-sh/sdk-dart/tree/main/example): email
and password sign-in with two-factor codes, GitHub sign-in in the system
browser, and a list of notes that updates live.

The essentials:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vaultbase_flutter/vaultbase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final vb = Vaultbase('https://api.example.com',
      authStore: kIsWeb ? PrefsAuthStore() : SecureAuthStore());
  await vb.authStore.ready;
  VaultbaseLifecycle(vb);
  runApp(MaterialApp(
    home: StreamBuilder<StoredAuth?>(
      stream: vb.authStore.onChange,
      initialData: vb.authStore.current,
      builder: (context, snap) => snap.data == null
          ? const Text('Sign-in page')
          : const Text('Signed in'),
    ),
  ));
}
```
