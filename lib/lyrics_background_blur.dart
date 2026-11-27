const defaultLyricsBackgroundBlur = 50;

bool isValidLyricsBackgroundBlur(Object? value) =>
    value is int && value >= 0 && value <= 100;

int lyricsBackgroundBlurFromSettings(Object? value) =>
    isValidLyricsBackgroundBlur(value)
    ? value as int
    : defaultLyricsBackgroundBlur;
