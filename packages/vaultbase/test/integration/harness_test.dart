@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'server.dart';

void main() {
  final skip =
      TestServer.serverDir() == null ? 'no Vaultbase server checkout' : null;
  late TestServer server;

  setUpAll(() async {
    if (skip == null) server = await TestServer.start();
  });
  tearDownAll(() async {
    if (skip == null) await server.stop();
  });

  test('the server answers and the admin can sign in', () async {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse('${server.baseUrl}/api/v1/admin/auth/me'));
      req.headers.set('authorization', 'Bearer ${server.adminToken}');
      final res = await req.close();
      final body = jsonDecode(await res.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      expect(res.statusCode, 200);
      expect(((body['data'] ?? body) as Map<String, dynamic>)['email'],
          TestServer.adminEmail);
    } finally {
      client.close();
    }
  }, skip: skip);
}
