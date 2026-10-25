# Vaultbase for Dart and Flutter

Clients for [Vaultbase](https://vaultbase.dev), the single-binary backend: records, auth,
files and realtime.

| Package | What it is |
|---|---|
| [`vaultbase`](packages/vaultbase) | The client, pure Dart. Works in Flutter, on the server and in CLIs. |
| [`vaultbase_flutter`](packages/vaultbase_flutter) | Flutter helpers: secure token storage, OAuth sign-in, app lifecycle. |

Both need Dart 3.6 (Flutter 3.27) and a Vaultbase server 0.27 or later. Docs:
[docs.vaultbase.dev/sdk-dart/quick-start](https://docs.vaultbase.dev/sdk-dart/quick-start/).
A complete Flutter app is in [`example/`](example).

## Development

Needs the Flutter SDK (3.27 or later) and [Bun](https://bun.sh) for the integration tests.

```sh
flutter pub get
dart format .
flutter analyze
(cd packages/vaultbase && dart test)          # integration tests need ../vaultbase
(cd packages/vaultbase_flutter && flutter test)
```

The integration tests start a real server from a checkout of
[vaultbase-sh/vaultbase](https://github.com/vaultbase-sh/vaultbase) next to this repo
(`../vaultbase`), or from `VAULTBASE_SERVER_DIR`. Without one they skip.

## License

MIT
