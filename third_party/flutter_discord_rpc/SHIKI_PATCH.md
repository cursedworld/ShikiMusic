# Shiki local changes

Based on `flutter_discord_rpc` 1.1.0 by KRTirtho (MIT; see LICENSE).

Listening activities default to Discord's documented `status_display_type: 2`,
so the member list shows the existing track/artist details. The optional
`RPCActivity.statusDisplayType` selects Name (0), State (1), or Details (2)
without swapping the profile card's details and state fields. Other activity
types retain upstream behavior unless an explicit display type is supplied.

The Flutter/Rust bridge is regenerated with `flutter_rust_bridge_codegen` 2.11.1
when the activity model changes; rebuild the native library together with Dart.
The Dart SDK minimum is 3.3 because the generated web bridge uses extension types.

Regenerate from this package directory, with `cargo-expand` available:

```sh
flutter_rust_bridge_codegen generate --rust-input crate::api --rust-root rust --dart-output lib/src/rust --dart-root . --no-auto-upgrade-dependency --no-dart-fix --no-deps-check --no-add-mod-to-lib
```

The upstream Rust dependency is pinned to its original lockfile revision.
The IPC command uses the same envelope as upstream `set_activity`.

Validation:

```sh
cargo test --manifest-path third_party/flutter_discord_rpc/Cargo.toml
```
