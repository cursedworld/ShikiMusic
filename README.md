# ShikiMusic

Музыкальный плеер, написанный на Flutter для Android, Windows, Linux и iOS.

## Local server

The server is optional during normal offline playback. Its default address is
`http://127.0.0.1:8000`. Override it at build or run time with a Dart
define:

```bash
flutter run --dart-define=SHIKI_SERVER_URL=http://127.0.0.1:8000
```

For Android, use an address reachable from the phone. MP3 and MP4 downloads are
stored locally; video playback uses the local MP4 file.

## Перенос библиотеки

Настройки → **Перенос и резервная копия** → **Создать архив**.
ZIP содержит плейлисты с обложками, избранное, каталог, тексты, настройки
и статистику. MP3/MP4 включаются отдельным переключателем. Серверная БД,
учётные данные Django и исполняемые файлы не включаются.

На другом устройстве выберите архив в том же разделе и перезапустите плеер.
Импорт объединяет списки, сохраняет порядок треков и не заменяет существующую
музыку. Применение настроек — отдельный выбор. Повторный импорт не удваивает
статистику. Конфликт ID разных музыкальных библиотек останавливает импорт.
Ожидающий импорт можно отменить; перед применением исходные JSON сохраняются
в папке `transfer_restore_*` внутри данных плеера.

Архив личный: в нём могут быть адрес сервера и история прослушивания.
На Android адрес `127.0.0.1` относится к телефону, а не к компьютеру.
Для офлайн-прослушивания сервер не нужен.

Используется потоковый ZIP без дополнительного сжатия: до 64 ГБ всего,
до 8 ГБ на медиафайл. Импорт принимает архивы, созданные плеером; стороннее
пересжатие ZIP не поддерживается. Экспорт и проверка работают вне UI-потока.
Для импорта нужно место под временную распаковку и копии добавляемых файлов.

## Arch Linux

Install Flutter's standard Linux desktop build dependencies plus the native
video runtime:

```bash
sudo pacman -S mpv libepoxy
```

`mpv` must provide `mpv.pc` for the build. The first Linux build may also fetch
the statically linked mimalloc allocator used to reduce native playback leaks.
