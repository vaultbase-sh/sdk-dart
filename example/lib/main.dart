import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vaultbase_flutter/vaultbase_flutter.dart';

/// The server, from `--dart-define=VAULTBASE_URL=...`. The Android emulator
/// reaches the host machine at 10.0.2.2.
String get serverUrl {
  const url = String.fromEnvironment('VAULTBASE_URL');
  if (url.isNotEmpty) return url;
  return !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? 'http://10.0.2.2:8091'
      : 'http://localhost:8091';
}

/// The OAuth redirect; its scheme is registered in AndroidManifest.xml and
/// must be in the server's allowed redirects.
const oauthRedirect = 'dev.vaultbase.example://oauth';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final vb = Vaultbase(serverUrl,
      authStore: kIsWeb ? PrefsAuthStore() : SecureAuthStore());
  await vb.authStore.ready;
  VaultbaseLifecycle(vb);
  runApp(NotesApp(vb: vb));
}

class NotesApp extends StatelessWidget {
  const NotesApp({super.key, required this.vb});

  final Vaultbase vb;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Vaultbase notes',
        theme: ThemeData(colorSchemeSeed: Colors.indigo),
        darkTheme: ThemeData(
            colorSchemeSeed: Colors.indigo, brightness: Brightness.dark),
        home: StreamBuilder<StoredAuth?>(
          stream: vb.authStore.onChange,
          initialData: vb.authStore.current,
          builder: (context, snap) =>
              snap.data == null ? SignInPage(vb: vb) : NotesPage(vb: vb),
        ),
      );
}

class SignInPage extends StatefulWidget {
  const SignInPage({super.key, required this.vb});

  final Vaultbase vb;

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  CollectionAuth get _users => widget.vb.auth.collection('users');

  Future<void> _run(Future<AuthResult?> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await action();
      if (result is MfaRequired && mounted) await _finishMfa(result);
      if (result is MergeRequired) {
        _error = 'That email already has an account. Sign in with your '
            'password to link ${result.provider}.';
      }
    } on CancelledException {
      // The browser was closed.
    } on VaultbaseException catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finishMfa(MfaRequired mfa) async {
    final code = await showDialog<String>(
      context: context,
      builder: (context) {
        final field = TextEditingController();
        return AlertDialog(
          title: const Text('Two-factor code'),
          content: TextField(
            controller: field,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Code from your authenticator app'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, field.text.trim()),
                child: const Text('Verify')),
          ],
        );
      },
    );
    if (code == null || code.isEmpty) return;
    await _users.loginMfa(mfa.mfaToken, code: code);
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Notes',
                        style: Theme.of(context).textTheme.headlineMedium),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      decoration: const InputDecoration(labelText: 'Password'),
                      onSubmitted: (_) => _signIn(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                        onPressed: _busy ? null : _signIn,
                        child: const Text('Sign in')),
                    const SizedBox(height: 8),
                    OutlinedButton(
                        onPressed: _busy ? null : _register,
                        child: const Text('Create account')),
                    const SizedBox(height: 8),
                    TextButton(
                        onPressed: _busy ? null : _github,
                        child: const Text('Continue with GitHub')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  void _signIn() =>
      _run(() => _users.login(_email.text.trim(), _password.text));

  void _register() => _run(() async {
        await _users.register(_email.text.trim(), _password.text);
        return _users.login(_email.text.trim(), _password.text);
      });

  void _github() =>
      _run(() => _users.signInWithOAuth2('github', redirectUri: oauthRedirect));
}

class NotesPage extends StatefulWidget {
  const NotesPage({super.key, required this.vb});

  final Vaultbase vb;

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  final _input = TextEditingController();
  List<RecordModel> _notes = [];
  RealtimeSubscription? _live;
  String? _error;

  Collection<RecordModel> get _collection => widget.vb.collection('notes');

  @override
  void initState() {
    super.initState();
    // Other devices' changes arrive here; this device's own changes too, so
    // the list is updated from events only.
    _live = _collection.subscribe(_onEvent);
    _load();
  }

  Future<void> _load() async {
    try {
      final page = await _collection.list(sort: '-created', perPage: 100);
      if (mounted) setState(() => _notes = page.items);
    } on VaultbaseException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _onEvent(RealtimeEvent e) {
    setState(() {
      _notes = [
        if (e.action == RealtimeAction.create) e.record!,
        for (final n in _notes)
          if (n.id != e.id)
            n
          else if (e.action == RealtimeAction.update)
            e.record!,
      ];
    });
  }

  Future<void> _add() async {
    final body = _input.text.trim();
    if (body.isEmpty) return;
    _input.clear();
    try {
      await _collection
          .create({'body': body, 'owner': widget.vb.authStore.record?['id']});
    } on VaultbaseException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _delete(RecordModel note) async {
    try {
      await _collection.delete(note.id);
    } on VaultbaseException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  void dispose() {
    _live?.cancel();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title:
              Text(widget.vb.authStore.record?['email'] as String? ?? 'Notes'),
          actions: [
            StreamBuilder<RealtimeState>(
              stream: widget.vb.realtime.states,
              initialData: widget.vb.realtime.state,
              builder: (context, snap) => Tooltip(
                message: 'Realtime: ${snap.data?.name}',
                child: Icon(snap.data == RealtimeState.open
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off_outlined),
              ),
            ),
            IconButton(
              tooltip: 'Sign out',
              icon: const Icon(Icons.logout),
              onPressed: () => unawaited(widget.vb.auth.logout()),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_error != null)
              MaterialBanner(
                content: Text(_error!),
                actions: [
                  TextButton(
                      onPressed: () => setState(() => _error = null),
                      child: const Text('Dismiss')),
                ],
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: _notes.isEmpty
                    ? ListView(children: const [
                        Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: Text('No notes yet.')),
                        ),
                      ])
                    : ListView.builder(
                        itemCount: _notes.length,
                        itemBuilder: (context, i) {
                          final note = _notes[i];
                          return Dismissible(
                            key: ValueKey(note.id),
                            onDismissed: (_) => _delete(note),
                            child: ListTile(
                              title: Text(note.getString('body')),
                              subtitle: Text(note.createdAt
                                  .toLocal()
                                  .toString()
                                  .substring(0, 16)),
                            ),
                          );
                        },
                      ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        decoration: const InputDecoration(hintText: 'New note'),
                        onSubmitted: (_) => _add(),
                      ),
                    ),
                    IconButton(
                        tooltip: 'Add',
                        onPressed: _add,
                        icon: const Icon(Icons.send)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}
