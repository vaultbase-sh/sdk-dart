/// Starts a real Vaultbase server for the integration tests.
///
/// The server source is the sibling checkout `../vaultbase` (relative to the
/// repo root), or `VAULTBASE_SERVER_DIR`. It runs under Bun on a free port
/// with a throwaway data directory, rate limiting off and a known setup key;
/// an admin is seeded through `/api/v1/admin/setup`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class TestServer {
  TestServer._(this.baseUrl, this.adminToken, this._process, this._dataDir);

  final String baseUrl;
  final String adminToken;
  final Process _process;
  final Directory _dataDir;

  static const adminEmail = 'admin@sdk-dart.test';
  static const adminPassword = 'integration-password-1';
  static const setupKey = 'integration-setup-key';

  /// The server checkout, or null when there is none (tests then skip).
  static Directory? serverDir() {
    final env = Platform.environment['VAULTBASE_SERVER_DIR'];
    final candidates = [
      if (env != null && env.isNotEmpty) env,
      // packages/vaultbase → repo root → sibling.
      '${Directory.current.path}/../../../vaultbase',
    ];
    for (final c in candidates) {
      final dir = Directory(c);
      if (File('${dir.path}/src/index.ts').existsSync()) return dir.absolute;
    }
    return null;
  }

  static Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  static Future<TestServer> start() async {
    final dir = serverDir();
    if (dir == null) throw StateError('no Vaultbase server checkout found');
    final dataDir = await Directory.systemTemp.createTemp('vbdart-it-');
    final port = await _freePort();
    final process = await Process.start(
      'bun',
      ['src/index.ts'],
      workingDirectory: dir.path,
      environment: {
        'VAULTBASE_DATA_DIR': dataDir.path,
        'VAULTBASE_PORT': '$port',
        'VAULTBASE_HOST': '127.0.0.1',
        'VAULTBASE_JWT_SECRET': 'test-jwt-secret-do-not-use-in-prod',
        'VAULTBASE_RATE_ENABLED': '0',
        'VAULTBASE_SETUP_KEY': setupKey,
        'VAULTBASE_READ_WORKERS': '0',
      },
    );
    final output = StringBuffer();
    process.stdout.transform(utf8.decoder).listen(output.write);
    process.stderr.transform(utf8.decoder).listen(output.write);

    final baseUrl = 'http://127.0.0.1:$port';
    final client = HttpClient();
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (true) {
        try {
          final res =
              await (await client.getUrl(Uri.parse('$baseUrl/api/health')))
                  .close();
          await res.drain<void>();
          if (res.statusCode == 200) break;
        } on SocketException {
          // Not listening yet.
        }
        if (DateTime.now().isAfter(deadline)) {
          process.kill();
          throw StateError('server did not start within 30 s:\n$output');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      Future<Map<String, dynamic>> post(String path, Map<String, Object> body,
          [Map<String, String> headers = const {}]) async {
        final req = await client.postUrl(Uri.parse('$baseUrl$path'));
        req.headers.contentType = ContentType.json;
        headers.forEach(req.headers.set);
        req.write(jsonEncode(body));
        final res = await req.close();
        final text = await res.transform(utf8.decoder).join();
        if (res.statusCode >= 300) {
          throw StateError('$path: ${res.statusCode} $text');
        }
        return jsonDecode(text) as Map<String, dynamic>;
      }

      final creds = {'email': adminEmail, 'password': adminPassword};
      await post('/api/v1/admin/setup', creds, {'x-setup-key': setupKey});
      final login = await post('/api/v1/admin/auth/login', creds);
      final data = (login['data'] ?? login) as Map<String, dynamic>;
      return TestServer._(baseUrl, data['token'] as String, process, dataDir);
    } finally {
      client.close();
    }
  }

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      _process.kill(ProcessSignal.sigkill);
      return -1;
    });
    try {
      await _dataDir.delete(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  }
}
