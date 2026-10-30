@Tags(['integration'])
library;

import 'package:test/test.dart';
import 'package:vaultbase/vaultbase.dart';

import '../generated/schema.g.dart';
import 'server.dart';

// test/generated/schema.g.dart is `dart run vaultbase:types` over
// test/fixtures/schema-all-types.json; these collections match it.

void main() {
  final skip =
      TestServer.serverDir() == null ? 'no Vaultbase server checkout' : null;
  late TestServer server;
  late Vaultbase vb;

  setUpAll(() async {
    if (skip != null) return;
    server = await TestServer.start();
    vb = Vaultbase(server.baseUrl);
    await vb.auth.admin.login(TestServer.adminEmail, TestServer.adminPassword);
    Future<void> create(Map<String, Object?> body) =>
        vb.send('/api/v1/collections', method: 'POST', body: body);
    await create({
      'name': 'users',
      'type': 'auth',
      'create_rule': null,
      'fields': [
        {'name': 'name', 'type': 'text', 'required': true},
        {'name': 'avatar', 'type': 'file'},
      ],
    });
    await create({
      'name': 'posts',
      'type': 'base',
      'fields': [
        {'name': 'title', 'type': 'text', 'required': true},
        {'name': 'body', 'type': 'editor'},
        {'name': 'views', 'type': 'number'},
        {'name': 'rating', 'type': 'number', 'required': true},
        {'name': 'published', 'type': 'bool'},
        {'name': 'pinned', 'type': 'bool', 'required': true},
        {
          'name': 'status',
          'type': 'select',
          'options': {
            'values': ['draft', 'live']
          }
        },
        {
          'name': 'tags',
          'type': 'select',
          'options': {
            'multiple': true,
            'values': ['a', 'b']
          }
        },
        {'name': 'author', 'type': 'relation', 'collection': 'users'},
        {'name': 'publish_at', 'type': 'date'},
        {'name': 'edited', 'type': 'autodate', 'onUpdate': true},
        {'name': 'meta', 'type': 'json'},
        {'name': 'place', 'type': 'geoPoint'},
        {
          'name': 'embedding',
          'type': 'vector',
          'options': {'dimensions': 3}
        },
        {'name': 'contact', 'type': 'email'},
        {'name': 'site', 'type': 'url'},
        {'name': 'accent', 'type': 'color'},
        {'name': 'class', 'type': 'text'},
        {'name': 'data', 'type': 'text'},
        {'name': 'to_json', 'type': 'text'},
      ],
    });
    await create({
      'name': 'orders',
      'type': 'base',
      'fields': [
        {
          'name': 'items',
          'type': 'group',
          'required': true,
          'options': {
            'max': 10,
            'fields': [
              {'name': 'sku', 'type': 'text', 'required': true},
              {'name': 'qty', 'type': 'number', 'required': true},
              {'name': 'price', 'type': 'number'},
              {'name': 'gift', 'type': 'bool'},
              {
                'name': 'size',
                'type': 'select',
                'options': {
                  'values': ['S', 'M']
                }
              },
              {
                'name': 'tags',
                'type': 'select',
                'options': {
                  'multiple': true,
                  'values': ['x', 'y']
                }
              },
              {'name': 'ship_on', 'type': 'date'},
              {'name': 'extra', 'type': 'json'},
              {'name': 'class', 'type': 'text'},
              {'name': 'to_json', 'type': 'text'},
            ],
          },
        },
        {
          'name': 'address',
          'type': 'group',
          'options': {
            'multiple': false,
            'fields': [
              {'name': 'city', 'type': 'text', 'required': true},
              {'name': 'zip', 'type': 'text'},
              {'name': 'since', 'type': 'date', 'required': true},
            ],
          },
        },
      ],
    });
    await create({
      'name': 'site_settings',
      'type': 'singleton',
      'fields': [
        {'name': 'headline', 'type': 'text', 'required': true},
      ],
    });
  });

  tearDownAll(() async {
    if (skip != null) return;
    vb.close();
    await server.stop();
  });

  test('a typed create round-trips through the server', () async {
    const u = UsersCreate(
        email: 'typed@sdk-dart.test',
        password: 'a-long-password-9',
        name: 'Ann');
    final registered = await Vaultbase(server.baseUrl)
        .auth
        .collection('users')
        .register(u.email, u.password, data: u.toJson());
    final author = await vb.collections.users.get(registered.id);
    expect(author.name, 'Ann');
    expect(author.email, 'typed@sdk-dart.test');
    expect(author.emailVerified, isFalse);

    final at = DateTime.utc(2026, 10, 25, 12, 30);
    final post = await vb.collections.posts.create(PostsCreate(
      title: 'Typed',
      rating: 4.5,
      pinned: true,
      published: false,
      views: 12,
      status: 'live',
      tags: ['a', 'b'],
      author: author.id,
      publishAt: at,
      meta: {
        'k': [1, 2]
      },
      place: (lat: 51.5, lng: -0.12),
      embedding: [0.1, 0.2, 0.3],
      contact: 'ann@example.com',
      site: 'https://example.com',
      accent: '#ff0000',
      classField: 'c',
      dataField: 'd',
      toJsonField: 't',
    ).toJson());

    final got = await vb.collections.posts.get(post.id);
    expect(got, isA<PostsRecord>());
    expect(got.title, 'Typed');
    expect(got.rating, 4.5);
    expect(got.pinned, isTrue);
    expect(got.published, isFalse);
    expect(got.views, 12);
    expect(got.status, 'live');
    expect(got.tags, ['a', 'b']);
    expect(got.author, author.id);
    expect(got.publishAt, at);
    // `edited` is set on update only.
    expect(got.edited, isNull);
    final edited = await vb.collections.posts.update(post.id, {'views': 13});
    expect(edited.edited, isNotNull);
    expect(got.meta, {
      'k': [1, 2]
    });
    expect(got.place, (lat: 51.5, lng: -0.12));
    expect(got.embedding, [0.1, 0.2, 0.3]);
    expect(got.contact, 'ann@example.com');
    expect(got.site, 'https://example.com');
    expect(got.accent, '#ff0000');
    expect(got.classField, 'c');
    expect(got.dataField, 'd');
    expect(got.toJsonField, 't');
    expect(got.body, isNull);
    expect(got.cover, isNull);
    expect(got.gallery, isEmpty);
  }, skip: skip);

  test('unset optional fields read as null; required ones fall back', () async {
    final post = await vb.collections.posts.create(
        const PostsCreate(title: 'Bare', rating: 0, pinned: false).toJson());
    expect(post.views, isNull);
    expect(post.published, isNull);
    expect(post.publishAt, isNull);
    expect(post.place, isNull);
    expect(post.tags, isEmpty);
    expect(post.embedding, isEmpty);
    expect(PostsRecord(const {}).title, '');
    expect(PostsRecord(const {}).rating, 0);
  }, skip: skip);

  test('group items round-trip, keeping their ids', () async {
    final ship = DateTime.utc(2026, 11, 2);
    final order = await vb.collections.orders.create(OrdersCreate(
      items: [
        OrdersItemsItem(
            sku: 'A-1',
            qty: 2,
            price: 9.5,
            gift: true,
            size: 'M',
            tags: ['x'],
            shipOn: ship,
            extra: {'n': 1},
            classField: 'c',
            toJsonField: 't'),
        const OrdersItemsItem(sku: 'B-2', qty: 1),
      ],
      address: OrdersAddress(city: 'Oslo', since: DateTime.utc(2020)),
    ).toJson());

    final got = await vb.collections.orders.get(order.id);
    expect(got.items, hasLength(2));
    final first = got.items.first;
    expect(first.id, matches(RegExp(r'^[a-z0-9]{15}$')));
    expect(first.sku, 'A-1');
    expect(first.qty, 2);
    expect(first.price, 9.5);
    expect(first.gift, isTrue);
    expect(first.size, 'M');
    expect(first.tags, ['x']);
    expect(first.shipOn, ship);
    expect(first.extra, {'n': 1});
    expect(first.classField, 'c');
    expect(first.toJsonField, 't');
    expect(got.items.last.price, isNull);
    expect(got.items.last.tags, isNull);
    expect(got.address?.city, 'Oslo');
    expect(got.address?.zip, isNull);
    expect(got.address?.since, DateTime.utc(2020));

    // Sent back as read, the items keep their ids.
    final again = await vb.collections.orders.update(order.id, {
      'items': [for (final i in got.items) i.toJson()]
    });
    expect(
        [for (final i in again.items) i.id], [for (final i in got.items) i.id]);
  }, skip: skip);

  test('a singleton has its typed record', () async {
    final s = await vb.collections.siteSettings.update({'headline': 'Hello'});
    expect(s, isA<SiteSettingsRecord>());
    expect(s.headline, 'Hello');
  }, skip: skip);
}
