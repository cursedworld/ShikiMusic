import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

const mprisRootInterface = 'org.mpris.MediaPlayer2';
const mprisPlayerInterface = 'org.mpris.MediaPlayer2.Player';

/// Event-driven OS controls over the existing player. Owns no audio engine,
/// polling timer or background isolate. Position is extrapolated when queried.
class LinuxMediaSession extends DBusObject {
  LinuxMediaSession({
    required this.onAction,
    required this.onShuffle,
    required this.onRepeat,
    required this.onVolume,
  }) : super(DBusObjectPath('/org/mpris/MediaPlayer2'));

  final void Function(String action, Duration? position) onAction;
  final ValueChanged<bool> onShuffle;
  final ValueChanged<String> onRepeat;
  final ValueChanged<double> onVolume;
  DBusClient? _connection;
  bool _closed = false;
  final Stopwatch _clock = Stopwatch();
  Duration _position = Duration.zero, _duration = Duration.zero;
  final Map<String, DBusValue> _state = {
    'PlaybackStatus': const DBusString('Stopped'),
    'LoopStatus': const DBusString('None'),
    'Rate': const DBusDouble(1),
    'Shuffle': const DBusBoolean(false),
    'Metadata': DBusDict.stringVariant({}),
    'Volume': const DBusDouble(1),
    'MinimumRate': const DBusDouble(1),
    'MaximumRate': const DBusDouble(1),
    'CanGoNext': const DBusBoolean(false),
    'CanGoPrevious': const DBusBoolean(false),
    'CanPlay': const DBusBoolean(false),
    'CanPause': const DBusBoolean(false),
    'CanSeek': const DBusBoolean(false),
    'CanControl': const DBusBoolean(true),
  };
  final Map<String, DBusValue> _root = {
    'CanQuit': const DBusBoolean(false),
    'CanRaise': const DBusBoolean(false),
    'HasTrackList': const DBusBoolean(false),
    'Identity': const DBusString('ShikiMusic'),
    'SupportedUriSchemes': DBusArray.string([]),
    'SupportedMimeTypes': DBusArray.string([]),
  };
  DBusObjectPath _track = DBusObjectPath(
    '/org/mpris/MediaPlayer2/TrackList/NoTrack',
  );

  Future<void> start() async {
    if (_closed || _connection != null) return;
    DBusClient? connection;
    try {
      connection = DBusClient.session();
      _connection = connection;
      await connection
          .requestName('org.mpris.MediaPlayer2.ShikiMusic.instance$pid')
          .timeout(const Duration(seconds: 3));
      if (_closed) return;
      await connection.registerObject(this).timeout(const Duration(seconds: 3));
    } catch (error) {
      debugPrint('MPRIS unavailable: $error');
      await connection?.close();
      if (identical(_connection, connection)) _connection = null;
    }
  }

  Future<void> close() async {
    _closed = true;
    _clock.stop();
    final connection = _connection;
    _connection = null;
    await connection?.close();
  }

  Duration get position {
    final value =
        _position + (_clock.isRunning ? _clock.elapsed : Duration.zero);
    return _duration > Duration.zero && value > _duration ? _duration : value;
  }

  void updatePosition(Duration value) {
    _position = value < Duration.zero ? Duration.zero : value;
    _clock.reset();
  }

  void update({
    required int? id,
    required String title,
    required List<String> artists,
    required String? album,
    required String? artwork,
    required Duration duration,
    required Duration position,
    required bool playing,
    bool stopped = false,
    required bool canNext,
    required bool canPrevious,
    required bool shuffled,
    required String loop,
    required double volume,
  }) {
    if (_closed) return;
    updatePosition(position);
    _duration = duration;
    if (playing && !stopped && id != null) {
      _clock.start();
    } else {
      _clock.stop();
    }
    _track = DBusObjectPath(
      id == null
          ? '/org/mpris/MediaPlayer2/TrackList/NoTrack'
          : '/org/mpris/MediaPlayer2/track_$id',
    );
    final next = <String, DBusValue>{
      'PlaybackStatus': DBusString(
        id == null || stopped
            ? 'Stopped'
            : playing
            ? 'Playing'
            : 'Paused',
      ),
      'LoopStatus': DBusString(loop),
      'Shuffle': DBusBoolean(shuffled),
      'Volume': DBusDouble(volume),
      'Metadata': DBusDict.stringVariant(
        id == null
            ? {}
            : {
                'mpris:trackid': _track,
                'xesam:title': DBusString(title),
                'xesam:artist': DBusArray.string(artists),
                if (album != null) 'xesam:album': DBusString(album),
                if (artwork != null && artwork.isNotEmpty)
                  'mpris:artUrl': DBusString(artwork),
                if (duration > Duration.zero)
                  'mpris:length': DBusInt64(duration.inMicroseconds),
              },
      ),
      'CanGoNext': DBusBoolean(id != null && canNext),
      'CanGoPrevious': DBusBoolean(id != null && canPrevious),
      'CanPlay': DBusBoolean(id != null),
      'CanPause': DBusBoolean(id != null),
      'CanSeek': DBusBoolean(id != null && duration > Duration.zero),
    };
    next.removeWhere((key, value) => _state[key] == value);
    if (next.isEmpty) return;
    _state.addAll(next);
    unawaited(
      _signal(
        () => emitPropertiesChanged(
          mprisPlayerInterface,
          changedProperties: next,
        ),
      ),
    );
  }

  void seeked(Duration value) {
    updatePosition(value);
    unawaited(
      _signal(
        () => emitSignal(mprisPlayerInterface, 'Seeked', [
          DBusInt64(value.inMicroseconds),
        ]),
      ),
    );
  }

