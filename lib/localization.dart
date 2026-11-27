import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../globals.dart';

const appSupportedLocales = [Locale('ru'), Locale('en'), Locale('ja')];

@visibleForTesting
const translationCatalog = _translations;

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
  'download_recovery_failed': {
    'ru':
        'Не удалось восстановить скачанное после сбоя при удалении. Файлы на месте, но скачивание и перенос пока недоступны. Попробуй перезапустить плеер.',
    'en':
        'The player could not restore a download after an interrupted removal. The files are still there, but downloads and transfers are on hold. Try restarting the player.',
    'ja':
        '削除が途中で止まり、ダウンロード済みの曲を復元できませんでした。ファイルは残っていますが、今はダウンロードと移行ができません。プレーヤーを再起動してください。',
  },
  'download_removal_deferred': {
    'ru': 'Удалим загрузку после переключения трека. Музыка не прервётся.',
    'en':
        'Download will be removed after switching tracks. Playback continues.',
    'ja': '曲を切り替えた後にダウンロードを削除します。再生は続行します。',
  },
  'download_removal_failed': {
    'ru':
        'Не удалось удалить скачанную копию. Файлы на месте. Попробуй ещё раз.',
    'en':
        'Could not remove the download. Your files are still there. Try again.',
    'ja': 'ダウンロード済みのコピーを削除できませんでした。ファイルは残っています。もう一度お試しください。',
  },
  'download_removal_cleanup_pending': {
    'ru':
        'Трек убран из загрузок. Плеер удалит оставшиеся файлы при следующем запуске.',
    'en':
        'Download removed from the list. The player will delete the remaining files next time it starts.',
    'ja': '曲をダウンロード一覧から外しました。残りのファイルは次回起動時に削除します。',
  },
  'catalog_refresh': {
    'ru': 'Обновить каталог',
    'en': 'Refresh library',
    'ja': 'ライブラリを更新',
  },
  'catalog_checking': {
    'ru': 'Проверяем сервер',
    'en': 'Checking server',
    'ja': 'サーバーを確認中',
  },
  'catalog_synced': {
    'ru': 'Каталог обновлён',
    'en': 'Library up to date',
    'ja': 'ライブラリは最新です',
  },
  'catalog_offline': {
    'ru': 'Сервер недоступен. Скачанное можно слушать.',
    'en': 'Server unavailable. You can still play downloads.',
    'ja': 'サーバーに接続できません。ダウンロード済みの曲は再生できます。',
  },
  'catalog_error': {
    'ru': 'Не удалось обновить каталог. Скачанные треки на месте.',
    'en': 'Could not refresh the library. Downloads are still available.',
    'ja': 'ライブラリを更新できませんでした。ダウンロード済みの曲はそのままです。',
  },
  'catalog_last_sync': {
    'ru': 'Последняя проверка: {time}',
    'en': 'Last checked: {time}',
    'ja': '最終確認: {time}',
  },
  'repeat_off': {'ru': 'Повтор выключен', 'en': 'Repeat off', 'ja': 'リピートなし'},
  'play_next_queue': {'ru': 'Следом', 'en': 'Up next', 'ja': '次に再生'},
  'local_import': {'ru': 'Добавить файлы', 'en': 'Add files', 'ja': 'ファイルを追加'},
  'local_import_choose': {
    'ru': 'Выбрать файлы',
    'en': 'Choose files',
    'ja': 'ファイルを選択',
  },
  'local_import_copy': {
    'ru':
        'Плеер скопирует MP3 в папку со скачанными треками и не тронет исходники. Копии займут место на диске.',
    'en':
        'The player keeps your MP3s and saves copies next to your downloads. You’ll need free space for the copies.',
    'ja': 'MP3をダウンロード済みの曲と同じフォルダにコピーします。空き容量が必要です。元のファイルはそのままです。',
  },
  'local_import_lrc_desktop': {
    'ru':
        'Если рядом с MP3 есть .lrc с тем же именем, плеер возьмёт из него текст.',
    'en':
        'The player also imports lyrics from a matching .lrc next to the MP3.',
    'ja': '同じフォルダに同名の.lrcがあれば、歌詞も取り込みます。',
  },
  'local_import_lrc_mobile': {
    'ru': 'Чтобы добавить текст, выбери .lrc с тем же именем вместе с MP3.',
    'en': 'To add lyrics, select the matching .lrc together with the MP3.',
    'ja': '歌詞を追加するには、MP3と同名の.lrcも一緒に選択します。',
  },
  'local_import_preparing': {
    'ru': 'Подготовка…',
    'en': 'Preparing…',
    'ja': '準備中…',
  },
  'local_import_summary': {
    'ru': 'Добавлено: {added}. Уже в библиотеке: {existing}.',
    'en': 'Added: {added}. Already in your library: {existing}.',
    'ja': '追加: {added} 件。登録済み: {existing} 件。',
  },
  'local_import_restored': {
    'ru': 'Копий восстановлено: {count}.',
    'en': 'Copies restored: {count}.',
    'ja': '復元したコピー: {count} 件。',
  },
  'local_import_cancelled': {
    'ru': 'Импорт остановлен. Уже добавленные треки остались в библиотеке.',
    'en': 'Import stopped. Tracks you already added stay in your library.',
    'ja': '取り込みを停止しました。追加済みの曲はライブラリに残ります。',
  },
  'local_import_problem_count': {
    'ru': 'Не добавлено: {count}',
    'en': 'Not added: {count}',
    'ja': '追加できなかったファイル: {count} 件',
  },
  'local_import_more_problems': {
    'ru': 'И ещё: {count}',
    'en': 'And {count} more',
    'ja': 'ほか {count} 件',
  },
  'local_import_invalidAudio': {
    'ru': 'не удалось прочитать MP3',
    'en': 'not a readable MP3',
    'ja': 'MP3を読み取れません',
  },
  'local_import_cannotRead': {
    'ru': 'ошибка чтения или записи',
    'en': 'could not read or save the file',
    'ja': 'ファイルを読み込むか保存できません',
  },
  'local_import_unsupported': {
    'ru': 'выбери MP3 или LRC',
    'en': 'choose MP3 or LRC files',
    'ja': 'MP3またはLRCを選んでください',
  },
  'local_import_unpairedLyrics': {
    'ru': 'выбери MP3 с тем же именем',
    'en': 'select the MP3 with the same name',
    'ja': '同名のMP3も選択してください',
  },
  'local_import_pick_failed': {
    'ru': 'Не удалось открыть выбранные файлы. Попробуй выбрать их ещё раз.',
    'en': 'Could not open the selected files. Try selecting them again.',
    'ja': '選択したファイルにアクセスできませんでした。もう一度選択してください。',
  },
  'local_import_save_failed': {
    'ru':
        'Не удалось сохранить копии. Проверь свободное место и доступ к папке ShikiMusic.',
    'en':
        'Could not save copies. Check free space and access to the ShikiMusic folder.',
    'ja': 'コピーを保存できませんでした。空き容量とShikiMusicフォルダへのアクセスを確認してください。',
  },
  'local_import_owned': {'ru': 'Свой MP3', 'en': 'Your MP3', 'ja': 'ローカルMP3'},
  'local_track_remove': {
    'ru': 'Удалить свой MP3',
    'en': 'Remove your MP3',
    'ja': 'ローカルMP3を削除',
  },
  'local_track_remove_action': {'ru': 'Удалить', 'en': 'Remove', 'ja': '削除'},
  'local_track_remove_confirm': {
    'ru':
        '«{title}» будет удалён из библиотеки, плейлистов и очереди. Исходный файл и каталог сервера не изменятся.',
    'en':
        '“{title}” will be removed from your library, playlists, and queue. The original file and server catalog won’t change.',
    'ja': '「{title}」をライブラリ、プレイリスト、再生キューから削除します。元のファイルとサーバーのカタログは変更されません。',
  },
  'local_track_removed': {
    'ru': 'Свой MP3 удалён',
    'en': 'Your MP3 was removed',
    'ja': 'ローカルMP3を削除しました',
  },
  'local_track_remove_failed': {
    'ru': 'Не удалось удалить свой MP3',
    'en': 'Couldn’t remove your MP3',
    'ja': 'ローカルMP3を削除できませんでした',
  },
  'local_track_remove_incomplete': {
    'ru': 'Трек убран из библиотеки, но не все данные удалось очистить',
    'en':
        'Track removed from the library, but some local data couldn’t be cleaned up',
    'ja': '曲をライブラリから削除しましたが、一部のデータを消去できませんでした',
  },
  'local_match_on_server': {
    'ru': 'Найти на сервере',
    'en': 'Find on server',
    'ja': 'サーバーで探す',
  },
  'local_match_after_import': {
    'ru':
        'Если сервер доступен, плеер поищет эту запись по тегам. Сам MP3 не отправляется.',
    'en':
        'If the server is online, the player looks for the recording by its tags. It doesn’t upload the MP3.',
    'ja': 'サーバーに接続できる場合、タグから同じ音源を探します。MP3自体は送信しません。',
  },
  'local_match_unavailable': {
    'ru': 'Сервер недоступен или ещё не поддерживает этот поиск',
    'en': 'The server is offline or doesn’t support this search yet',
    'ja': 'サーバーに接続できないか、この検索に未対応です',
  },
  'local_match_queued': {
    'ru': 'найдено, сервер готовит запись: {count}',
    'en': 'matched, adding to server: {count}',
    'ja': '一致を確認、サーバーに追加中: {count}',
  },
  'local_match_metadata': {
    'ru': 'данные обновлены только на этом устройстве: {count}',
    'en': 'track details updated on this device only: {count}',
    'ja': 'この端末のみ曲情報を更新: {count}',
  },
  'local_match_existing': {
    'ru': 'уже в каталоге: {count}',
    'en': 'already in catalog: {count}',
    'ja': '登録済み: {count}',
  },
  'local_match_no_match': {
    'ru': 'совпадение не подтверждено: {count}',
    'en': 'no confirmed match: {count}',
    'ja': '一致を確認できず: {count}',
  },
  'local_match_failed': {
    'ru': 'ошибок поиска: {count}',
    'en': 'search errors: {count}',
    'ja': '検索エラー: {count}',
  },
  'local_import_missing': {
    'ru': 'Копии MP3 нет. Добавь исходный файл снова.',
    'en': 'The MP3 copy is missing. Add the original file again.',
    'ja': 'MP3のコピーがありません。元のファイルをもう一度追加してください。',
  },
  'local_import_unknown_artist': {
    'ru': 'Неизвестный исполнитель',
    'en': 'Unknown artist',
    'ja': '不明なアーティスト',
  },
  'local_import_unknown_album': {
    'ru': 'Без альбома',
    'en': 'Unknown album',
    'ja': 'アルバム不明',
  },
  'play_next_track': {
    'ru': 'Сыграть следующим',
    'en': 'Play next',
    'ja': '次に再生する',
  },
  'play_next_selection': {
    'ru': 'Сыграть следующими',
    'en': 'Play selected next',
    'ja': '選択した曲を次に再生',
  },
  'play_next_now_playing': {
    'ru': 'Сейчас: {title}',
    'en': 'Now: {title}',
    'ja': '再生中: {title}',
  },
  'play_next_clear': {'ru': 'Очистить', 'en': 'Clear', 'ja': 'クリア'},
  'play_next_empty': {
    'ru': 'Чтобы добавить трек, выбери «Сыграть следующим» в его меню.',
    'en': 'To add a track, choose Play next from its menu.',
    'ja': '曲を追加するには、曲のメニューで「次に再生する」を選びます。',
  },
  'play_next_remove': {
    'ru': 'Убрать из «Следом»',
    'en': 'Remove from Up next',
    'ja': '次に再生から取り除く',
  },
  'play_next_starting': {
    'ru': 'Трек уже начал играть',
    'en': 'Track has already started',
    'ja': 'この曲はすでに再生が始まっています',
  },
  'play_next_added': {
    'ru': 'Добавлено в «Следом»: {count}',
    'en': 'Added to Up next: {count}',
    'ja': '次に再生へ追加: {count} 曲',
  },
  'play_next_unavailable': {
    'ru': 'Пропущен недоступный трек: {title}',
    'en': 'Skipped unavailable track: {title}',
    'ja': '利用できない曲をスキップしました: {title}',
  },
  'track_actions': {
    'ru': 'Действия с треком',
    'en': 'Track actions',
    'ja': '曲の操作',
  },
  'repeat_queue': {
    'ru': 'Повтор очереди',
    'en': 'Repeat queue',
    'ja': '再生キューをリピート',
  },
  'repeat_track': {'ru': 'Повтор трека', 'en': 'Repeat track', 'ja': '1曲リピート'},
  'ok': {'ru': 'ОК', 'en': 'OK', 'ja': 'OK'},
  'create': {'ru': 'Создать', 'en': 'Create', 'ja': '作成'},
  'image_selected': {
    'ru': 'Картинка выбрана ✓',
    'en': 'Image selected ✓',
    'ja': '画像を選択済み ✓',
  },
  'offline_mode': {
    'ru': 'Сервер недоступен. Работаем оффлайн.',
    'en': 'Server unavailable. Working offline.',
    'ja': 'サーバーに接続できません。オフラインで利用できます。',
  },
  'video_retry_delayed': {
    'ru':
        'Плеер пока не будет снова искать клип. Скачивание можно повторить вручную.',
    'en':
        'Automatic video search is on hold. You can still retry the download manually.',
    'ja': '動画の自動検索を一時停止しています。手動でダウンロードをやり直せます。',
  },
  'listening_music': {
    'ru': 'Слушает музыку',
    'en': 'Listening to music',
    'ja': '音楽を再生中',
  },
  'lyrics_intro': {'ru': 'Вступление...', 'en': 'Intro...', 'ja': 'イントロ…'},
  'paused_at': {
    'ru': 'На паузе ({position})',
    'en': 'Paused ({position})',
    'ja': '一時停止（{position}）',
  },
  'shuffle_off': {
    'ru': 'Выключить перемешивание',
    'en': 'Turn shuffle off',
    'ja': 'シャッフルをオフ',
  },
  'test_screen': {'ru': 'Тест', 'en': 'Test', 'ja': 'テスト'},
  'taskbar_favorite_add': {
    'ru': 'Добавить в избранное',
    'en': 'Add to favorites',
    'ja': 'お気に入りに追加',
  },
  'taskbar_favorite_remove': {
    'ru': 'Убрать из избранного',
    'en': 'Remove from favorites',
    'ja': 'お気に入りから削除',
  },
  'taskbar_previous': {
    'ru': 'Предыдущий трек',
    'en': 'Previous track',
    'ja': '前の曲',
  },
  'taskbar_next': {'ru': 'Следующий трек', 'en': 'Next track', 'ja': '次の曲'},
  'taskbar_play': {'ru': 'Воспроизвести', 'en': 'Play', 'ja': '再生'},
  'taskbar_pause': {'ru': 'Пауза', 'en': 'Pause', 'ja': '一時停止'},
  'playlist_rename': {'ru': 'Переименовать', 'en': 'Rename', 'ja': '名前を変更'},
  'playlist_reorder': {
    'ru': 'Перетащить трек',
    'en': 'Drag to reorder',
    'ja': 'ドラッグして並べ替え',
  },
  'tracks_selected': {
    'ru': 'Выбрано: {count}',
    'en': 'Selected: {count}',
    'ja': '選択中: {count}',
  },
  'clear_track_selection': {
    'ru': 'Снять выделение',
    'en': 'Clear selection',
    'ja': '選択を解除',
  },
  'download_selected_tracks': {
    'ru': 'Скачать выбранные',
    'en': 'Download selected',
    'ja': '選択した曲をダウンロード',
  },
  'play_selected_tracks': {
    'ru': 'Слушать выбранные',
    'en': 'Play selected',
    'ja': '選択した曲を再生',
  },
  'add_selected_to_playlist': {
    'ru': 'Добавить выбранные в плейлист',
    'en': 'Add selected to playlist',
    'ja': '選択した曲をプレイリストに追加',
  },
  'create_playlist_from_selection': {
    'ru': 'Создать плейлист из выбранных',
    'en': 'Create playlist from selected tracks',
    'ja': '選択した曲からプレイリストを作成',
  },
  'favorite_save_failed': {
    'ru': 'Не удалось сохранить избранное. Изменения отменены.',
    'en': 'Could not save favorites. Changes were reverted.',
    'ja': 'お気に入りを保存できませんでした。変更を元に戻しました。',
  },
  'playlist_reorder_touch': {
    'ru': 'Удерживай обложку и перетащи трек',
    'en': 'Hold the artwork and drag to reorder',
    'ja': 'ジャケットを長押ししてドラッグで並べ替え',
  },
  'playlist_move_up': {'ru': 'Переместить выше', 'en': 'Move up', 'ja': '上に移動'},
  'playlist_move_down': {
    'ru': 'Переместить ниже',
    'en': 'Move down',
    'ja': '下に移動',
  },
  'playlist_change_artwork': {
    'ru': 'Сменить обложку',
    'en': 'Change artwork',
    'ja': '画像を変更',
  },
  'playlist_add_background': {
    'ru': 'Поставить фон',
    'en': 'Set background',
    'ja': '背景を設定',
  },
  'playlist_change_background': {
    'ru': 'Сменить фон',
    'en': 'Change background',
    'ja': '背景を変更',
  },
  'playlist_reset_background': {
    'ru': 'Вернуть общий фон',
    'en': 'Use app background',
    'ja': 'アプリの背景に戻す',
  },
  'playlist_select_background_photo': {
    'ru': 'Выбрать фото для фона',
    'en': 'Choose a background photo',
    'ja': '背景の写真を選ぶ',
  },
  'playlist_background_saved': {
    'ru': 'Фон плейлиста сохранён',
    'en': 'Playlist background saved',
    'ja': 'プレイリストの背景を保存しました',
  },
  'playlist_background_invalid': {
    'ru':
        'Не удалось открыть фото. Попробуй другой файл: JPG, PNG или WebP без анимации.',
    'en': 'Could not open the photo. Try a still JPG, PNG or WebP.',
    'ja': '写真を開けませんでした。JPG、PNG、WebPの静止画を選んでください。',
  },
  'playlist_background_failed': {
    'ru': 'Не удалось сохранить фон плейлиста. Прежний фон не изменился.',
    'en':
        'Could not save the playlist background. The previous background is unchanged.',
    'ja': 'プレイリストの背景を保存できませんでした。元の背景はそのままです。',
  },
  'playlist_delete': {
    'ru': 'Удалить плейлист',
    'en': 'Delete playlist',
    'ja': 'プレイリストを削除',
  },
  'playlist_deleted': {
    'ru': 'Плейлист удалён',
    'en': 'Playlist deleted',
    'ja': 'プレイリストを削除しました',
  },
  'playlist_name': {
    'ru': 'Название плейлиста',
    'en': 'Playlist name',
    'ja': 'プレイリスト名',
  },
  'playlist_save': {'ru': 'Сохранить', 'en': 'Save', 'ja': '保存'},
  'playlist_save_failed': {
    'ru':
        'Не удалось сохранить плейлист. Проверь свободное место и доступ к папке данных.',
    'en':
        'Could not save the playlist. Check for free space and make sure the player can write to its data folder.',
    'ja': 'プレイリストを保存できませんでした。空き容量とフォルダへのアクセスを確認してください。',
  },
  'transfer_title': {
    'ru': 'Перенос и резервная копия',
    'en': 'Transfer and backup',
    'ja': 'データの移行とバックアップ',
  },
  'transfer_cancel': {
    'ru': 'Отменить импорт',
    'en': 'Cancel import',
    'ja': 'インポートをキャンセル',
  },
  'transfer_cancelled': {
    'ru': 'Импорт отменён. Библиотека не изменена.',
    'en': 'Import cancelled. Library unchanged.',
    'ja': 'インポートをキャンセルしました。ライブラリは変更されていません。',
  },
  'transfer_hint': {
    'ru':
        'В ZIP сохранятся каталог, обложки, избранное, настройки, статистика и плейлисты с фонами. Делись архивом только с теми, кому доверяешь: в нём личные данные.',
    'en':
        'The ZIP includes your catalog, artwork, favorites, settings, stats and playlists with their backgrounds. It contains private data, so share it only with people you trust.',
    'ja':
        'ZIPにカタログ、画像、お気に入り、設定、統計、プレイリストとその背景を保存します。個人データが入っているので、信頼できる相手とだけ共有してください。',
  },
  'transfer_media': {
    'ru': 'Включить скачанную музыку и видео',
    'en': 'Include downloaded music and video',
    'ja': 'ダウンロード済みの音楽と動画を含める',
  },
  'transfer_export': {
    'ru': 'Создать архив',
    'en': 'Create archive',
    'ja': 'アーカイブを作成',
  },
  'transfer_import': {
    'ru': 'Выбрать архив',
    'en': 'Choose archive',
    'ja': 'アーカイブを選択',
  },
  'transfer_settings': {
    'ru': 'Применить настройки из архива',
    'en': 'Apply settings from archive',
    'ja': 'アーカイブの設定を適用する',
  },
  'transfer_import_hint': {
    'ru':
        'После перезапуска плеер объединит архив с библиотекой, не заменяя скачанную музыку. Если данные двух библиотек конфликтуют, импорт остановится. На другом устройстве может понадобиться новый адрес сервера.',
    'en':
        'Restart the player to merge the archive with your library. It keeps your existing music files and stops the import if the libraries conflict. You may need to change the server address on the other device.',
    'ja':
        '次回起動時にデータを統合します。既存の音楽は置き換えません。ライブラリが競合する場合はインポートを中止します。移行先でサーバーアドレスの変更が必要な場合があります。',
  },
  'transfer_pending': {
    'ru': 'Архив проверен. Перезапусти плеер, чтобы завершить импорт.',
    'en': 'Archive verified. Restart the player to finish importing.',
    'ja': 'アーカイブを確認しました。プレーヤーを再起動するとインポートが完了します。',
  },
  'transfer_saved': {
    'ru': 'Архив сохранён.',
    'en': 'Archive saved.',
    'ja': 'アーカイブを保存しました。',
  },
  'transfer_error': {
    'ru': 'Не удалось завершить перенос:',
    'en': 'Transfer could not be completed:',
    'ja': 'データの移行を完了できませんでした：',
  },
  'transfer_working': {
    'ru': 'Не закрывай плеер, пока он работает с архивом.',
    'en': 'Keep the player open while it processes the archive.',
    'ja': 'アーカイブの処理が終わるまで、プレーヤーを閉じないでください。',
  },
  'transfer_applied': {
    'ru':
        'Перенос завершён. Копии прежних настроек и списков ищи в папке transfer_restore… внутри папки данных плеера.',
    'en':
        'Transfer complete. Look for copies of your old settings and lists in the transfer_restore… folder inside the player’s data folder.',
    'ja': '移行が完了しました。元の設定とリストのコピーは、プレーヤーのデータフォルダー内のtransfer_restore…にあります。',
  },
  'stats_title': {
    'ru': 'Моя статистика',
    'en': 'My statistics',
    'ja': 'リスニング統計',
  },
  'stats_music': {'ru': 'Моя музыка', 'en': 'My music', 'ja': 'マイミュージック'},
  'stats_favorite_artist': {
    'ru': 'Больше всего слушал',
    'en': 'Top artist',
    'ja': 'いちばん聴いたアーティスト',
  },
  'stats_favorite_tracks': {
    'ru': 'Любимые треки',
    'en': 'Top tracks',
    'ja': 'よく聴いた曲',
  },
  'stats_total_listened': {
    'ru': 'Всего слушал',
    'en': 'Total listening',
    'ja': '合計再生時間',
  },
  'stats_daily': {'ru': 'По дням', 'en': 'Listening by day', 'ja': '日別の再生時間'},
  'stats_more': {'ru': 'Показать все', 'en': 'Show all', 'ja': 'すべて表示'},
  'stats_less': {'ru': 'Свернуть', 'en': 'Show less', 'ja': '折りたたむ'},
  'stats_details': {
    'ru': 'Об истории прослушивания',
    'en': 'About listening history',
    'ja': '再生履歴について',
  },
  'stats_private': {
    'ru': 'История хранится на этом устройстве. Аккаунт не нужен.',
    'en': 'Your history stays on this device. No account needed.',
    'ja': '履歴はこの端末に保存します。アカウントは不要です。',
  },
  'stats_listening': {
    'ru': 'Время прослушивания',
    'en': 'Listening time',
    'ja': '再生時間',
  },
  'stats_app_time': {
    'ru': 'Время в приложении',
    'en': 'Time in the app',
    'ja': 'アプリを開いていた時間',
  },
  'stats_plays': {'ru': 'Прослушиваний', 'en': 'Plays', 'ja': '再生回数'},
  'stats_plays_short': {'ru': 'прослуш.', 'en': 'plays', 'ja': '回'},
  'stats_tracks': {'ru': 'Треки', 'en': 'Tracks', 'ja': '曲'},
  'stats_artists': {'ru': 'Исполнители', 'en': 'Artists', 'ja': 'アーティスト'},
  'stats_active_days': {
    'ru': 'Дней с музыкой',
    'en': 'Days with music',
    'ja': '音楽を聴いた日数',
  },
  'stats_activity': {'ru': 'Активность', 'en': 'Activity', 'ja': 'アクティビティ'},
  'stats_period_week': {'ru': '7 дней', 'en': '7 days', 'ja': '7日間'},
  'stats_period_month': {'ru': '30 дней', 'en': '30 days', 'ja': '30日間'},
  'stats_period_year': {'ru': 'Этот год', 'en': 'This year', 'ja': '今年'},
  'stats_period_all': {'ru': 'Всё время', 'en': 'All time', 'ja': '全期間'},
  'stats_period_custom': {'ru': 'Период', 'en': 'Date range', 'ja': '期間を選択'},
  'stats_sort_time': {
    'ru': 'По времени',
    'en': 'By listening time',
    'ja': '再生時間順',
  },
  'stats_sort_plays': {
    'ru': 'По прослушиваниям',
    'en': 'By plays',
    'ja': '再生回数順',
  },
  'stats_top_hint': {
    'ru': 'До 100 исполнителей или треков за выбранный период',
    'en': 'Up to 100 artists or tracks for the selected period',
    'ja': '選択した期間の上位100組のアーティストまたは100曲を表示します',
  },
  'stats_empty': {
    'ru': 'За выбранный период нет прослушиваний.',
    'en': 'No listening history for the selected period.',
    'ja': '選んだ期間の再生履歴はありません。',
  },
  'stats_counting_hint': {
    'ru':
        'Плеер считает время, пока играет музыка, даже в фоне. Паузы и перемотка не в счёт. Трек засчитывается после 30 секунд. Если он короче минуты, достаточно половины. Время совместного трека идёт каждому исполнителю, но в общий итог попадает один раз.',
    'en':
        'The player tracks time while music plays, even in the background. Pauses and seeks do not count. A play counts after 30 seconds of listening, or half the track if it’s under a minute. A collaboration adds time to each artist but only once to your total.',
    'ja':
        '曲が流れている時間を記録します。バックグラウンド再生も含みますが、一時停止や再生位置の移動は含みません。30秒聴くと1回になり、1分未満の曲は半分で1回になります。共作曲の時間は各アーティストに加わりますが、合計には一度だけ入ります。',
  },
  'stats_backup_hint': {
    'ru':
        'Сохрани копию истории через «Экспорт». «Импорт» добавит записи из файла без дублей. Обновление плеера и очистка кэша историю не удаляют.',
    'en':
        'Use Export to save a copy of your history. Import adds records from a file without duplicates. Updating the player or clearing its cache keeps your history.',
    'ja':
        '「エクスポート」で履歴のコピーを保存できます。「インポート」ではファイルの履歴を重複なく追加します。アプリを更新したりキャッシュを消去したりしても履歴は残ります。',
  },
  'stats_since': {'ru': 'История с', 'en': 'History since', 'ja': '記録開始日'},
  'stats_refresh': {
    'ru': 'Обновить статистику',
    'en': 'Refresh statistics',
    'ja': '統計を更新',
  },
  'stats_retry': {'ru': 'Повторить', 'en': 'Retry', 'ja': '再試行'},
  'stats_error': {
    'ru': 'Не удалось прочитать статистику. Попробуй ещё раз.',
    'en': 'Could not load statistics. Please try again.',
    'ja': '統計を読み込めませんでした。もう一度お試しください。',
  },
  'stats_export': {'ru': 'Экспорт', 'en': 'Export', 'ja': 'エクスポート'},
  'stats_import': {'ru': 'Импорт', 'en': 'Import', 'ja': 'インポート'},
  'stats_exported': {
    'ru': 'Статистика сохранена',
    'en': 'Statistics exported',
    'ja': '統計を保存しました',
  },
  'stats_imported': {
    'ru': 'История объединена',
    'en': 'History merged',
    'ja': '履歴を統合しました',
  },
  'stats_import_error': {
    'ru':
        'Не удалось импортировать файл. Выбери копию, которую сохранил через «Экспорт» в статистике.',
    'en':
        'Could not import this file. Choose a copy saved with Export in the statistics screen.',
    'ja': 'ファイルを取り込めませんでした。統計画面の「エクスポート」で保存したファイルを選んでください。',
  },
  'stats_export_error': {
    'ru': 'Не удалось сохранить файл статистики',
    'en': 'Could not export statistics',
    'ja': '統計を保存できませんでした',
  },
  'stats_under_minute': {
    'ru': 'Менее минуты',
    'en': 'Under a minute',
    'ja': '1分未満',
  },
  'stats_minutes': {'ru': 'мин', 'en': 'min', 'ja': '分'},
  'stats_hours': {'ru': 'ч', 'en': 'h', 'ja': '時間'},
  'stats_untitled': {'ru': 'Без названия', 'en': 'Untitled', 'ja': 'タイトルなし'},
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
        'Плеер оставит старые файлы. При следующем воспроизведении трека он возьмёт новый MP3 и текст.',
    'en':
        'The player keeps the old files and uses the new MP3 and lyrics next time you play the track.',
    'ja': '元のファイルは残ります。次に曲を再生するときに、新しいMP3と歌詞を使います。',
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
  'playlist_crop_title': {
    'ru': 'Обложка плейлиста',
    'en': 'Playlist artwork',
    'ja': 'プレイリストの画像',
  },
  'playlist_crop_hint': {
    'ru':
        'Перемещай фото и меняй масштаб. На обложке останется то, что внутри круга.',
    'en':
        'Drag and zoom the photo. The area inside the circle becomes the playlist artwork.',
    'ja': '写真を移動したり拡大・縮小したりして、プレイリストの画像に使う範囲を円の中に収めてください。',
  },
  'playlist_crop_reset': {
    'ru': 'Сбросить кадрирование',
    'en': 'Reset crop',
    'ja': '切り抜きをリセット',
  },
  'playlist_crop_apply': {'ru': 'Выбрать', 'en': 'Use image', 'ja': 'この画像を使用'},
  'settings': {'ru': 'Настройки', 'en': 'Settings', 'ja': '設定'},
  'search_hint_senpai': {
    'ru': 'Треки, исполнители, текст',
    'en': 'Tracks, artists, lyrics',
    'ja': '曲名・アーティスト・歌詞',
  },
  'search_lyrics_loading': {
    'ru': 'Ищем в сохранённых текстах…',
    'en': 'Searching saved lyrics…',
    'ja': '保存された歌詞を検索中…',
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
  'settings_appearance': {'ru': 'Внешний вид', 'en': 'Appearance', 'ja': '外観'},
  'settings_track_list_density': {
    'ru': 'Вид списка треков',
    'en': 'Track list spacing',
    'ja': '曲一覧の間隔',
  },
  'settings_track_list_normal': {'ru': 'Обычный', 'en': 'Standard', 'ja': '標準'},
  'settings_track_list_compact': {
    'ru': 'Компактный',
    'en': 'Compact',
    'ja': 'コンパクト',
  },
  'settings_track_list_save_failed': {
    'ru': 'Не удалось сохранить вид списка треков.',
    'en': 'Could not save track list spacing.',
    'ja': '曲一覧の間隔を保存できませんでした。',
  },
  'lyrics_text_size': {
    'ru': 'Размер текста песен',
    'en': 'Lyrics text size',
    'ja': '歌詞の文字サイズ',
  },
  'lyrics_text_size_small': {'ru': 'Мелкий', 'en': 'Small', 'ja': '小'},
  'lyrics_text_size_normal': {'ru': 'Обычный', 'en': 'Standard', 'ja': '標準'},
  'lyrics_text_size_large': {'ru': 'Крупный', 'en': 'Large', 'ja': '大'},
  'lyrics_text_size_sample': {
    'ru': 'Ночью огни города отражаются в реке.',
    'en': 'At night, the city lights ripple on the river.',
    'ja': '夜の川面に街の明かりが揺れる。',
  },
  'settings_apply': {'ru': 'Применить', 'en': 'Apply', 'ja': '適用'},
  'lyrics_text_size_save_failed': {
    'ru': 'Не удалось сохранить размер текста песен.',
    'en': 'Could not save the lyrics text size.',
    'ja': '歌詞の文字サイズを保存できませんでした。',
  },
  'lyrics_background_blur': {
    'ru': 'Размытие фона текста',
    'en': 'Lyrics background blur',
    'ja': '歌詞の背景ぼかし',
  },
  'lyrics_background_blur_sample': {
    'ru': 'Город засыпает',
    'en': 'The city sleeps',
    'ja': '街が眠る',
  },
  'lyrics_background_blur_reset': {
    'ru': 'Сбросить',
    'en': 'Reset',
    'ja': 'リセット',
  },
  'lyrics_background_blur_save_failed': {
    'ru': 'Не удалось сохранить размытие фона текста.',
    'en': 'Could not save the lyrics background blur.',
    'ja': '歌詞の背景ぼかしを保存できませんでした。',
  },
  'settings_playback': {'ru': 'Воспроизведение', 'en': 'Playback', 'ja': '再生'},
  'replay_gain': {
    'ru': 'Выравнивать громкость',
    'en': 'Match track loudness',
    'ja': '曲の音量をそろえる',
  },
  'replay_gain_hint': {
    'ru':
        'Приглушает громкие MP3 с тегом ReplayGain. Треки без тега звучат как раньше.',
    'en':
        'Turns down loud MP3s with ReplayGain tags. Untagged tracks play as before.',
    'ja': 'ReplayGain タグ付きの大きな音の MP3 を抑えます。タグなしの曲はそのままです。',
  },
  'smooth_track_transitions': {
    'ru': 'Плавные переходы',
    'en': 'Smooth transitions',
    'ja': 'なめらかな曲の切り替え',
  },
  'smooth_track_transitions_hint': {
    'ru': 'Звук нарастает в начале и затухает в конце трека',
    'en': 'Fade in at the start and fade out at the end of each track',
    'ja': '曲の始めにフェードインし、終わりにフェードアウト',
  },
  'track_transition_off': {'ru': 'Выкл.', 'en': 'Off', 'ja': 'オフ'},
  'track_transition_off_hint': {
    'ru': 'Обычная смена треков',
    'en': 'Play tracks normally',
    'ja': '通常どおり曲を切り替える',
  },
  'track_transition_fade': {
    'ru': 'Затухание без наложения',
    'en': 'Fade without overlap',
    'ja': '重ねずにフェード',
  },
  'track_transition_crossfade': {
    'ru': 'Кроссфейд · 0,6 с',
    'en': 'Crossfade · 0.6 s',
    'ja': 'クロスフェード · 0.6秒',
  },
  'track_transition_crossfade_hint': {
    'ru':
        'При автопереходе между скачанными треками следующий начнётся чуть раньше. В остальных случаях треки сменяются плавно, без наложения.',
    'en':
        'On automatic transitions between downloaded tracks, the next one starts a little early. Other transitions fade without overlap.',
    'ja': 'ダウンロード済みの曲が自動で切り替わるときは、次の曲が少し早く始まります。それ以外では、曲を重ねずにフェードします。',
  },
  'settings_data': {'ru': 'Данные', 'en': 'Data', 'ja': 'データ'},
  'settings_accent': {
    'ru': 'Цвет акцента',
    'en': 'Accent color',
    'ja': 'アクセントカラー',
  },
  'settings_background': {
    'ru': 'Общий фон',
    'en': 'App background',
    'ja': 'アプリの背景',
  },
  'settings_background_default': {
    'ru': 'Стандартный',
    'en': 'Default',
    'ja': 'デフォルト',
  },
  'settings_background_dimming': {
    'ru': 'Затемнение фона',
    'en': 'Background dimming',
    'ja': '背景の暗さ',
  },
  'settings_background_dimming_hint': {
    'ru': 'Для своего фона и фото плейлистов.',
    'en': 'Applies to custom backgrounds and playlist photos.',
    'ja': 'カスタム背景とプレイリストの写真に適用されます。',
  },
  'settings_background_dimming_reset': {
    'ru': 'По умолчанию',
    'en': 'Reset to default',
    'ja': '初期値に戻す',
  },
  'settings_background_dimming_save': {
    'ru': 'Сохранить',
    'en': 'Save',
    'ja': '保存',
  },
  'settings_background_dimming_save_failed': {
    'ru': 'Не удалось сохранить затемнение. Вернулось прежнее значение.',
    'en': 'Could not save dimming. The previous value was restored.',
    'ja': '暗さを保存できませんでした。以前の設定に戻しました。',
  },
  'settings_background_custom': {
    'ru': 'Моя картинка',
    'en': 'Custom image',
    'ja': 'カスタム画像',
  },
  'settings_background_formats': {
    'ru': 'Фото, GIF или MP4',
    'en': 'Photo, GIF or MP4',
    'ja': '写真、GIF、MP4',
  },
  'settings_background_gif': {'ru': 'GIF', 'en': 'GIF', 'ja': 'GIF'},
  'settings_background_video': {
    'ru': 'Видео MP4',
    'en': 'MP4 video',
    'ja': 'MP4動画',
  },
  'settings_select_background': {
    'ru': 'Выбрать фон',
    'en': 'Choose a background',
    'ja': '背景を選択',
  },
  'settings_background_preparing': {
    'ru': 'Проверяем файл…',
    'en': 'Checking file…',
    'ja': 'ファイルを確認中…',
  },
  'settings_background_limit': {
    'ru':
        'GIF до 24 МиБ или MP4 до 64 МиБ и 30 секунд. Разрешение до 1080p для обоих.',
    'en':
        'GIF up to 24 MiB or MP4 up to 64 MiB and 30 seconds. Both up to 1080p.',
    'ja': 'GIFは24 MiBまで、MP4は64 MiB・30秒まで。解像度はどちらも1080pまでです。',
  },
  'settings_background_invalid': {
    'ru':
        'Не удалось открыть файл. Попробуй другой. Для видео выбери MP4 с H.264.',
    'en':
        'Could not open the file. Try another one. For video, choose an H.264 MP4.',
    'ja': 'ファイルを開けませんでした。別のファイルを選んでください。動画はH.264のMP4をお試しください。',
  },
  'settings_background_save_failed': {
    'ru':
        'Не удалось сохранить фон. Проверь свободное место. Прежний фон не изменился.',
    'en':
        'Could not save the background. Check free storage. The previous background is unchanged.',
    'ja': '背景を保存できませんでした。空き容量を確認してください。元の背景はそのままです。',
  },
  'settings_custom_color': {
    'ru': 'Свой цвет',
    'en': 'Custom color',
    'ja': 'カスタムカラー',
  },
  'settings_remove_background': {
    'ru': 'Убрать свой фон',
    'en': 'Remove custom background',
    'ja': 'カスタム背景を削除',
  },
  'settings_server': {'ru': 'Сервер', 'en': 'Server', 'ja': 'サーバー'},
  'settings_load_error': {
    'ru': 'Не удалось прочитать настройки. Сохранённые данные не изменены.',
    'en': 'Could not read settings. Saved data has not been changed.',
    'ja': '設定を読み込めませんでした。保存済みデータは変更されていません。',
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
  'storage_music': {
    'ru': 'Музыка на устройстве',
    'en': 'Music on this device',
    'ja': '端末内の曲',
  },
  'storage_clips': {'ru': 'Клипы', 'en': 'Videos', 'ja': 'ミュージックビデオ'},
  'storage_artwork': {'ru': 'Обложки', 'en': 'Artwork', 'ja': 'カバー画像'},
  'storage_reclaimable': {
    'ru': 'Можно освободить',
    'en': 'Space you can free',
    'ja': '解放できる容量',
  },
  'storage_cache_hint': {
    'ru':
        'Можно удалить только неиспользуемые обложки и их старые временные файлы.',
    'en': 'Only unused artwork and its old temporary files can be cleared.',
    'ja': '使われていないカバー画像と古い一時ファイルだけを消去できます。',
  },
  'storage_calculating': {
    'ru': 'Считаем размер файлов…',
    'en': 'Checking file sizes…',
    'ja': 'ファイルサイズを確認中…',
  },
  'storage_cleaning': {
    'ru': 'Удаляем лишние обложки…',
    'en': 'Clearing unused artwork…',
    'ja': '使われていないカバー画像を消去中…',
  },
  'storage_read_error': {
    'ru': 'Не удалось посчитать размер файлов.',
    'en': 'Could not check file sizes.',
    'ja': 'ファイルサイズを確認できませんでした。',
  },
  'storage_size_units': {
    'ru': 'Б/КБ/МБ/ГБ/ТБ',
    'en': 'B/kB/MB/GB/TB',
    'ja': 'B/kB/MB/GB/TB',
  },
  'storage_estimated': {
    'ru': 'Можно освободить примерно {size}.',
    'en': 'This can free about {size}.',
    'ja': '約{size}の容量を解放できます。',
  },
  'clear_cache_body': {
    'ru': 'Треки, клипы, тексты, фоны, плейлисты и статистика останутся.',
    'en':
        'Music, videos, lyrics, backgrounds, playlists, and listening history will stay.',
    'ja': '曲、動画、歌詞、背景、プレイリスト、再生履歴はそのままです。',
  },
  'cache_clear_failed': {
    'ru': 'Не удалось очистить кэш полностью.',
    'en': 'Some cached files could not be cleared.',
    'ja': '一部のキャッシュを消去できませんでした。',
  },
  'storage_freed': {
    'ru': 'Освобождено {size}.',
    'en': 'Freed {size}.',
    'ja': '{size}の容量を解放しました。',
  },
  'storage_no_files_to_clear': {
    'ru': 'К удалению ничего не осталось.',
    'en': 'There’s nothing left to clear.',
    'ja': '消去できるファイルはありません。',
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
    'ru': 'Проверь данные трека',
    'en': 'Check track information',
    'ja': '曲情報を確認',
  },
  'metadata_confirmation_hint': {
    'ru':
        'Не удалось подтвердить исполнителя. Укажи его имя, а не название канала.',
    'en':
        'Could not confirm the artist. Enter the artist’s name, not the channel name.',
    'ja': 'アーティストを確認できませんでした。チャンネル名ではなく、アーティスト名を入力してください。',
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
    'ru': 'Добавить альбом или плейлист',
    'en': 'Add an album or playlist',
    'ja': 'アルバムまたはプレイリストを追加',
  },
  'import_partial': {
    'ru': 'Не все треки добавлены',
    'en': 'Not all tracks were added',
    'ja': '一部の曲を追加できませんでした',
  },
  'import_failed': {
    'ru': 'Не удалось добавить треки',
    'en': 'Could not add tracks',
    'ja': '曲を追加できませんでした',
  },
  'import_complete': {
    'ru': 'Добавлено треков',
    'en': 'Tracks added',
    'ja': '追加した曲数',
  },
  'track_search_complete': {
    'ru': 'Трек найден',
    'en': 'Track found',
    'ja': '曲が見つかりました',
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
  'downloaded_only': {
    'ru': 'Только скачанное',
    'en': 'Downloaded only',
    'ja': 'ダウンロード済みのみ',
  },
  'downloaded_only_hint': {
    'ru': 'Показывать музыку с устройства и не обращаться к серверу.',
    'en': 'Show music on this device and pause server connections.',
    'ja': '端末にある曲を表示し、サーバーに接続しません。',
  },
  'downloaded_only_server_paused': {
    'ru': 'Проверка сервера отключена в режиме «Только скачанное».',
    'en': 'Connection testing is off in Downloaded only mode.',
    'ja': '「ダウンロード済みのみ」では接続をテストできません。',
  },
  'downloaded_only_action': {
    'ru': 'Выключи «Только скачанное», чтобы обратиться к серверу.',
    'en': 'Turn off Downloaded only to use the server.',
    'ja': 'サーバーを使うには「ダウンロード済みのみ」をオフにしてください。',
  },
  'downloaded_only_busy': {
    'ru': 'Дождись окончания поиска или загрузки, затем включи режим.',
    'en': 'Wait for the search or download to finish, then try again.',
    'ja': '検索やダウンロードが終わってから、もう一度お試しください。',
  },
  'downloaded_only_stream_busy': {
    'ru': 'Плеер ещё переключает трек. Попробуй снова.',
    'en': 'The player is still changing tracks. Try again in a moment.',
    'ja': '曲を切り替えています。少し待ってからお試しください。',
  },
  'downloaded_only_stop_stream': {
    'ru': 'Сейчас открыт трек с сервера. Остановить его и включить режим?',
    'en': 'A track from the server is open. Stop it and switch modes?',
    'ja': 'サーバーから曲を開いています。曲を停止して切り替えますか？',
  },
  'downloaded_only_stop_and_enable': {
    'ru': 'Остановить и включить',
    'en': 'Stop and turn on',
    'ja': '停止してオンにする',
  },
  'downloaded_only_save_failed': {
    'ru': 'Не удалось сохранить режим. Он действует до закрытия плеера.',
    'en': 'Could not save this mode. It applies until you close the player.',
    'ja': 'モードを保存できませんでした。プレーヤーを閉じるまで有効です。',
  },
  'downloaded_only_unavailable': {
    'ru': 'Не скачано',
    'en': 'Not downloaded',
    'ja': '未ダウンロード',
  },
  'downloaded_only_empty': {
    'ru': 'На устройстве пока нет треков.',
    'en': 'No tracks on this device yet.',
    'ja': '端末に保存された曲はまだありません。',
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
    'ru': 'Укажи адрес с http:// или https://, без логина и пароля.',
    'en':
        'Use an address that starts with http:// or https://, without a username or password.',
    'ja': 'http://またはhttps://で始まるアドレスを入力してください。ユーザー名とパスワードは入れないでください。',
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
    'ru': 'Добавляем треки',
    'en': 'Adding tracks',
    'ja': '曲を追加中',
  },
  'server_waiting_for_response': {
    'ru': 'Ждём ответа сервера…',
    'en': 'Waiting for the server…',
    'ja': 'サーバーからの応答を待っています…',
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
    'ru': 'Адрес сохранён. Перезапусти плеер, чтобы подключиться по нему.',
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
  'about': {'ru': 'О приложении', 'en': 'About', 'ja': 'アプリについて'},
  'version': {'ru': 'Версия', 'en': 'Version', 'ja': 'バージョン'},
  'personal_player': {
    'ru': 'Скачанные треки можно слушать без сервера и аккаунта.',
    'en': 'Play downloaded tracks without a server or an account.',
    'ja': 'ダウンロード済みの曲は、サーバーやアカウントなしで聴けます。',
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
    'ru': 'Нажми на сердечко рядом с треком, чтобы добавить его в избранное.',
    'en': 'Tap the heart next to a track to add it to favorites.',
    'ja': '曲の横にあるハートを押すと、お気に入りに追加できます。',
  },
  'playlist_empty': {
    'ru': 'В библиотеке открой «⋯» рядом с треком и выбери этот плейлист.',
    'en': 'Open ⋯ next to a track in your library and choose this playlist.',
    'ja': 'ライブラリで曲の横の「⋯」を開き、このプレイリストを選びます。',
  },
  'no_data': {'ru': 'Нет данных', 'en': 'No data', 'ja': 'データなし'},
  'search_online': {
    'ru': 'Искать в интернете',
    'en': 'Search online',
    'ja': 'ウェブで検索',
  },
  'shuffle_on_tooltip': {
    'ru': 'Выключить перемешивание',
    'en': 'Turn off shuffle',
    'ja': 'シャッフルをOFF',
  },
  'shuffle_off_tooltip': {'ru': 'Перемешать', 'en': 'Shuffle', 'ja': 'シャッフル'},

  // ── Lyrics ──
  'open_lyrics': {
    'ru': 'Открыть текст песни',
    'en': 'Open lyrics',
    'ja': '歌詞を開く',
  },
  'no_lyrics': {
    'ru': 'Текст песни не найден',
    'en': 'Lyrics not found',
    'ja': '歌詞が見つかりません',
  },
  'lyric_timing': {
    'ru': 'Синхронизация текста',
    'en': 'Lyric timing',
    'ja': '歌詞のタイミング調整',
  },
  'lyric_edit_line': {'ru': 'Изменить строку', 'en': 'Edit line', 'ja': '行を編集'},
  'lyric_line_label': {
    'ru': 'Текст строки',
    'en': 'Lyrics for this line',
    'ja': 'この行の歌詞',
  },
  'lyric_line_invalid': {
    'ru': 'Только текст, без меток времени и переносов.',
    'en': 'Use plain text, without timestamps or line breaks.',
    'ja': 'タイムタグや改行を入れずに入力してください。',
  },
  'lyric_line_revert': {
    'ru': 'Вернуть исходную строку',
    'en': 'Restore original line',
    'ja': '元の行に戻す',
  },
  'lyric_line_share_hint': {
    'ru': 'На проверку уйдут все изменённые строки этого трека.',
    'en': 'Send all edited lines for this track for review.',
    'ja': 'この曲で編集したすべての行を確認用に送信します。',
  },
  'lyric_line_track_changed': {
    'ru': 'Трек сменился. Открой редактор снова.',
    'en': 'The track changed. Open the editor again.',
    'ja': '曲が切り替わりました。編集画面を開き直してください。',
  },
  'lyric_timing_earlier': {'ru': 'Раньше', 'en': 'Earlier', 'ja': '早める'},
  'lyric_timing_later': {'ru': 'Позже', 'en': 'Later', 'ja': '遅らせる'},
  'lyric_timing_reset': {'ru': 'Сбросить', 'en': 'Reset', 'ja': 'リセット'},
  'lyric_timing_done': {'ru': 'Готово', 'en': 'Done', 'ja': '完了'},
  'lyric_timing_no_offset': {
    'ru': 'Без сдвига',
    'en': 'No adjustment',
    'ja': '調整なし',
  },
  'lyric_timing_advanced': {
    'ru': 'На {seconds} с раньше',
    'en': '{seconds} s earlier',
    'ja': '{seconds} 秒早く',
  },
  'lyric_timing_delayed': {
    'ru': 'На {seconds} с позже',
    'en': '{seconds} s later',
    'ja': '{seconds} 秒遅く',
  },
  'lyric_timing_save_error': {
    'ru': 'Не удалось сохранить. Попробуй ещё раз.',
    'en': 'Could not save. Try again.',
    'ja': '保存できませんでした。もう一度お試しください。',
  },
  'lyric_timing_propose': {
    'ru': 'Отправить на проверку',
    'en': 'Send for review',
    'ja': '確認用に送信',
  },
  'lyric_timing_propose_hint': {
    'ru': 'Сохранить поправку на этом устройстве и отправить её на сервер',
    'en': 'Save the adjustment on this device and send it to the server',
    'ja': '調整をこの端末に保存して、サーバーに送信します',
  },
  'lyric_timing_sending': {
    'ru': 'Отправляем на проверку…',
    'en': 'Sending for review…',
    'ja': '送信中…',
  },
  'lyric_timing_proposal_pending': {
    'ru': 'Поправка ждёт проверки.',
    'en': 'Suggestion awaiting review.',
    'ja': '提案は確認待ちです。',
  },
  'lyric_timing_proposal_accepted': {
    'ru': 'Эту поправку уже приняли.',
    'en': 'This suggestion was already accepted.',
    'ja': 'この提案は承認済みです。',
  },
  'lyric_timing_proposal_rejected': {
    'ru': 'Эту поправку отклонили. На устройстве она сохранена.',
    'en': 'This suggestion was declined. The local adjustment is still saved.',
    'ja': '提案は却下されました。端末の調整は保存されています。',
  },
  'lyric_timing_proposal_conflict': {
    'ru':
        'На сервере другая версия записи или текста. Поправка сохранена на устройстве.',
    'en':
        'The server has different audio or lyrics. The local adjustment is saved.',
    'ja': 'サーバーの音源または歌詞のバージョンが異なります。調整は端末に保存済みです。',
  },
  'lyric_timing_proposal_offline': {
    'ru': 'Сервер недоступен. Поправка сохранена на устройстве.',
    'en': 'The server is unavailable. The local adjustment is saved.',
    'ja': 'サーバーに接続できません。調整は端末に保存済みです。',
  },
  'lyric_timing_proposal_limit': {
    'ru':
        'Сервер пока не принимает новые предложения. Поправка сохранена на устройстве.',
    'en':
        'The server is not taking new suggestions right now. The local adjustment is saved.',
    'ja': '現在サーバーは新しい提案を受け付けていません。調整は端末に保存済みです。',
  },
  'lyric_timing_proposal_failed': {
    'ru': 'Не удалось отправить. Поправка сохранена на устройстве.',
    'en': 'Could not send the suggestion. The local adjustment is saved.',
    'ja': '提案を送信できませんでした。調整は端末に保存済みです。',
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
    'ru': 'Если у трека есть клип, плеер покажет его вместо обложки.',
    'en': 'Show the music video in place of the cover when one is available.',
    'ja': '曲に動画がある場合、ジャケットの代わりに再生します。',
  },
  'discord_settings': {'ru': 'Discord', 'en': 'Discord', 'ja': 'Discord'},
  'discord_presence_enabled': {
    'ru': 'Показывать, что я слушаю',
    'en': 'Show what I’m listening to',
    'ja': '聴いている曲を表示',
  },
  'discord_presence_enabled_hint': {
    'ru': 'Показывает трек и исполнителя в активности «Слушает».',
    'en': 'Show the track and artist in Discord’s Listening activity.',
    'ja': 'Discordのアクティビティに曲名とアーティスト名を表示します。',
  },
  'discord_hide_on_pause': {
    'ru': 'Скрывать трек на паузе',
    'en': 'Hide track when paused',
    'ja': '一時停止中は曲を非表示',
  },
  'discord_hide_on_pause_hint': {
    'ru': 'Активность возвращается, когда музыка снова играет.',
    'en': 'Show the activity again when playback resumes.',
    'ja': '再生を再開するとアクティビティが再表示されます。',
  },
  'discord_privacy_save_failed': {
    'ru':
        'Не удалось сохранить настройки Discord. После перезапуска проверь их снова.',
    'en': 'Could not save Discord settings. Check them again after restarting.',
    'ja': 'Discordの設定を保存できませんでした。再起動後に設定を確認してください。',
  },
  'discord_lyrics_status': {
    'ru': 'Текст песни в статусе Discord',
    'en': 'Lyrics in Discord status',
    'ja': 'Discordのステータスに歌詞を表示',
  },
  'discord_lyrics_status_hint': {
    'ru':
        'Показывает текущую строку в коротком статусе, пока играет музыка. Карточка профиля не меняется.',
    'en':
        'Show the current lyric in the short status during playback. The profile card stays the same.',
    'ja': '短いステータスに再生中の歌詞を表示します。プロフィールカードは変わりません。',
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
    'ru': 'Показывать кнопку GitHub в статусе',
    'en': 'Show the GitHub button in your status',
    'ja': 'DiscordステータスにGitHubリンクボタンを表示',
  },

  // ── Downloads management ──
  'delete_downloaded_track': {
    'ru': 'Удалить из загрузок',
    'en': 'Delete from downloads',
    'ja': 'ダウンロードから削除',
  },
  'track_deleted_from_storage': {
    'ru': 'Скачанная копия удалена',
    'en': 'Download removed',
    'ja': 'ダウンロード済みのコピーを削除しました',
  },

  // ── Artists & Albums ──
  'sidebar_artists': {'ru': 'Исполнители', 'en': 'Artists', 'ja': 'アーティスト'},
  'artists_empty': {
    'ru': 'Исполнители появятся здесь, когда добавишь треки в библиотеку.',
    'en': 'Add tracks to your library to see their artists here.',
    'ja': 'ライブラリに曲を追加すると、アーティストがここに表示されます。',
  },
  'artists_search_empty': {
    'ru': 'Исполнители не найдены. Попробуй другое имя.',
    'en': 'No matching artists. Try another name.',
    'ja': 'アーティストが見つかりません。別の名前を試してください。',
  },
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
