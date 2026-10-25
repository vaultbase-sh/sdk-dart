@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:vaultbase/vaultbase.dart';

import 'server.dart';

/// RFC 6238 code for a base32 [secret]: SHA-1, 6 digits, 30 s steps.
String totp(String secret, [DateTime? at]) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final bits = StringBuffer();
  for (final ch in secret.toUpperCase().replaceAll('=', '').split('')) {
    bits.write(alphabet.indexOf(ch).toRadixString(2).padLeft(5, '0'));
  }
  final s = bits.toString();
  final key = Uint8List.fromList([
    for (var i = 0; i + 8 <= s.length; i += 8)
      int.parse(s.substring(i, i + 8), radix: 2)
  ]);
  final counter = (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000 ~/ 30;
  final msg = ByteData(8)..setInt64(0, counter);
  final h = Hmac(sha1, key).convert(msg.buffer.asUint8List()).bytes;
  final o = h.last & 0xf;
  final code =
      ((h[o] & 0x7f) << 24 | h[o + 1] << 16 | h[o + 2] << 8 | h[o + 3]) %
          1000000;
  return code.toString().padLeft(6, '0');
}

void main() {
  final skip =
      TestServer.serverDir() == null ? 'no Vaultbase server checkout' : null;
  late TestServer server;
  late Vaultbase admin;

  setUpAll(() async {
    if (skip != null) return;
    server = await TestServer.start();
    admin = Vaultbase(server.baseUrl);
    await admin.auth.admin
        .login(TestServer.adminEmail, TestServer.adminPassword);
    Future<void> create(Map<String, Object?> body) =>
        admin.send('/api/v1/collections', method: 'POST', body: body);
    await admin.send('/api/v1/admin/settings',
        method: 'PATCH', body: {'auth.anonymous.enabled': '1'});
    await create({
      'name': 'members',
      'type': 'auth',
      'create_rule': null,
      'fields': <Object?>[],
    });
    await create({
      'name': 'docs',
      'type': 'base',
      'list_rule': null,
      'view_rule': null,
      'fields': [
        {'name': 'title', 'type': 'text'},
        {
          'name': 'attachments',
          'type': 'file',
          'options': {'multiple': true}
        },
        {
          'name': 'secret',
          'type': 'file',
          'options': {'protected': true}
        },
      ],
    });
    await create({
      'name': 'notes',
      'type': 'base',
      'list_rule': "@request.auth.id != ''",
      'view_rule': "@request.auth.id != ''",
      'create_rule': null,
      'fields': [
        {'name': 'body', 'type': 'text'},
      ],
    });
  });

  tearDownAll(() async {
    if (skip != null) return;
    admin.close();
    await server.stop();
  });

  group('auth', () {
    test('admin sign-in and setup status', () async {
      expect(admin.authStore.current?.isAdmin, isTrue);
      expect((await admin.auth.admin.me())['email'], TestServer.adminEmail);
      final status = await Vaultbase(server.baseUrl).auth.admin.setupStatus();
      expect(status.hasAdmin, isTrue);
    }, skip: skip);

    test('register, login, two-factor sign-in, recovery codes', () async {
      final vb = Vaultbase(server.baseUrl);
      final members = vb.auth.collection('members');
      const email = 'mfa@sdk-dart.test', password = 'a-long-password-1';
      await members.register(email, password);
      expect(await members.login(email, password), isA<SignedIn>());

      final setup = await members.setupTotp();
      expect(setup.otpauthUrl, startsWith('otpauth://'));
      final codes = await members.confirmTotp(totp(setup.secret));
      expect(codes, isNotEmpty);
      expect((await members.recoveryCodeStatus()).remaining, codes.length);

      await vb.auth.logout();
      final first = await members.login(email, password);
      expect(first, isA<MfaRequired>());
      expect(vb.authStore.current, isNull);
      // The confirm spent this step's code (replays are refused); the server
      // accepts the next step's within its drift window.
      final next = DateTime.now().add(const Duration(seconds: 30));
      final signedIn = await members.loginMfa((first as MfaRequired).mfaToken,
          code: totp(setup.secret, next));
      expect(signedIn.record.getString('email'), email);
      expect(vb.auth.isSignedIn, isTrue);

      await vb.auth.logout();
      final again = await members.login(email, password) as MfaRequired;
      await members.loginMfa(again.mfaToken, recoveryCode: codes.first);
      expect((await members.recoveryCodeStatus()).remaining, codes.length - 1);
      vb.close();
    }, skip: skip);

    test('anonymous sign-in, then promote', () async {
      final vb = Vaultbase(server.baseUrl);
      final members = vb.auth.collection('members');
      final anon = await members.anonymous();
      expect(anon.record.getBool('anonymous'), isTrue);
      final promoted =
          await members.promote('promoted@sdk-dart.test', 'a-long-password-2');
      expect(promoted.record.id, anon.record.id);
      expect((await vb.auth.me())['email'], 'promoted@sdk-dart.test');
      vb.close();
    }, skip: skip);

    test('OAuth: providers list, and an unlisted redirect is refused',
        () async {
      final members = Vaultbase(server.baseUrl).auth.collection('members');
      expect(await members.oauth2Providers(), isEmpty);
      await expectLater(members.oauth2Authorize('github', 'com.evil://x'),
          throwsA(isA<ValidationException>()));
    }, skip: skip);
  });

  group('files', () {
    test('upload with progress, attach, download', () async {
      final doc =
          await admin.collection('docs').create({'title': 'with files'});
      final sent = <int>[];
      final metas = await admin.files.upload(
          'docs',
          doc.id,
          'attachments',
          [
            UploadFile.fromBytes('a.txt', utf8.encode('alpha'),
                contentType: 'text/plain'),
            UploadFile.fromStream(
                'b.txt', () => Stream.value(utf8.encode('bravo')),
                length: 5, contentType: 'text/plain'),
          ],
          onProgress: (s, _) => sent.add(s));
      expect(metas.map((m) => m.originalName), ['a.txt', 'b.txt']);
      expect(sent, isNotEmpty);

      final updated = await admin.collection('docs').update(doc.id, {
        'attachments': [for (final m in metas) m.filename]
      });
      expect(updated.getList<String>('attachments'), hasLength(2));

      final res = await http.get(admin.files.url(metas.first.filename));
      expect(res.statusCode, 200);
      expect(res.body, 'alpha');

      await admin.files
          .delete('docs', doc.id, 'attachments', metas.last.filename);
      // The stored file is gone and the record's field no longer names it.
      final gone = await http.get(admin.files.url(metas.last.filename));
      expect(gone.statusCode, 404);
      final after = await admin.collection('docs').get(doc.id);
      expect(after.getList<String>('attachments'), [metas.first.filename]);
    }, skip: skip);

    test('a protected file needs a token', () async {
      final doc = await admin.collection('docs').create({'title': 'secret'});
      final meta = (await admin.files.upload('docs', doc.id, 'secret',
              [UploadFile.fromBytes('s.txt', utf8.encode('hush'))]))
          .single;
      await admin.collection('docs').update(doc.id, {'secret': meta.filename});

      final bare = await http.get(admin.files.url(meta.filename));
      expect(bare.statusCode, isNot(200));
      final url = await admin.files
          .urlWithToken('docs', doc.id, 'secret', meta.filename);
      final withToken = await http.get(url);
      expect(withToken.statusCode, 200);
      expect(withToken.body, 'hush');
    }, skip: skip);
  });

  group('realtime', () {
    test('create, update and delete events reach a subscriber', () async {
      final events = <RealtimeEvent>[];
      final sub = admin.collection('docs').subscribe(events.add);
      await sub.ready.timeout(const Duration(seconds: 5));

      final doc = await admin.collection('docs').create({'title': 'live'});
      await admin.collection('docs').update(doc.id, {'title': 'live 2'});
      await admin.collection('docs').delete(doc.id);
      for (var i = 0; i < 100 && events.length < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(events.map((e) => e.action), [
        RealtimeAction.create,
        RealtimeAction.update,
        RealtimeAction.delete,
      ]);
      expect(events[1].record?.getString('title'), 'live 2');
      expect(events.every((e) => e.id == doc.id), isTrue);
      sub.cancel();
    }, skip: skip);

    test('a record subscription hears only its record', () async {
      final a = await admin.collection('docs').create({'title': 'a'});
      final b = await admin.collection('docs').create({'title': 'b'});
      final events = <RealtimeEvent>[];
      final sub = admin.collection('docs').subscribe(events.add, ids: [a.id]);
      await sub.ready.timeout(const Duration(seconds: 5));
      await admin.collection('docs').update(b.id, {'title': 'b2'});
      await admin.collection('docs').update(a.id, {'title': 'a2'});
      for (var i = 0; i < 100 && events.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(events.map((e) => e.id), [a.id]);
      sub.cancel();
    }, skip: skip);

    test('rules apply: events after signing in on the open connection',
        () async {
      final user = Vaultbase(server.baseUrl);
      final members = user.auth.collection('members');
      await members.register('rt@sdk-dart.test', 'a-long-password-3');
      final events = <RealtimeEvent>[];
      final sub = user.collection('notes').subscribe(events.add);
      await sub.ready.timeout(const Duration(seconds: 5));

      await admin.collection('notes').create({'body': 'hidden'});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(events, isEmpty);

      await members.login('rt@sdk-dart.test', 'a-long-password-3');
      // The new token goes over the open connection; give it a moment.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await admin.collection('notes').create({'body': 'visible'});
      for (var i = 0; i < 100 && events.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(events.single.record?.getString('body'), 'visible');
      user.close();
    }, skip: skip);
  });
}
