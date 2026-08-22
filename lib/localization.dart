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
  // ── Navigation / Home ──
  'sidebar_home': {
    'ru': 'Главная',
    'en': 'Home',
    'ja': 'ホーム',
  },
  'sidebar_favorites': {
    'ru': 'Избранное',
    'en': 'Favorites',
    'ja': 'お気に入り',
  },
  'sidebar_downloaded': {
    'ru': 'Загруженное',
    'en': 'Downloaded',
    'ja': 'ダウンロード済み',
  },
  'playlists': {
    'ru': 'ПЛЕЙЛИСТЫ',
    'en': 'PLAYLISTS',
    'ja': 'プレイリスト',
  },
  'create_playlist': {
    'ru': 'Создать плейлист',
    'en': 'Create Playlist',
    'ja': 'プレイリストを作成',
  },
  'settings': {
    'ru': 'Настройки',
    'en': 'Settings',
    'ja': '設定',
  },
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
  'nav_home': {
    'ru': 'Главная',
    'en': 'Home',
    'ja': 'ホーム',
  },
  'nav_favorites': {
    'ru': 'Избранное',
    'en': 'Favorites',
    'ja': 'お気に入り',
  },
  'nav_downloaded': {
    'ru': 'Загруженное',
    'en': 'Downloaded',
    'ja': 'ダウンロード済み',
  },

  // ── Settings ──
  'settings_title': {
    'ru': 'Настройки',
    'en': 'Settings',
    'ja': '設定',
  },
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
  'color_theme': {
    'ru': 'Цветовая тема',
    'en': 'Color Theme',
    'ja': 'カラーテーマ',
  },
  'language': {
    'ru': 'Язык',
    'en': 'Language',
    'ja': '言語',
  },
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
  'storage': {
    'ru': 'Хранилище',
    'en': 'Storage',
    'ja': 'ストレージ',
  },
  'clear_cache': {
    'ru': 'Очистить кэш',
    'en': 'Clear Cache',
    'ja': 'キャッシュを消去',
  },
  'clear_cache_desc': {
    'ru': 'Удалить загруженные треки и обложки',
    'en': 'Delete downloaded tracks and covers',
    'ja': 'ダウンロードした曲とカバーを削除',
  },
  'clear_cache_confirm': {
    'ru': 'Подтвердить очистку',
    'en': 'Confirm clearing',
    'ja': '消去を確認',
  },
  'clear_cache_body': {
    'ru': 'Все локальные файлы будут удалены. Продолжить?',
    'en': 'All local files will be deleted. Continue?',
    'ja': 'すべてのローカルファイルが削除されます。続行しますか？',
  },
  'cancel': {
    'ru': 'Отмена',
    'en': 'Cancel',
    'ja': 'キャンセル',
  },
  'clear': {
    'ru': 'Очистить',
    'en': 'Clear',
    'ja': '消去',
  },
  'cache_cleared': {
    'ru': 'Кэш очищен',
    'en': 'Cache cleared',
    'ja': 'キャッシュを消去しました',
  },
  'about': {
    'ru': 'О приложении',
    'en': 'About',
    'ja': 'アプリについて',
  },
  'version': {
    'ru': 'Версия',
    'en': 'Version',
    'ja': 'バージョン',
  },
  'personal_player': {
    'ru': 'Персональный музыкальный плеер',
    'en': 'Personal music player',
    'ja': 'パーソナルミュージックプレイヤー',
  },

  // ── Color names ──
  'color_red': {
    'ru': 'Красный',
    'en': 'Red',
    'ja': '赤',
  },
  'color_blue': {
    'ru': 'Синий',
    'en': 'Blue',
    'ja': '青',
  },
  'color_purple': {
    'ru': 'Фиолетовый',
    'en': 'Purple',
    'ja': '紫',
  },
  'color_green': {
    'ru': 'Зелёный',
    'en': 'Green',
    'ja': '緑',
  },
  'color_orange': {
    'ru': 'Оранжевый',
    'en': 'Orange',
    'ja': '橙',
  },
  'color_pink': {
    'ru': 'Розовый',
    'en': 'Pink',
    'ja': 'ピンク',
  },
  'color_teal': {
    'ru': 'Бирюзовый',
    'en': 'Teal',
    'ja': '青緑',
  },
  'color_black': {
    'ru': 'Чёрный',
    'en': 'Black',
    'ja': '黒',
  },

  // ── Track pluralization ──
  'track_one': {
    'ru': 'трек',
    'en': 'track',
    'ja': 'トラック',
  },
  'track_few': {
    'ru': 'трека',
    'en': 'tracks',
    'ja': 'トラック',
  },
  'track_many': {
    'ru': 'треков',
    'en': 'tracks',
    'ja': 'トラック',
  },
  'tracks_count': {
    'ru': 'треков',
    'en': 'tracks',
    'ja': 'トラック',
  },

  // ── Duration units ──
  'hours_short': {
    'ru': 'ч',
    'en': 'h',
    'ja': '時間',
  },
  'minutes_short': {
    'ru': 'мин',
    'en': 'm',
    'ja': '分',
  },

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
  'no_data': {
    'ru': 'Нет данных',
    'en': 'No data',
    'ja': 'データなし',
  },
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
  'shuffle_off_tooltip': {
    'ru': 'Перемешать',
    'en': 'Shuffle',
    'ja': 'シャッフル',
  },

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
  'sidebar_artists': {
    'ru': 'Исполнители',
    'en': 'Artists',
    'ja': 'アーティスト',
  },
  'artist_bio': {
    'ru': 'Биография',
    'en': 'Biography',
    'ja': 'バイオグラフィー',
  },
  'artist_albums': {
    'ru': 'Альбомы',
    'en': 'Albums',
    'ja': 'アルバム',
  },
  'artist_all_tracks': {
    'ru': 'Все треки',
    'en': 'All Tracks',
    'ja': 'すべての曲',
  },
  'artist_play_all': {
    'ru': 'Слушать всё',
    'en': 'Play All',
    'ja': 'すべて再生',
  },
  'artist_shuffle': {
    'ru': 'Перемешать',
    'en': 'Shuffle',
    'ja': 'シャッフル',
  },
  'no_bio_available': {
    'ru': 'Биография отсутствует',
    'en': 'No biography available',
    'ja': 'バイオグラフィーはありません',
  },
  'albums_title': {
    'ru': 'Альбомы',
    'en': 'Albums',
    'ja': 'アルバム',
  },
  'read_more': {
    'ru': 'Подробнее',
    'en': 'Read more',
    'ja': 'もっと見る',
  },
  'show_less': {
    'ru': 'Свернуть',
    'en': 'Show less',
    'ja': '閉じる',
  },
  'artist_tracks_count': {
    'ru': 'треков',
    'en': 'tracks',
    'ja': '曲',
  },
  'artist_albums_count': {
    'ru': 'альбомов',
    'en': 'albums',
    'ja': 'アルバム',
  },
};
