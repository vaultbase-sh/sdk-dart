import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:vaultbase/codegen.dart';

const _usage = '''
dart run vaultbase:types: Dart types from a Vaultbase schema

Usage:
  dart run vaultbase:types --schema=vaultbase-schema.json [--out=lib/vaultbase_schema.g.dart]
  dart run vaultbase:types --url=https://api.example.com --admin-token=\$TOKEN [--out=...]

Snapshot mode is the default and recommended for CI. Snapshot the schema via:
  curl -H "Authorization: Bearer \$ADMIN" \\
    https://api.example.com/api/v1/admin/migrations/snapshot \\
    > vaultbase-schema.json
Then commit the JSON. Anyone can regenerate the types from it without secrets.
''';

Future<void> main(List<String> argv) async {
  try {
    await _run(argv);
  } on Object catch (e) {
    stderr.writeln('vaultbase:types: ${e is FormatException ? e.message : e}');
    exitCode = 1;
  }
}

Future<void> _run(List<String> argv) async {
  String? schema, url, token;
  var out = 'lib/vaultbase_schema.g.dart';
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    String value(String flag) {
      if (a.startsWith('$flag=')) return a.substring(flag.length + 1);
      if (i + 1 >= argv.length) throw FormatException('$flag needs a value');
      return argv[++i];
    }

    if (a == '--help' || a == '-h') {
      stdout.write(_usage);
      return;
    } else if (a.startsWith('--schema')) {
      schema = value('--schema');
    } else if (a.startsWith('--url')) {
      url = value('--url');
    } else if (a.startsWith('--admin-token')) {
      token = value('--admin-token');
    } else if (a.startsWith('--out') || a == '-o') {
      out = value(a == '-o' ? '-o' : '--out');
    } else {
      throw FormatException('unknown option $a\n\n$_usage');
    }
  }

  final Object? json;
  if (schema != null) {
    json = jsonDecode(await File(schema).readAsString());
  } else if (url != null) {
    if (token == null) {
      throw const FormatException('--admin-token is required with --url');
    }
    final base = url.replaceAll(RegExp(r'/+$'), '');
    final res = await http.get(
        Uri.parse('$base/api/v1/admin/migrations/snapshot'),
        headers: {'Authorization': 'Bearer $token'});
    if (res.statusCode != 200) {
      throw FormatException('schema fetch failed: ${res.statusCode}');
    }
    json = jsonDecode(res.body);
  } else {
    throw const FormatException(
        'Provide --schema=<file> or --url=<host> with --admin-token');
  }

  final collections = snapshotCollections(json);
  // The command as run, minus the token.
  final shown = [
    for (var i = 0; i < argv.length; i++)
      argv[i].startsWith('--admin-token=')
          ? r'--admin-token=$ADMIN_TOKEN'
          : i > 0 && argv[i - 1] == '--admin-token'
              ? r'$ADMIN_TOKEN'
              : argv[i]
  ];
  final source = generateDart(collections,
      header: codegenHeader(['dart run vaultbase:types', ...shown].join(' ')));

  // Written atomically, so a failed run never leaves half a file.
  final file = File(out);
  await file.parent.create(recursive: true);
  final tmp = File('$out.tmp');
  await tmp.writeAsString(source);
  await tmp.rename(file.path);
  // Formatted, so a format check in CI passes.
  await Process.run(Platform.resolvedExecutable, ['format', file.path]);
  stdout.writeln(
      'vaultbase:types: wrote ${file.path} (${collections.length} collections)');
}
