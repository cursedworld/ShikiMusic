# ShikiMusic

Музыкальный плеер, написанный на Flutter для Android, Windows, Linux и iOS.

## Local server

The server is optional during normal offline playback. Its default address is
`http://192.168.31.13:8000`. Override it at build or run time with a Dart
define:

```bash
flutter run --dart-define=SHIKI_SERVER_URL=http://127.0.0.1:8000
```

For Android, use an address reachable from the phone. MP3 and MP4 downloads are
stored locally; video playback uses the local MP4 file.

## Arch Linux

Install Flutter's standard Linux desktop build dependencies plus the native
video runtime:

```bash
sudo pacman -S mpv libepoxy
```

`mpv` must provide `mpv.pc` for the build. The first Linux build may also fetch
the statically linked mimalloc allocator used to reduce native playback leaks.
