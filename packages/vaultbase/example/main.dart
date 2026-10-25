// Signs in, lists posts, and prints changes to them for a minute.
//
//   dart run example/main.dart https://api.example.com a@b.c a-long-password
import 'package:vaultbase/vaultbase.dart';

Future<void> main(List<String> args) async {
  final vb = Vaultbase(args.isNotEmpty ? args[0] : 'http://localhost:8091');
  try {
    if (args.length >= 3) {
      final result = await vb.auth.collection('users').login(args[1], args[2]);
      if (result is MfaRequired) {
        print('Two-factor is on for this account; finish with loginMfa.');
        return;
      }
    }

    final page =
        await vb.collection('posts').list(sort: '-created', perPage: 10);
    print('${page.totalItems} posts');
    for (final post in page.items) {
      print('- ${post.getString('title')} (${post.createdAt.toLocal()})');
    }

    final sub = vb.collection('posts').subscribe((e) =>
        print('${e.action.name}: ${e.record?.getString('title') ?? e.id}'));
    await sub.ready;
    print('Listening for changes for a minute...');
    await Future<void>.delayed(const Duration(minutes: 1));
    sub.cancel();
  } on VaultbaseException catch (e) {
    print('Failed: ${e.message}');
  } finally {
    vb.close();
  }
}
