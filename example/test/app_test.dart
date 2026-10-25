import 'package:flutter_test/flutter_test.dart';
import 'package:vaultbase_example/main.dart';
import 'package:vaultbase_flutter/vaultbase_flutter.dart';

void main() {
  testWidgets('signed out shows sign-in; a session shows the notes',
      (tester) async {
    final vb = Vaultbase('http://127.0.0.1:9');
    await tester.pumpWidget(NotesApp(vb: vb));
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Continue with GitHub'), findsOneWidget);

    vb.authStore.save(const StoredAuth('t', record: {'email': 'a@b.c'}));
    await tester.pump();
    await tester.pump();
    expect(find.text('a@b.c'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);
    vb.close();
  });
}
