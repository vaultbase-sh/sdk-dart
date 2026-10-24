import 'package:test/test.dart';
import 'package:vaultbase/vaultbase.dart';

void main() {
  final r = RecordModel({
    'id': 'r1',
    'created': 1700000000,
    'updated': 1700000100,
    'title': 'Hello',
    'views': 12,
    'score': '2.5',
    'email_verified': 1,
    'tags': ['a', 'b', 3],
    'published': 1700000200,
    'expand': {
      'author': {'id': 'u1', 'name': 'Ann'},
      'tags': [
        {'id': 't1'},
        {'id': 't2'}
      ],
    },
  });

  test('typed getters', () {
    expect(r.id, 'r1');
    expect(r.createdAt, DateTime.utc(2023, 11, 14, 22, 13, 20));
    expect(r.getString('title'), 'Hello');
    expect(r.getInt('views'), 12);
    expect(r.getDouble('score'), 2.5);
    expect(r.getBool('email_verified'), isTrue);
    expect(r.getBool('missing'), isFalse);
    expect(r.getList<String>('tags'), ['a', 'b']);
    expect(r.getDate('published'), isNotNull);
    expect(r.getDate('title'), isNull);
  });

  test('expanded relations', () {
    expect(r.expandOne('author')?.getString('name'), 'Ann');
    expect(r.expandMany('tags').map((e) => e.id), ['t1', 't2']);
    expect(r.expandOne('nothing'), isNull);
    expect(r.expandMany('nothing'), isEmpty);
  });

  test('list pages', () {
    final page = ListResult.fromJson({
      'data': [
        {'id': 'a'}
      ],
      'page': 2,
      'perPage': 1,
      'totalItems': -1,
      'totalPages': -1,
    }, RecordModel.fromJson);
    expect(page.items.single.id, 'a');
    expect(page.page, 2);
    expect(page.totalItems, -1);
  });
}
