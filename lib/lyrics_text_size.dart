enum LyricsTextSize {
  small(0.875),
  normal(1),
  large(1.25);

  const LyricsTextSize(this._scale);
  final double _scale;

  double get activeFontSize => 32 * _scale;
  double get inactiveFontSize => 20 * _scale;
  double get plainFontSize => 24 * _scale;

  static LyricsTextSize? tryParse(Object? value) => switch (value) {
    'small' => small,
    'normal' => normal,
    'large' => large,
    _ => null,
  };

  static LyricsTextSize fromSettings(Object? value) =>
      tryParse(value) ?? normal;
}
