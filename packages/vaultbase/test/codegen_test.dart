@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vaultbase/codegen.dart';

const fixture = 'test/fixtures/schema-all-types.json';

void main() {
  final collections =
      snapshotCollections(jsonDecode(File(fixture).readAsStringSync()));
  final out = generateDart(collections);

  test('a record class per collection, typed getters per field', () {
    expect(out, contains('class PostsRecord extends RecordModel {'));
    expect(out, contains("String get title => getString('title');"));
    expect(out, contains("String? get body => data['body'] as String?;"));
    expect(out, contains("num get rating => data['rating'] as num? ?? 0;"));
    expect(out, contains("List<String> get tags => getList<String>('tags');"));
    expect(out, contains("DateTime? get publishAt => getDate('publish_at');"));
    expect(
        out,
        contains("({double lat, double lng})? get place => "
            "_geoPoint(data['place']);"));
    expect(out,
        contains("for (final v in getList<num>('embedding')) v.toDouble()"));
  });

  test('fields that clash with keywords or RecordModel members are renamed',
      () {
    expect(out, contains("get classField => data['class']"));
    expect(out, contains("get dataField => data['data']"));
    expect(out, contains("get toJsonField => data['to_json']"));
    expect(out, isNot(contains('get data =>')));
  });

  test('password fields are never emitted', () {
    expect(out, isNot(contains('secret')));
  });

  test('auth records carry the account flags; their create points at register',
      () {
    expect(
        out, contains("bool get emailVerified => getBool('email_verified');"));
    expect(out, contains("bool get isAnonymous => getBool('is_anonymous');"));
    expect(out, contains('required this.email, required this.password'));
    expect(
        out,
        contains("auth.collection('users')"
            '.register(u.email, u.password, data: u.toJson())'));
    expect(out, isNot(contains(RegExp(r'get verified\b'))));
  });

  test('views and singletons have no create class; singletons use singletonOf',
      () {
    expect(out, contains('class PostStatsRecord'));
    expect(out, isNot(contains('PostStatsCreate')));
    expect(out, isNot(contains('SiteSettingsCreate')));
    expect(out, contains('Singleton<SiteSettingsRecord> get siteSettings =>'));
    expect(
        out,
        contains(
            "vb.singletonOf('site_settings', SiteSettingsRecord.fromJson)"));
    // A singleton's fields start empty, required or not.
    expect(out, contains('String? get headline'));
  });

  test('create classes omit unset fields and encode dates and geo points', () {
    expect(out, contains("if (body != null) 'body': body!"));
    expect(out, contains("'publish_at': publishAt!.toUtc().toIso8601String()"));
    expect(out, contains("'place': {'lat': place!.lat, 'lng': place!.lng}"));
    // Autodate fields are the server's to set.
    expect(out, isNot(contains('this.edited')));
  });

  test('a class per group: list items with an id, or one object', () {
    expect(out, contains('class OrdersItemsItem {'));
    expect(out, contains("id: json['id'] as String?,"));
    expect(out, contains("sku: json['sku'] as String? ?? '',"));
    expect(out, contains("shipOn: _groupDate(json['ship_on']),"));
    expect(out, contains("if (toJsonField != null) 'to_json': toJsonField!"));
    expect(out, contains('class OrdersAddress {'));
    expect(out, isNot(contains('OrdersAddressItem')));
    expect(out, contains('List<OrdersItemsItem> get items => ['));
    expect(out, contains('OrdersAddress? get address =>'));
    expect(out, contains("'items': [for (final i in items) i.toJson()],"));
    expect(out, contains("if (address != null) 'address': address!.toJson()"));
  });

  test('group classes stay clear of record and create class names', () {
    final out = generateDart([
      {
        'name': 'posts',
        'fields': [
          {
            'name': 'record',
            'type': 'group',
            'options': {
              'multiple': false,
              'fields': [
                {'name': 'a', 'type': 'text'}
              ]
            }
          }
        ]
      }
    ]);
    expect(out, contains('class PostsRecord extends RecordModel {'));
    expect(out, contains('class PostsRecord2 {'));
    expect(out, contains('PostsRecord2? get record =>'));
  });

  test('colliding class and accessor names are deduped', () {
    final dup = generateDart([
      {'name': 'my_posts', 'type': 'base', 'fields': <Object?>[]},
      {'name': 'myPosts', 'type': 'base', 'fields': <Object?>[]},
      {'name': 'hashCode', 'type': 'base', 'fields': '[]'},
    ]);
    expect(dup, contains('class MyPostsRecord '));
    expect(dup, contains('class MyPosts2Record '));
    expect(dup, contains('get myPosts =>'));
    expect(dup, contains('get myPosts2 =>'));
    expect(dup, contains('get hashCode2 =>'));
  });

  test('snapshot shapes: a list, {collections}, and the data envelope', () {
    final one = [
      {'name': 'a', 'type': 'base', 'fields': <Object?>[]}
    ];
    expect(snapshotCollections(one), hasLength(1));
    expect(snapshotCollections({'collections': one}), hasLength(1));
    expect(snapshotCollections({'data': one}), hasLength(1));
    expect(() => snapshotCollections({'x': 1}), throwsFormatException);
  });

  group('dart run vaultbase:types', () {
    late Directory dir;
    // Inside the package, so `dart format` uses the package's language
    // version, as it does for an app's generated file.
    setUp(() => dir = Directory('.dart_tool/vb-types-test')
      ..createSync(recursive: true));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<ProcessResult> run(List<String> args) =>
        Process.run(Platform.resolvedExecutable, ['bin/types.dart', ...args]);

    test('test/generated/schema.g.dart is what the fixture generates now',
        () async {
      final target = '${dir.path}/schema.g.dart';
      final res = await run(['--schema=$fixture', '--out=$target']);
      expect(res.exitCode, 0, reason: '${res.stderr}');
      String body(String path) =>
          File(path).readAsLinesSync().skip(2).join('\n');
      // Regenerate with: dart run vaultbase:types --schema=$fixture
      //   --out=test/generated/schema.g.dart
      expect(body(target), body('test/generated/schema.g.dart'));
    });

    test('names the command in the header, without the token', () async {
      final target = '${dir.path}/out.g.dart';
      final res = await run(['--schema', fixture, '-o', target]);
      expect(res.exitCode, 0, reason: '${res.stderr}');
      expect(File(target).readAsStringSync(),
          contains('// Regenerate via:  dart run vaultbase:types --schema'));
    });

    test('refuses unknown options and a missing source', () async {
      final unknown = await run(['--lang=kotlin']);
      expect(unknown.exitCode, 1);
      expect(unknown.stderr, contains('unknown option --lang=kotlin'));
      final none = await run([]);
      expect(none.exitCode, 1);
      expect(none.stderr, contains('Provide --schema'));
    });
  });
}
