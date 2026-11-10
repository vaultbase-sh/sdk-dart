@Tags(['integration'])
library;

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
    admin = Vaultbase(server.baseUrl,
        authStore: MemoryAuthStore()..save(StoredAuth(server.adminToken)));
    Future<void> create(Map<String, Object?> body) =>
        admin.send('/api/v1/collections', method: 'POST', body: body);
    await create({
      'name': 'authors',
      'type': 'base',
      'fields': [
        {'name': 'name', 'type': 'text', 'required': true},
      ],
    });
    await create({
      'name': 'posts',
      'type': 'base',
      'fields': [
        {'name': 'title', 'type': 'text', 'required': true},
        {'name': 'status', 'type': 'text'},
        {'name': 'views', 'type': 'number'},
        {'name': 'author', 'type': 'relation', 'collection': 'authors'},
      ],
    });
    await create({
      'name': 'site',
      'type': 'singleton',
      'fields': [
        {'name': 'title', 'type': 'text'},
      ],
    });
    await create({
      'name': 'notes',
      'type': 'base',
      'create_rule': '@request.auth.id != ""',
      'fields': [
        {'name': 'body', 'type': 'text'},
      ],
    });
    await create({
      'name': 'members',
      'type': 'auth',
      'create_rule': null,
      'fields': <Object?>[
        {'name': 'nickname', 'type': 'text'},
      ],
    });
    // Anyone can read these.
    await create({
      'name': 'pages',
      'type': 'base',
      'list_rule': null,
      'view_rule': null,
      'fields': [
        {'name': 'title', 'type': 'text'},
      ],
    });
  });

  tearDownAll(() async {
    if (skip != null) return;
    admin.close();
    await server.stop();
  });

  group('records', () {
    test('create, get, update, delete', () async {
      final posts = admin.collection('posts');
      final created = await posts.create({'title': 'Hello', 'views': 3});
      expect(created.id, isNotEmpty);
      expect(created.created, greaterThan(0));

      final read = await posts.get(created.id);
      expect(read.getString('title'), 'Hello');
      expect(read.getInt('views'), 3);

      final updated = await posts.update(created.id, {'title': 'Edited'});
      expect(updated.getString('title'), 'Edited');

      await posts.delete(created.id);
      await expectLater(
          posts.get(created.id),
          throwsA(
              isA<NotFoundException>().having((e) => e.status, 'status', 404)));
    }, skip: skip);

    test('validation errors carry field details', () async {
      await expectLater(
          admin.collection('posts').create({'views': 1}),
          throwsA(isA<ValidationException>()
              .having((e) => e.details.keys, 'fields', contains('title'))));
    }, skip: skip);

    test('list with a built filter, sort, fields and expand', () async {
      final author = await admin.collection('authors').create({'name': 'Ann'});
      final posts = admin.collection('posts');
      for (final (title, views) in [
        ('a "quoted" one', 5),
        ('b', 9),
        ('c', 1)
      ]) {
        await posts.create({
          'title': title,
          'views': views,
          'status': 'list-test',
          'author': author.id
        });
      }
      final page = await posts.list(
        filter: admin.filter(
            'status = {:s} && views >= {:v}', {'s': 'list-test', 'v': 5}),
        sort: '-views',
        expand: 'author',
      );
      expect(page.items.map((r) => r.getInt('views')), [9, 5]);
      expect(page.totalItems, 2);
      expect(page.items.first.expandOne('author')?.getString('name'), 'Ann');

      final quoted = await posts.list(
          filter: admin.filter('title = {:t}', {'t': 'a "quoted" one'}));
      expect(quoted.items.single.getInt('views'), 5);

      final slim = await posts.list(
          filter: 'status = "list-test"', fields: 'id,title', perPage: 1);
      expect(slim.items.single.data.containsKey('views'), isFalse);
      expect(slim.totalPages, 3);

      final lean = await posts.list(
          filter: 'status = "list-test"', exclude: 'views,status', perPage: 1);
      final item = lean.items.single;
      expect(item.data.containsKey('views'), isFalse);
      expect(item.data.containsKey('status'), isFalse);
      expect(item.data.containsKey('title'), isTrue);
      final one =
          await posts.get(item.id, fields: 'title,views', exclude: 'views');
      expect(one.data.keys.toSet(), {'id', 'title'});
    }, skip: skip);

    test('iterate reads every page; skipTotal gives -1 totals', () async {
      final posts = admin.collection('posts');
      for (var i = 0; i < 7; i++) {
        await posts.create({'title': 'it $i', 'status': 'iterate'});
      }
      final titles = await posts
          .iterate(perPage: 3, filter: 'status = "iterate"', sort: 'title')
          .map((r) => r.getString('title'))
          .toList();
      expect(titles, [for (var i = 0; i < 7; i++) 'it $i']);

      final page = await posts.list(
          filter: 'status = "iterate"', perPage: 3, skipTotal: true);
      expect(page.totalItems, -1);
      expect(page.items, hasLength(3));
    }, skip: skip);

    test('aggregate counts by group', () async {
      final posts = admin.collection('posts');
      await posts.create({'title': 'x', 'status': 'agg-a', 'views': 2});
      await posts.create({'title': 'y', 'status': 'agg-a', 'views': 4});
      await posts.create({'title': 'z', 'status': 'agg-b', 'views': 1});
      final rows = await posts.aggregate(
          agg: ['count', 'sum(views)'],
          groupBy: ['status'],
          filter: 'status ~ "agg-"',
          sort: 'status');
      expect(rows, hasLength(2));
      expect(rows.first['status'], 'agg-a');
      expect(rows.first.values, containsAll([2, 6]));
    }, skip: skip);

    test('a stale ETag is refused with PreconditionFailedException', () async {
      final posts = admin.collection('posts');
      final post = await posts.create({'title': 'v1'});
      await posts.get(post.id);
      // Another client changes the record.
      final other = Vaultbase(server.baseUrl,
          authStore: MemoryAuthStore()..save(StoredAuth(server.adminToken)));
      await other
          .collection('posts')
          .update(post.id, {'title': 'v2'}, checkEtag: false);
      other.close();

      await expectLater(posts.update(post.id, {'title': 'v3'}),
          throwsA(isA<PreconditionFailedException>()));
      final forced =
          await posts.update(post.id, {'title': 'v3'}, checkEtag: false);
      expect(forced.getString('title'), 'v3');
    }, skip: skip);

    test('a cancelled request throws CancelledException', () async {
      final token = CancelToken();
      final future = admin.collection('posts').list(cancelToken: token);
      token.cancel();
      await expectLater(future, throwsA(isA<CancelledException>()));
    }, skip: skip);
  });

  test('singleton: get and update with its ETag', () async {
    final site = admin.singleton('site');
    final first = await site.get();
    expect(first.id, isNotEmpty);
    final updated = await site.update({'title': 'My site'});
    expect(updated.getString('title'), 'My site');
    expect((await site.get()).getString('title'), 'My site');
    await expectLater(site.update({'title': 'x'}, ifMatch: '"stale"'),
        throwsA(isA<PreconditionFailedException>()));
  }, skip: skip);

  test('batch runs operations in one request', () async {
    final keep = await admin.collection('posts').create({'title': 'keep'});
    final drop = await admin.collection('posts').create({'title': 'drop'});
    final batch = admin.batch()
      ..create('posts', {'title': 'from batch', 'status': 'batch'})
      ..update('posts', keep.id, {'status': 'batch'})
      ..delete('posts', drop.id)
      ..get('posts', keep.id);
    final results = await batch.run();
    expect(results.map((r) => r.ok), everyElement(isTrue));
    expect(results[0].record?.getString('title'), 'from batch');
    expect(results[3].record?.getString('status'), 'batch');
    // Lists go in a batch of reads.
    final reads = await (admin.batch()
          ..get('posts', keep.id)
          ..list('posts', filter: 'status = "batch"', skipTotal: true))
        .run();
    expect(reads.map((r) => r.ok), everyElement(isTrue));
    await expectLater(
        (admin.batch()
              ..create('posts', {'title': 'x'})
              ..list('posts'))
            .run(),
        throwsA(isA<ValidationException>()));
    await expectLater(admin.collection('posts').get(drop.id),
        throwsA(isA<NotFoundException>()));
  }, skip: skip);

  group('session', () {
    late Vaultbase user;

    setUpAll(() async {
      if (skip != null) return;
      user = Vaultbase(server.baseUrl);
      const creds = {
        'email': 'ann@sdk-dart.test',
        'password': 'a-long-password-1'
      };
      await user.send('/api/v1/auth/members/register',
          method: 'POST', body: creds, skipAuth: true);
      final login = await user.send('/api/v1/auth/members/login',
          method: 'POST', body: creds, skipAuth: true) as Map;
      user.authStore.save(StoredAuth(login['token'] as String,
          record: (login['record'] as Map).cast<String, dynamic>()));
    });

    tearDownAll(() {
      if (skip == null) user.close();
    });

    test('me, refresh and logout', () async {
      expect(user.auth.isSignedIn, isTrue);
      final me = await user.auth.me();
      expect(me['email'], 'ann@sdk-dart.test');

      final before = user.authStore.token;
      expect(await user.auth.refresh(), isTrue);
      expect(user.authStore.token, isNot(before));
      expect(user.authStore.record?['email'], 'ann@sdk-dart.test');
      expect((await user.auth.me())['email'], 'ann@sdk-dart.test');

      final signedOut = user.authStore.token!;
      await user.auth.logout();
      expect(user.authStore.current, isNull);

      // The logged-out token is refused, and a client holding it is
      // signed out rather than retrying forever.
      final stale = Vaultbase(server.baseUrl,
          authStore: MemoryAuthStore()..save(StoredAuth(signedOut)));
      await expectLater(stale.auth.me(), throwsA(isA<AuthException>()));
      expect(stale.authStore.current, isNull);
      stale.close();
    }, skip: skip);

    test('wrong credentials are AuthException.invalid', () async {
      await expectLater(
          Vaultbase(server.baseUrl).send('/api/v1/auth/members/login',
              method: 'POST',
              body: {
                'email': 'ann@sdk-dart.test',
                'password': 'wrong-password'
              },
              skipAuth: true),
          throwsA(isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.invalid)));
    }, skip: skip);
  });

  group('403 reasons (server 0.42)', () {
    test('a 403 says not_signed_in and the operation', () async {
      final anon = Vaultbase(server.baseUrl);
      addTearDown(anon.close);
      await expectLater(
          anon.collection('notes').create({'body': 'x'}),
          throwsA(isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.notSignedIn)
              .having((e) => e.operation, 'operation', AuthOperation.create)
              .having((e) => e.serverReason, 'serverReason', 'not_signed_in')));
    }, skip: skip);

    test('registering a taken email is a ConflictException', () async {
      final members = Vaultbase(server.baseUrl).auth.collection('members');
      await members.register('taken@sdk-dart.test', 'longpassword-123');
      await expectLater(
          members.register('taken@sdk-dart.test', 'longpassword-123'),
          throwsA(
              isA<ConflictException>().having((e) => e.status, 'status', 409)));
    }, skip: skip);
  });

  group('a token the server refuses (server 0.44)', () {
    Matcher expired() => isA<AuthException>()
        .having((e) => e.reason, 'reason', AuthFailure.expired)
        .having((e) => e.status, 'status', 401)
        .having((e) => e.message, 'message', 'Token expired or invalid')
        .having((e) => e.serverReason, 'serverReason', 'token_invalid');

    test('ends the session, on a write and on a public read', () async {
      await admin.collection('pages').create({'title': 'Open'});
      for (final call in <Future<Object?> Function(Vaultbase)>[
        (vb) => vb.collection('notes').create({'body': 'x'}),
        (vb) => vb.collection('pages').list(),
        (vb) => vb.collection('no_such_collection').list(),
      ]) {
        final store = MemoryAuthStore()..save(StoredAuth('not.a.token'));
        final vb = Vaultbase(server.baseUrl, authStore: store);
        addTearDown(vb.close);
        await expectLater(call(vb), throwsA(expired()));
        expect(store.current, isNull);
        // Signed out, the public read works again.
        final page = await vb.collection('pages').list();
        expect(page.items.single.getString('title'), 'Open');
      }
    }, skip: skip);

    test('a signed-out session is refused the same way', () async {
      final vb = Vaultbase(server.baseUrl);
      addTearDown(vb.close);
      const email = 'stale@sdk-dart.test';
      const password = 'a-long-password-1';
      final members = vb.auth.collection('members');
      await members.register(email, password);
      await members.login(email, password);
      final session = vb.authStore.current!;
      expect((await vb.collection('pages').list()).items, isNotEmpty);
      await vb.auth.logout();

      final store = MemoryAuthStore()..save(session);
      final stale = Vaultbase(server.baseUrl, authStore: store);
      addTearDown(stale.close);
      await expectLater(stale.collection('pages').list(), throwsA(expired()));
      expect(store.current, isNull);
    }, skip: skip);

    test('batch and files answer the same', () async {
      for (final call in <Future<Object?> Function(Vaultbase)>[
        (vb) => (vb.batch()..list('pages')).run(),
        (vb) => vb.files.token('pages', 'p1', 'cover', 'a.png'),
        (vb) => vb.files.upload('pages', 'p1', 'cover', [
              UploadFile.fromBytes('a.txt', [1, 2, 3])
            ]),
        (vb) => vb.files.delete('pages', 'p1', 'cover'),
      ]) {
        final store = MemoryAuthStore()..save(StoredAuth('not.a.token'));
        final vb = Vaultbase(server.baseUrl, authStore: store);
        addTearDown(vb.close);
        await expectLater(call(vb), throwsA(expired()));
        expect(store.current, isNull);
      }
    }, skip: skip);

    test('an API token without the scope is forbidden, and kept', () async {
      final minted =
          await admin.send('/api/v1/admin/api-tokens', method: 'POST', body: {
        'name': 'sdk-dart read only',
        'scopes': ['read']
      }) as Map;
      final token = minted['token'] as String;
      expect(token, startsWith('vbat_'));
      final store = MemoryAuthStore()..save(StoredAuth(token));
      final vb = Vaultbase(server.baseUrl, authStore: store);
      addTearDown(vb.close);

      expect((await vb.collection('posts').list(perPage: 1)).page, 1);
      await expectLater(
          vb.collection('posts').create({'title': 'x'}),
          throwsA(isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.forbidden)
              .having((e) => e.status, 'status', 401)
              .having((e) => e.message, 'message',
                  "This API token doesn't have the scope for this request")
              .having((e) => e.serverReason, 'serverReason',
                  'insufficient_scope')));
      expect(store.token, token);
      expect(await vb.auth.refresh(), isFalse);
      expect(store.token, token);
      // Still good for what it may do.
      expect((await vb.collection('posts').list(perPage: 1)).page, 1);

      // Revoked: no longer accepted, and still not cleared.
      await admin.send('/api/v1/admin/api-tokens/${minted['id']}',
          method: 'DELETE');
      await expectLater(
          vb.collection('posts').list(),
          throwsA(isA<AuthException>()
              .having((e) => e.reason, 'reason', AuthFailure.expired)
              .having((e) => e.message, 'message', 'Token expired or invalid')
              .having((e) => e.serverReason, 'serverReason', 'token_invalid')));
      expect(store.token, token);
    }, skip: skip);
  });

  group('unknown keys (server 0.44)', () {
    test('an unknown sort, expand or fields name is a ValidationException',
        () async {
      final warnings = <VaultbaseWarning>[];
      final vb = Vaultbase(server.baseUrl,
          authStore: MemoryAuthStore()..save(StoredAuth(server.adminToken)),
          onWarning: warnings.add,
          printWarnings: PrintWarnings.never);
      addTearDown(vb.close);
      final posts = vb.collection('posts');
      await expectLater(
          posts.list(sort: '-titel'),
          throwsA(isA<ValidationException>()
              .having((e) => e.status, 'status', 400)
              .having((e) => e.message, 'message', contains('titel'))
              .having((e) => e.details, 'details',
                  {'sort': "unknown sort field 'titel'"})));
      await expectLater(
          posts.list(expand: 'autor', fields: 'id,titel'),
          throwsA(isA<ValidationException>().having((e) => e.details.keys,
              'details', unorderedEquals(['expand', 'fields']))));
      expect(warnings, isEmpty);
    }, skip: skip);

    test('the names the SDK and its examples send are accepted', () async {
      final posts = admin.collection('posts');
      await posts.list(
          sort: '-created,updated,id,title',
          fields: 'id,created,updated,title',
          expand: 'author',
          perPage: 1);
      await posts.iterate(sort: '-created', perPage: 50).take(1).toList();
    }, skip: skip);

    test('a body key that is not a field is a ValidationException', () async {
      final posts = admin.collection('posts');
      await expectLater(
          posts.create({'title': 'x', 'colour': 'red'}),
          throwsA(isA<ValidationException>()
              .having((e) => e.status, 'status', 400)
              .having((e) => e.details, 'details',
                  {'colour': "unknown field 'colour' in body"})));
      final post = await posts.create({'title': 'x'});
      await expectLater(
          posts.update(post.id, {'colour': 'red'}),
          throwsA(isA<ValidationException>()
              .having((e) => e.details.keys, 'details', ['colour'])));
      await expectLater(
          admin.singleton('site').update({'colour': 'red'}),
          throwsA(isA<ValidationException>()
              .having((e) => e.details.keys, 'details', ['colour'])));
    }, skip: skip);

    test('a fetched record can be saved back as it came', () async {
      final author = await admin.collection('authors').create({'name': 'Bo'});
      final posts = admin.collection('posts');
      final post =
          await posts.create({'title': 'Round trip', 'author': author.id});
      final read = await posts.get(post.id, expand: 'author');
      expect(
          read.data.keys,
          containsAll([
            'id',
            'created',
            'updated',
            'collectionId',
            'collectionName',
            'expand'
          ]));
      final saved =
          await posts.update(post.id, {...read.toJson(), 'title': 'Saved'});
      expect(saved.getString('title'), 'Saved');

      final site = admin.singleton('site');
      final siteNow = await site.get();
      expect(
          (await site.update({...siteNow.toJson(), 'title': 'Again'}))
              .getString('title'),
          'Again');

      // An auth record carries columns that aren't fields.
      final members = Vaultbase(server.baseUrl).auth.collection('members');
      final registered =
          await members.register('roundtrip@sdk-dart.test', 'longpassword-123');
      final member = await admin.collection('members').get(registered.id);
      expect(
          member.data.keys,
          containsAll(
              ['email', 'email_verified', 'totp_enabled', 'is_anonymous']));
      final renamed = await admin
          .collection('members')
          .update(member.id, {...member.toJson(), 'nickname': 'Rt'});
      expect(renamed.getString('nickname'), 'Rt');
    }, skip: skip);
  });
}