  Future<void> _signal(Future<void> Function() send) async {
    if (_closed) return;
    try {
      await send();
    } catch (error) {
      debugPrint('MPRIS update failed: $error');
    }
  }

  Map<String, DBusValue>? _properties(String interface) => switch (interface) {
    mprisRootInterface => _root,
    mprisPlayerInterface => {
      ..._state,
      'Position': DBusInt64(position.inMicroseconds),
    },
    _ => null,
  };

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = _properties(interface)?[name];
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    final values = _properties(interface);
    return values == null
        ? DBusMethodErrorResponse.unknownInterface()
        : DBusGetAllPropertiesResponse(values);
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    final call = methodCall;
    if (_closed) return DBusMethodErrorResponse.failed('Session closed');
    if (call.interface == mprisRootInterface &&
        ['Raise', 'Quit'].contains(call.name)) {
      return call.values.isEmpty
          ? DBusMethodErrorResponse.notSupported()
          : DBusMethodErrorResponse.invalidArgs();
    }
    if (call.interface != mprisPlayerInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final signature = call.signature.value;
    final actions = {
      'Next': 'next',
      'Previous': 'previous',
      'Pause': 'pause',
      'PlayPause': 'toggle',
      'Stop': 'stop',
      'Play': 'play',
    };
    final action = actions[call.name];
    if (action != null) {
      if (signature.isNotEmpty) return DBusMethodErrorResponse.invalidArgs();
      final capability = switch (call.name) {
        'Next' => 'CanGoNext',
        'Previous' => 'CanGoPrevious',
        _ => 'CanPlay',
      };
      if (_state[capability] == const DBusBoolean(true)) onAction(action, null);
    } else if (call.name == 'Seek' || call.name == 'SetPosition') {
      if (signature != (call.name == 'Seek' ? 'x' : 'ox')) {
        return DBusMethodErrorResponse.invalidArgs();
      }
      if (_state['CanSeek'] == const DBusBoolean(true)) {
        if (call.name == 'SetPosition' && call.values[0] != _track) {
          return DBusMethodSuccessResponse();
        }
        final micros = call.values.last.asInt64();
        final target = call.name == 'Seek'
            ? position + Duration(microseconds: micros)
            : Duration(microseconds: micros);
        if (call.name == 'Seek' && target > _duration) {
          if (_state['CanGoNext'] == const DBusBoolean(true)) {
            onAction('next', null);
          }
        } else if (target >= Duration.zero && target <= _duration) {
          onAction('seek', target);
        } else if (call.name == 'Seek' && target < Duration.zero) {
          onAction('seek', Duration.zero);
        }
      }
    } else if (call.name == 'OpenUri') {
      return signature == 's'
          ? DBusMethodErrorResponse.notSupported()
          : DBusMethodErrorResponse.invalidArgs();
    } else {
      return DBusMethodErrorResponse.unknownMethod();
    }
    return DBusMethodSuccessResponse();
  }

  @override
  Future<DBusMethodResponse> setProperty(
    String interface,
    String name,
    DBusValue value,
  ) async {
    if (_closed) return DBusMethodErrorResponse.failed('Session closed');
    if (interface != mprisPlayerInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    if (name == 'Shuffle' && value is DBusBoolean) {
      onShuffle(value.value);
    } else if (name == 'LoopStatus' &&
        value is DBusString &&
        ['None', 'Playlist', 'Track'].contains(value.value)) {
      onRepeat(value.value);
    } else if (name == 'Volume' &&
        value is DBusDouble &&
        value.value.isFinite) {
      onVolume(value.value.clamp(0, 1));
    } else if (name == 'Rate' && value == const DBusDouble(1)) {
      return DBusMethodSuccessResponse();
    } else if (_state.containsKey(name)) {
      return DBusMethodErrorResponse.invalidArgs();
    } else {
      return DBusMethodErrorResponse.unknownProperty();
    }
    return DBusMethodSuccessResponse();
  }

  @override
  List<DBusIntrospectInterface> introspect() {
    DBusIntrospectProperty property(String name, DBusValue value) =>
        DBusIntrospectProperty(
          name,
          value.signature,
          access: ['LoopStatus', 'Rate', 'Shuffle', 'Volume'].contains(name)
              ? DBusPropertyAccess.readwrite
              : DBusPropertyAccess.read,
        );
    DBusIntrospectArgument input(String type, String name) =>
        DBusIntrospectArgument(
          DBusSignature(type),
          DBusArgumentDirection.in_,
          name: name,
        );
    return [
      DBusIntrospectInterface(
        mprisRootInterface,
        methods: [DBusIntrospectMethod('Raise'), DBusIntrospectMethod('Quit')],
        properties: [
          for (final entry in _root.entries) property(entry.key, entry.value),
        ],
      ),
      DBusIntrospectInterface(
        mprisPlayerInterface,
        methods: [
          for (final name in [
            'Next',
            'Previous',
            'Pause',
            'PlayPause',
            'Stop',
            'Play',
          ])
            DBusIntrospectMethod(name),
          DBusIntrospectMethod('Seek', args: [input('x', 'Offset')]),
          DBusIntrospectMethod(
            'SetPosition',
            args: [input('o', 'TrackId'), input('x', 'Position')],
          ),
          DBusIntrospectMethod('OpenUri', args: [input('s', 'Uri')]),
        ],
        properties: [
          for (final entry in _properties(mprisPlayerInterface)!.entries)
            property(entry.key, entry.value),
        ],
        signals: [
          DBusIntrospectSignal(
            'Seeked',
            args: [
              DBusIntrospectArgument(
                DBusSignature('x'),
                DBusArgumentDirection.out,
                name: 'Position',
              ),
            ],
          ),
        ],
      ),
    ];
  }
}
