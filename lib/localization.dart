import '../globals.dart';

/// Simple in-app localization. Returns the translated string for [key]
/// based on the current [languageNotifier] value (`ru`, `en` or `ja`).
String tr(String key) {
  final lang = languageNotifier.value;
  final map = _translations[key];
  if (map == null) return key;

  // Japanese falls back to English for missing keys.
  if (lang == 'ja') {
    return map['ja'] ?? map['en'] ?? key;
  }
  return map[lang] ?? map['en'] ?? key;
}

const Map<String, Map<String, String>> _translations = {
  'wait_for_downloads': {
    'ru': 'Дождись завершения скачивания перед очисткой кэша.',
    'en': 'Wait for downloads to finish before clearing the cache.',
    'ja': 'ダウンロード完了後にキャッシュを削除してください。',
  },
  'track_updates': {
    'ru': 'Доступны обновления треков',
    'en': 'Track updates available',
    'ja': '楽曲の更新があります',
  },
  'track_updates_hint': {
    'ru':
        'Старые файлы остаются. Новый MP3 и текст применятся при следующем запуске трека.',
    'en':
        'Original files are kept. Updated audio and lyrics apply next time you start the track.',
    'ja': '元のファイルは保持されます。更新は次回の再生時に適用されます。',
  },
  'review_updates': {'ru': 'Посмотреть', 'en': 'Review', 'ja': '確認'},
  'update_track': {'ru': 'Обновить', 'en': 'Update', 'ja': '更新'},
  'update_later': {'ru': 'Позже', 'en': 'Later', 'ja': '後で'},
  'updating_track': {
    'ru': 'Обновление трека',
    'en': 'Updating track',
    'ja': '更新中',
  },
  'track_update_failed': {
    'ru': 'Не удалось обновить. Старый файл сохранён. Можно повторить.',
    'en': 'Update failed. Original file is safe. Try again.',
    'ja': '更新に失敗しました。元のファイルは保持されています。',
  },
  'tracks_up_to_date': {
    'ru': 'Все треки обновлены',
    'en': 'All tracks are up to date',
    'ja': 'すべて更新済みです',
  },
  // ── Navigation / Home ──
  'sidebar_home': {'ru': 'Главная', 'en': 'Home', 'ja': 'ホーム'},
  'sidebar_favorites': {'ru': 'Избранное', 'en': 'Favorites', 'ja': 'お気に入り'},
  'sidebar_downloaded': {
    'ru': 'Загруженное',
    'en': 'Downloaded',
    'ja': 'ダウンロード済み',
  },
  'playlists': {'ru': 'ПЛЕЙЛИСТЫ', 'en': 'PLAYLISTS', 'ja': 'プレイリスト'},
  'create_playlist': {
    'ru': 'Создать плейлист',
    'en': 'Create Playlist',
    'ja': 'プレイリストを作成',
  },
  'settings': {'ru': 'Настройки', 'en': 'Settings', 'ja': '設定'},
  'search_hint_senpai': {
    'ru': 'Поиск треков, исполнителей...',
    'en': 'Search tracks, artists...',
    'ja': '曲、アーティストを検索...',
  },
  'download_all': {
    'ru': 'Скачать всё',
    'en': 'Download All',
    'ja': 'すべてダウンロード',
  },
  'nav_home': {'ru': 'Главная', 'en': 'Home', 'ja': 'ホーム'},
  'nav_favorites': {'ru': 'Избранное', 'en': 'Favorites', 'ja': 'お気に入り'},
  'nav_downloaded': {'ru': 'Загруженное', 'en': 'Downloaded', 'ja': 'ダウンロード済み'},

  // ── Settings ──
  'settings_title': {'ru': 'Настройки', 'en': 'Settings', 'ja': '設定'},
  'custom_bg_title': {
    'ru': 'Пользовательский фон',
    'en': 'Custom Background',
    'ja': 'カスタム背景',
  },
  'custom_bg_active': {
    'ru': 'Пользовательский фон (Активен)',
    'en': 'Custom Background (Active)',
    'ja': 'カスタム背景 (有効)',
  },
  'upload_bg': {
    'ru': 'Загрузить свой фон',
    'en': 'Upload Background Image',
    'ja': '背景画像をアップロード',
  },
  'select_image': {
    'ru': 'Выбрать картинку',
    'en': 'Select Image',
    'ja': '画像を選択',
  },
  'color_theme': {'ru': 'Цветовая тема', 'en': 'Color Theme', 'ja': 'カラーテーマ'},
  'language': {'ru': 'Язык', 'en': 'Language', 'ja': '言語'},
  'vinyl_rotation': {
    'ru': 'Вращение винила',
    'en': 'Vinyl Rotation',
    'ja': 'ビニール回転',
  },
  'vinyl_rotation_desc': {
    'ru': 'Анимация обложки',
    'en': 'Cover Animation',
    'ja': 'カバーアニメーション',
  },
  'vinyl_rotation_hint': {
    'ru': 'Включает вращение обложки при воспроизведении',
    'en': 'Spins the cover art while playing',
    'ja': '再生中にカバーアートを回転させる',
  },
  'storage': {'ru': 'Хранилище', 'en': 'Storage', 'ja': 'ストレージ'},
  'clear_cache': {'ru': 'Очистить кэш', 'en': 'Clear Cache', 'ja': 'キャッシュを消去'},
  'clear_cache_desc': {
    'ru': 'Очистить обложки; музыка и видео останутся',
    'en': 'Clear artwork; keep music and videos',
    'ja': '画像キャッシュのみ消去。音楽と動画は保持',
  },
  'clear_cache_confirm': {
    'ru': 'Подтвердить очистку',
    'en': 'Confirm clearing',
    'ja': '消去を確認',
  },
  'clear_cache_body': {
    'ru': 'Удалить кэш обложек? Треки, видео, тексты и плейлисты останутся.',
    'en':
        'Clear cached artwork? Tracks, videos, lyrics and playlists will remain.',
    'ja': '画像キャッシュを消去しますか？曲、動画、歌詞、プレイリストは保持されます。',
  },
  'cache_clear_failed': {
    'ru': 'Кэш очищен не полностью. Файлы музыки сохранены.',
    'en': 'Cache clearing incomplete. Music files preserved.',
    'ja': 'キャッシュの消去は未完了。音楽は保持されています。',
  },
  'download_started': {
    'ru': 'Загрузка началась',
    'en': 'Download started',
    'ja': 'ダウンロード開始',
  },
  'download_complete': {
    'ru': 'Загрузка завершена',
    'en': 'Download complete',
    'ja': 'ダウンロード完了',
  },
  'download_partial': {
    'ru': 'Загружено частично',
    'en': 'Partially downloaded',
    'ja': '一部ダウンロード完了',
  },
  'download_failed': {
    'ru': 'Не удалось скачать',
    'en': 'Download failed',
    'ja': 'ダウンロード失敗',
  },
  'download_retry': {'ru': 'Повторить', 'en': 'Retry', 'ja': '再試行'},
  'download_details': {
    'ru': 'Подробности загрузки',
    'en': 'Download details',
    'ja': 'ダウンロード詳細',
  },
  'download_audio': {'ru': 'Аудио', 'en': 'Audio', 'ja': '音声'},
  'download_video': {'ru': 'Видео', 'en': 'Video', 'ja': '動画'},
  'download_cover': {'ru': 'Обложка', 'en': 'Artwork', 'ja': '画像'},
  'download_lyrics': {'ru': 'Текст', 'en': 'Lyrics', 'ja': '歌詞'},
  'download_skipped': {
    'ru': 'Уже скачано',
    'en': 'Already downloaded',
    'ja': 'ダウンロード済み',
  },
  'confirm_track_metadata': {
    'ru': 'Проверьте данные трека',
    'en': 'Check track information',
    'ja': '曲情報を確認',
  },
  'metadata_confirmation_hint': {
    'ru':
        'Автор не подтверждён источником. Укажите исполнителя, не владельца канала.',
    'en': 'Artist not confirmed by source. Enter performer, not channel owner.',
    'ja': 'アーティスト未確認。投稿者ではなく演奏者を入力してください。',
  },
  'track_title': {'ru': 'Название трека', 'en': 'Track title', 'ja': '曲名'},
  'track_artist': {'ru': 'Исполнитель', 'en': 'Artist', 'ja': 'アーティスト'},
  'track_album': {'ru': 'Альбом', 'en': 'Album', 'ja': 'アルバム'},
  'confirm_import': {
    'ru': 'Подтвердить и скачать',
    'en': 'Confirm and download',
    'ja': '確認してダウンロード',
  },
  'import_album': {
    'ru': 'Импорт альбома по ссылке',
    'en': 'Import album by link',
    'ja': 'リンクからアルバムを取込',
  },
  'import_partial': {
    'ru': 'Альбом импортирован частично',
    'en': 'Album partially imported',
    'ja': 'アルバムの一部を取込',
  },
  'import_failed': {
    'ru': 'Не удалось импортировать альбом',
    'en': 'Album import failed',
    'ja': 'アルバム取込失敗',
  },
  'import_complete': {
    'ru': 'Альбом импортирован',
    'en': 'Album imported',
    'ja': 'アルバム取込完了',
  },
  'search_failed': {
    'ru': 'Поиск не удался',
    'en': 'Search failed',
    'ja': '検索失敗',
  },
  'invalid_track': {
    'ru': 'Некорректные данные трека',
    'en': 'Invalid track information',
    'ja': '曲情報が無効',
  },
  'library_not_ready': {
    'ru': 'Библиотека ещё загружается',
    'en': 'Library is loading',
    'ja': 'ライブラリを読込中',
  },
  'server_address': {
    'ru': 'Адрес сервера',
    'en': 'Server address',
    'ja': 'サーバーアドレス',
  },
  'server_address_hint': {
    'ru': 'http://127.0.0.1:8000',
    'en': 'http://127.0.0.1:8000',
    'ja': 'http://127.0.0.1:8000',
  },
  'server_test': {
    'ru': 'Проверить соединение',
    'en': 'Test connection',
    'ja': '接続テスト',
  },
  'server_connected': {
    'ru': 'Сервер доступен',
    'en': 'Server connected',
    'ja': 'サーバーに接続済み',
  },
  'server_unavailable': {
    'ru': 'Сервер недоступен',
    'en': 'Server unavailable',
    'ja': 'サーバーに接続できません',
  },
  'server_invalid': {
    'ru': 'Нужен адрес HTTP или HTTPS без пароля',
    'en': 'Enter HTTP or HTTPS URL without credentials',
    'ja': '認証情報のないHTTP/HTTPSアドレスを入力',
  },
  'invalid_album_link': {
    'ru': 'Нужна ссылка на альбом или плейлист YouTube',
    'en': 'Enter a YouTube album or playlist link',
    'ja': 'YouTubeアルバムまたはプレイリストのリンクを入力',
  },
  'download_library': {
    'ru': 'Скачать всю библиотеку',
    'en': 'Download library',
    'ja': 'ライブラリ全体をダウンロード',
  },
  'video_not_found': {
    'ru': 'Клип не найден',
    'en': 'Video not found',
    'ja': '動画が見つかりません',
  },
  'connection_timeout': {
    'ru': 'Время ожидания истекло',
    'en': 'Connection timed out',
    'ja': '接続タイムアウト',
  },
  'import_progress': {
    'ru': 'Импорт альбома',
    'en': 'Importing album',
    'ja': 'アルバム取込中',
  },
  'album_link_hint': {
    'ru': 'Ссылка на альбом / плейлист YouTube Music',
    'en': 'YouTube Music album / playlist link',
    'ja': 'YouTube Musicのアルバム／プレイリストリンク',
  },
  'close': {'ru': 'Закрыть', 'en': 'Close', 'ja': '閉じる'},
  'download_album': {
    'ru': 'Скачать альбом',
    'en': 'Download album',
    'ja': 'アルバムをダウンロード',
  },
  'download_all_tracks': {
    'ru': 'Скачать все треки артиста',
    'en': 'Download all artist tracks',
    'ja': 'アーティストの全曲をダウンロード',
  },
  'playlist_image_failed': {
    'ru': 'Не удалось сохранить обложку плейлиста',
    'en': 'Could not save playlist artwork',
    'ja': 'プレイリスト画像を保存できません',
  },
  'server_save': {
    'ru': 'Сохранить адрес',
    'en': 'Save address',
    'ja': 'アドレスを保存',
  },
  'server_saved': {
    'ru': 'Сохранено. Адрес применится после перезапуска плеера.',
    'en': 'Saved. Restart the player to use this address.',
    'ja': '保存しました。再起動後に適用されます。',
  },
  'server_save_failed': {
    'ru': 'Не удалось сохранить адрес',
    'en': 'Could not save address',
    'ja': 'アドレスを保存できません',
  },
  'cancel': {'ru': 'Отмена', 'en': 'Cancel', 'ja': 'キャンセル'},
  'clear': {'ru': 'Очистить', 'en': 'Clear', 'ja': '消去'},
  'cache_cleared': {
    'ru': 'Кэш очищен',
    'en': 'Cache cleared',
    'ja': 'キャッシュを消去しました',
  },
  'about': {'ru': 'О приложении', 'en': 'About', 'ja': 'アプリについて'},
  'version': {'ru': 'Версия', 'en': 'Version', 'ja': 'バージョン'},
  'personal_player': {
    'ru': 'Персональный музыкальный плеер',
    'en': 'Personal music player',
    'ja': 'パーソナルミュージックプレイヤー',
  },

  // ── Color names ──
  'color_red': {'ru': 'Красный', 'en': 'Red', 'ja': '赤'},
  'color_blue': {'ru': 'Синий', 'en': 'Blue', 'ja': '青'},
  'color_purple': {'ru': 'Фиолетовый', 'en': 'Purple', 'ja': '紫'},
  'color_green': {'ru': 'Зелёный', 'en': 'Green', 'ja': '緑'},
  'color_orange': {'ru': 'Оранжевый', 'en': 'Orange', 'ja': '橙'},
  'color_pink': {'ru': 'Розовый', 'en': 'Pink', 'ja': 'ピンク'},
  'color_teal': {'ru': 'Бирюзовый', 'en': 'Teal', 'ja': '青緑'},
  'color_black': {'ru': 'Чёрный', 'en': 'Black', 'ja': '黒'},

  // ── Track pluralization ──
  'track_one': {'ru': 'трек', 'en': 'track', 'ja': 'トラック'},
  'track_few': {'ru': 'трека', 'en': 'tracks', 'ja': 'トラック'},
  'track_many': {'ru': 'треков', 'en': 'tracks', 'ja': 'トラック'},
  'tracks_count': {'ru': 'треков', 'en': 'tracks', 'ja': 'トラック'},

  // ── Duration units ──
  'hours_short': {'ru': 'ч', 'en': 'h', 'ja': '時間'},
  'minutes_short': {'ru': 'мин', 'en': 'm', 'ja': '分'},

  // ── Empty states / Search ──
  'search_wait_internet': {
    'ru': 'Ожидайте скачки секунд 5-10 если песня найдется в интернете',
    'en': 'Please wait 5-10 seconds while we search the internet for this song',
    'ja': 'インターネットで曲を検索中です。5〜10秒お待ちください',
  },
  'search_no_matches': {
    'ru': "Нет совпадений по '{query}'",
    'en': "No matches for '{query}'",
    'ja': "「{query}」に一致する結果はありません",
  },
  'favorites_empty': {
    'ru': 'Поставь сердечко на любимую песенку и она окажется тут!',
    'en': 'Like your favorite songs and they will appear here!',
    'ja': 'お気に入りの曲にハートを付けて、ここに表示させましょう！',
  },
  'playlist_empty': {
    'ru': 'Плейлист пока пуст. Добавь сюда треки через плюсик!',
    'en': 'Playlist is empty. Add tracks via the plus button!',
    'ja': 'プレイリストは空です。プラスボタンから曲を追加してください！',
  },
  'no_data': {'ru': 'Нет данных', 'en': 'No data', 'ja': 'データなし'},
  'search_online': {
    'ru': 'Поискать в интернете?',
    'en': 'Search the internet?',
    'ja': 'インターネットで検索しますか？',
  },
  'shuffle_on_tooltip': {
    'ru': 'Выключить перемешивание',
    'en': 'Turn off shuffle',
    'ja': 'シャッフルをOFF',
  },
  'shuffle_off_tooltip': {'ru': 'Перемешать', 'en': 'Shuffle', 'ja': 'シャッフル'},

  // ── Lyrics ──
  'no_lyrics': {
    'ru': 'Текст песни не найден',
    'en': 'Lyrics not found',
    'ja': '歌詞が見つかりません',
  },
  'play_video_clip': {
    'ru': 'Воспроизводить клип',
    'en': 'Play Video Clip',
    'ja': 'ビデオクリップを再生',
  },
  'play_video_clip_desc': {
    'ru': 'Видеоклип',
    'en': 'Video Clip',
    'ja': 'ビデオクリップ',
  },
  'play_video_clip_hint': {
    'ru': 'Воспроизводит клип с YouTube в круге плеера',
    'en': 'Plays YouTube music video inside the player circle',
    'ja': 'プレイヤーのサークル内でYouTubeクリップを再生します',
  },
  'discord_settings': {'ru': 'Discord', 'en': 'Discord', 'ja': 'Discord'},
  'discord_lyrics_status': {
    'ru': 'Текст песни в статусе Discord',
    'en': 'Lyrics in Discord status',
    'ja': 'Discordのステータスに歌詞を表示',
  },
  'discord_lyrics_status_hint': {
    'ru':
        'Текущая строка вместо трека и артиста. Без текста или на паузе — трек и артист. Карточка профиля не меняется.',
    'en':
        'Show the current lyric instead of track and artist. Without lyrics or when paused, show track and artist. The profile card stays unchanged.',
    'ja':
        '曲名とアーティストの代わりに現在の歌詞を表示。歌詞がない場合や一時停止中は曲名とアーティストを表示します。プロフィールカードは変わりません。',
  },
  'discord_github_button': {
    'ru': 'Кнопка GitHub в Discord',
    'en': 'GitHub Button in Discord',
    'ja': 'DiscordのGitHubボタン',
  },
  'discord_github_button_desc': {
    'ru': 'Ссылка на репозиторий',
    'en': 'Repository Link',
    'ja': 'リポジトリリンク',
  },
  'discord_github_button_hint': {
    'ru': 'Отображать кнопку со ссылкой на GitHub в статусе Discord',
    'en': 'Show the GitHub link button in Discord Rich Presence',
    'ja': 'DiscordステータスにGitHubリンクボタンを表示',
  },

  // ── Downloads management ──
  'delete_downloaded_track': {
    'ru': 'Удалить из загрузок',
    'en': 'Delete from downloads',
    'ja': 'ダウンロードから削除',
  },
  'track_deleted_from_storage': {
    'ru': 'Трек удален из памяти',
    'en': 'Track deleted from storage',
    'ja': '曲がストレージから削除されました',
  },

  // ── Artists & Albums ──
  'sidebar_artists': {'ru': 'Исполнители', 'en': 'Artists', 'ja': 'アーティスト'},
  'artist_bio': {'ru': 'Биография', 'en': 'Biography', 'ja': 'バイオグラフィー'},
  'artist_albums': {'ru': 'Альбомы', 'en': 'Albums', 'ja': 'アルバム'},
  'artist_all_tracks': {'ru': 'Все треки', 'en': 'All Tracks', 'ja': 'すべての曲'},
  'artist_play_all': {'ru': 'Слушать всё', 'en': 'Play All', 'ja': 'すべて再生'},
  'artist_shuffle': {'ru': 'Перемешать', 'en': 'Shuffle', 'ja': 'シャッフル'},
  'no_bio_available': {
    'ru': 'Биография отсутствует',
    'en': 'No biography available',
    'ja': 'バイオグラフィーはありません',
  },
  'albums_title': {'ru': 'Альбомы', 'en': 'Albums', 'ja': 'アルバム'},
  'read_more': {'ru': 'Подробнее', 'en': 'Read more', 'ja': 'もっと見る'},
  'show_less': {'ru': 'Свернуть', 'en': 'Show less', 'ja': '閉じる'},
  'artist_tracks_count': {'ru': 'треков', 'en': 'tracks', 'ja': '曲'},
  'artist_albums_count': {'ru': 'альбомов', 'en': 'albums', 'ja': 'アルバム'},
};
