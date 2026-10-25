@Tags(['integration'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:vaultbase/vaultbase.dart';

import 'server.dart';

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
    await admin.send('/api/v1/admin/flags', method: 'POST', body: {
      'key': 'beta',
      'type': 'bool',
      'enabled': true,
      'default_value': false,
      'variations': [
        {'name': 'on', 'value': true},
        {'name': 'off', 'value': false},
      ],
      'rules': [
        {
          'id': 'pro',
          'when': {'attr': 'plan', 'op': 'eq', 'value': 'pro'},
          'variation': 'on',
        }
      ],
    });
  });

  tearDownAll(() async {
    if (skip != null) return;
    admin.close();
    await server.stop();
  });

  test('evaluates for the context; a change is pushed', () async {
    final vb = Vaultbase(server.baseUrl);
    await vb.flags.connect(context: {'plan': 'free'});
    expect(vb.flags.isEnabled('beta'), isFalse);
    await vb.flags.setContext({'plan': 'pro'});
    expect(vb.flags.isEnabled('beta'), isTrue);

    // Wait until the push subscription is in place, then change the flag.
    for (var i = 0; i < 100 && vb.realtime.state != RealtimeState.open; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final changed = vb.flags.changes.first.timeout(const Duration(seconds: 5));
    await admin.send('/api/v1/admin/flags', method: 'POST', body: {
      'key': 'theme',
      'type': 'string',
      'enabled': true,
      'default_value': 'dark',
    });
    expect(await changed, {'theme'});
    expect(vb.flags.getString('theme', 'light'), 'dark');

    final deleted = vb.flags.changes.first.timeout(const Duration(seconds: 5));
    await admin.send('/api/v1/admin/flags/theme', method: 'DELETE');
    expect(await deleted, {'theme'});
    expect(vb.flags.getString('theme', 'light'), 'light');
    vb.close();
  }, skip: skip);
}
