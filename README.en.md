# ShikiMusic

[Русский](README.md) · **English**

A Flutter music player for **Windows, Android, and Linux**.
Local music and videos, synced lyrics, playlists, listening statistics,
and Discord Rich Presence. Everyday offline listening requires neither
an account nor a continuously running server. The Linux version has been
tested on Arch Linux.

## Features

- Downloaded MP3 playback, a playback queue, shuffle, repeat, and favorites.
- MP4 music video downloads and local playback, with an option to disable video.
- Synced LRC lyrics and a dedicated full-screen lyrics view.
- Offline search by title, artist, and phrases from saved lyrics.
  Lyric words must be consecutive and in the same order; matching ignores
  case, punctuation, and the Russian ё/е distinction.
- Playlists with custom artwork and a circular crop preview.
  Tracks follow their insertion order by default and can be reordered by dragging.
- Artist pages with biographies, albums, and collaborations when the catalog
  contains the corresponding metadata.
- Queued downloads for all tracks in a list or album.
- Search and imports through a separate server: individual tracks,
  recordings selected by URL, and YouTube / YouTube Music playlists by URL.
- Catalog update checks and prompts to update downloaded files.
- Local listening statistics without registration.
- ZIP library backups and transfer between devices.
- Accent colors, custom backgrounds, and interface languages.
  Russian, English, and Japanese are available; translation coverage varies by section.
- System playback controls on desktop platforms and Android.

The `ios`, `macos`, and `web` source directories do not imply confirmed support
for those platforms.

## Discord

On desktop platforms, the player uses the **Listening** activity type to display
the track, artists, and playback information. Settings let you show the current
lyric line in the compact status and hide the GitHub button.

Track artwork is looked up in this order: **iTunes → Deezer → Last.fm**.
If no matching track artwork is found, the player tries existing animated album
artwork through **MusicBrainz + Cover Art Archive**. Remaining fallbacks are
a public catalog cover, an artist portrait, or the player icon.
Matching track artwork takes priority over animation.

The desktop Discord client must be running with activity sharing enabled.
Artwork lookups run directly in the player and do not need your local server.
Searching and loading artwork require internet access. Discord cannot fetch
images from `localhost` or your private network. Artwork and animation
availability depends on the external catalogs.

## Library and server

The server is distributed separately and **is not included in this repository**.
It provides the catalog, search, imports, and downloads of new tracks, videos,
and updates. Building the player does not include a server or a preloaded music library.

Downloaded music, videos, and saved lyrics remain available without the server.
Playlists, favorites, settings, and statistics are stored on the device.

Change the server address in Settings. The default is `http://127.0.0.1:8000`.
You can also set it when running or building the app:

```bash
flutter run -d windows --dart-define=SHIKI_SERVER_URL=http://127.0.0.1:8000
```

On Android, `127.0.0.1` refers to the phone itself. To reach a server running
on your computer, enter an address accessible from the phone.

While the player is open and the server is reachable, changes are checked
approximately every 12 seconds. Library metadata is refreshed, and changed
downloaded files are offered as updates. If an updated MP3 is currently playing,
the new file is applied the next time that track starts.

## Playlists and statistics

Replacing the app build preserves your library as long as the app continues
using the same data directory. By default, this is `ShikiMusic` inside the
documents directory provided by the OS, usually the user's Documents folder on desktop.

**Clear cache** removes disposable artwork while preserving playlists,
favorites, statistics, and downloaded MP3/MP4 files. Clearing app data through
the OS is a different operation: create a backup first.

Statistics are available in Settings and stored locally in SQLite: listening
time, top tracks and artists, daily activity, and time spent using the app.
Choose 7 days, 30 days, the current year, all time, or a custom date range.
Statistics also have separate export and import actions. Pauses and seeking
do not count as listening time. History starts when you begin using this feature;
earlier listening activity is not reconstructed automatically.

## Backup and library transfer

1. Open **Settings → Transfer and backup → Create archive**.
2. Choose whether to include MP3/MP4 files. Include media to transfer an offline library.
3. Copy the ZIP archive to the other device.
4. Select it in the same section of the player and restart the app to apply it.

The archive includes the catalog, playlists and their artwork, favorites, lyrics,
settings, and statistics. It excludes the server database, Django credentials,
and app executables.

Import merges lists, preserves track order, and leaves existing music files
in place. Applying settings is optional. Reimporting does not double statistics;
conflicting IDs from different libraries stop the import. A pending import
can be canceled. Before applying it, original JSON files are saved in
a `transfer_restore_*` directory inside the app's data directory.

Archives use streaming ZIP without additional compression: up to 64 GB total
and 8 GB per media file. Import accepts archives produced by the player;
recompressing them with another tool is not supported. Export and verification
run outside the UI isolate. Import needs free space for extraction and copies
of the files being added.

**Backups are private:** they may contain your server address and listening
history. Do not publish them alongside the source code.

## Build from source

Use a Flutter SDK whose Dart version satisfies `^3.11.1` in
[`pubspec.yaml`](pubspec.yaml). Each platform also needs its native build tools.
After installing the toolchain:

```bash
git clone https://github.com/cursedworld/ShikiMusic.git
cd ShikiMusic
flutter doctor -v
flutter pub get
```

### Windows

Install the [Flutter Windows toolchain](https://docs.flutter.dev/platform-integration/windows/setup),
including Visual Studio with **Desktop development with C++**.

```bash
flutter build windows --release
```

Output: `build/windows/x64/runner/Release/Shiki.exe`.
Distribute the **entire `Release` directory**, including `data` and DLL files,
rather than the EXE alone.

### Android

Set up the Android SDK and check it with `flutter doctor -v`.

```bash
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`.
The current release configuration uses a debug signing key. Configure
a permanent signing key for your own distribution; keep the same application ID
and signing key when updating an installed app.

### Arch Linux

Build the Linux version on Linux. A Windows build does not produce a Linux binary.
Install Flutter SDK and the native dependencies:

```bash
sudo pacman -S --needed clang cmake ninja pkgconf gtk3 gstreamer gst-plugins-base gst-plugins-good gst-libav mpv libepoxy
flutter config --enable-linux-desktop
flutter doctor -v
flutter pub get
flutter build linux --release
```

The audio backend needs GStreamer; the video backend needs libmpv. Arch's
[`mpv` package](https://archlinux.org/packages/extra/x86_64/mpv/files/)
includes `libmpv.so` and `mpv.pc`. The first build may also download mimalloc,
which the native video backend uses.

For x64, output is in `build/linux/x64/release/bundle/`.
Run `./build/linux/x64/release/bundle/music_player`.
Distribute the entire `bundle`, preserving its `lib` and `data` directories.

## Validation

```bash
flutter analyze
flutter test
```

The repository includes tests for playlists, lyrics, library updates, backups,
statistics, and Discord integration. Also check native audio, video,
and integrations on the target OS.

## License

[Apache License 2.0](LICENSE). Third-party dependencies retain their own licenses.
