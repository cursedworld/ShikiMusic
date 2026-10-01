# Shiki local changes

Based on `flutter_discord_rpc` 1.1.0 by KRTirtho (MIT; see LICENSE).

Listening activities include Discord's documented `status_display_type: 2`,
so the member list shows the existing track/artist details. State, artwork,
timestamps, buttons, and the generated Flutter/Rust bridge ABI are preserved.
Other activity types retain the upstream display behavior.

The upstream Rust dependency is pinned to its original lockfile revision.
The IPC command uses the same envelope as upstream `set_activity`.

Validation:

```sh
cargo test --manifest-path third_party/flutter_discord_rpc/Cargo.toml
```
