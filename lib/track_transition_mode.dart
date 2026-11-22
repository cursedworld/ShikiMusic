enum TrackTransitionMode {
  off,
  fade,
  crossfade;

  static TrackTransitionMode fromSettings(Object? mode, Object? legacyFade) =>
      switch (mode) {
        'off' => off,
        'fade' => fade,
        'crossfade' => crossfade,
        _ => legacyFade == true ? fade : off,
      };
}
