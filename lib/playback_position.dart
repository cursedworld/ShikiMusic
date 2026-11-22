import 'package:audioplayers/audioplayers.dart';

const playbackPositionInterval = Duration(milliseconds: 200);

/// Audio/video run on their native clocks. Position reporting must not keep
/// Flutter rendering at the monitor refresh rate just to show whole seconds.
/// Explicit seeks and pause/stop still call update() immediately in AudioPlayer.
TimerPositionUpdater playbackPositionUpdater(
  Future<Duration?> Function() getPosition,
) => TimerPositionUpdater(
  getPosition: getPosition,
  interval: playbackPositionInterval,
);
