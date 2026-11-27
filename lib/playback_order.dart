import 'dart:math';

import 'globals.dart' show LoopMode;

/// One position in a playback session, not a library track. Inserting the
/// same track twice creates two independent positions.
class PlaybackEntry {
  PlaybackEntry._(this.slot, this.track, {this.inserted = false});

  final int slot;
  final Map track;
  final bool inserted;
  int get trackId => track['id'] as int;
}

enum PlaybackLane { repeat, insertion, forward, base }

typedef PlaybackMove = ({PlaybackEntry entry, PlaybackLane lane});

/// The base cursor is the furthest base position reached in this session.
/// Rewinding moves through history without consuming pending insertions or
/// moving that cursor; the forward stack leads back to it.
class PlaybackOrder {
  static const historyLimit = 64;

  List<PlaybackEntry> _base = [];
  List<dynamic> _baseTracks = const [];
  Map<int, int> _baseIndexBySlot = {};
  List<PlaybackEntry>? _unshuffled;
  List<dynamic> _unshuffledTracks = const [];
  final _pending = <PlaybackEntry>[];
  // New insertions can go ahead of redo. Entries already waiting when we
  // rewound still belong after the track we had reached.
  int _pendingAheadOfForward = 0;
  final _history = <PlaybackEntry>[];
  final _forward = <PlaybackEntry>[];
  int _lastSlot = 0;
  int _baseIndex = 0;
  PlaybackEntry? _current;

  List<dynamic> get baseTracks => _baseTracks;
  int get baseIndex => _baseIndex;
  PlaybackEntry? get current => _current;
  bool get shuffled => _unshuffled != null;
  int get insertionCount => _pending.length;
  Iterable<PlaybackEntry> get insertions => _pending.map((entry) => entry);

  /// Used by catalog/asset updates, not by playback-position ticks.
  Iterable<Map> get retainedTracks sync* {
    for (final entry in _base) {
      yield entry.track;
    }
    final seen = <int>{};
    for (final entries in [
      _pending,
      _history,
      _forward,
      [_current],
    ]) {
      for (final entry in entries) {
        if (entry != null && entry.inserted && seen.add(entry.slot)) {
          yield entry.track;
        }
      }
    }
  }

  void reset(Iterable<dynamic> tracks, int index) {
    _base = [
      for (final track in tracks)
        if (_validTrack(track)) PlaybackEntry._(++_lastSlot, track as Map),
    ];
    _unshuffled = null;
    _unshuffledTracks = const [];
    _pending.clear();
    _pendingAheadOfForward = 0;
    _history.clear();
    _forward.clear();
    _indexBase();
    _baseIndex = _base.isEmpty ? 0 : index.clamp(0, _base.length - 1);
    _current = _base.isEmpty ? null : _base[_baseIndex];
  }

  void jumpToBase(int index) {
    if (index < 0 || index >= _base.length) return;
    take((entry: _base[index], lane: PlaybackLane.base));
  }

  int insertNext(Iterable<dynamic> tracks, {int? alreadyStarting}) {
    if (_current == null) return 0;
    final entries = [
      for (final track in tracks)
        if (_validTrack(track))
          PlaybackEntry._(++_lastSlot, track as Map, inserted: true),
    ];
    if (entries.isNotEmpty) {
      final locked =
          _pending.isNotEmpty && _pending.first.slot == alreadyStarting;
      _pending.insertAll(locked ? 1 : 0, entries);
      if (_forward.isNotEmpty) _pendingAheadOfForward += entries.length;
    }
    return entries.length;
  }

  bool removeInsertion(int slot, {int? alreadyStarting}) {
    if (slot == alreadyStarting) return false;
    final index = _pending.indexWhere((entry) => entry.slot == slot);
    if (index < 0) return false;
    _pending.removeAt(index);
    if (index < _pendingAheadOfForward) _pendingAheadOfForward--;
    return true;
  }

  bool clearInsertions({int? alreadyStarting}) {
    final before = _pending.length;
    final keepAhead = _pending
        .take(_pendingAheadOfForward)
        .any((entry) => entry.slot == alreadyStarting);
    _pending.removeWhere((entry) => entry.slot != alreadyStarting);
    _pendingAheadOfForward = keepAhead ? 1 : 0;
    return _pending.length != before;
  }

  /// Remove an owned recording from every lane without rebuilding the other
  /// slots. The caller decides whether to stop/prepare a replacement decoder.
  bool removeTracks(bool Function(Map track) matches) {
    final current = _current;
    if (current == null || !retainedTracks.any(matches)) return false;
    bool remove(PlaybackEntry entry) => matches(entry.track);
    final removeCurrent = remove(current);
    final afterAnchor = _base
        .take(_baseIndex + 1)
        .where((e) => !remove(e))
        .length;
    final anchorRemoved = remove(_base[_baseIndex]);
    _pendingAheadOfForward = _pending
        .take(_pendingAheadOfForward)
        .where((entry) => !remove(entry))
        .length;
    _pending.removeWhere(remove);
    _history.removeWhere(remove);
    _forward.removeWhere(remove);
    if (_forward.isEmpty) _pendingAheadOfForward = 0;
    _base.removeWhere(remove);
    if (_base.isEmpty) {
      // An insertion can outlive the last base track. Keep it and the other
      // pending tracks usable instead of resetting the whole session.
      final survivor = !removeCurrent
          ? current
          : _forward.lastOrNull ?? _pending.firstOrNull ?? _history.lastOrNull;
      if (survivor == null) {
        reset(const [], 0);
        return true;
      }
      _pending.remove(survivor);
      _forward.remove(survivor);
      _history.remove(survivor);
      _pendingAheadOfForward = 0;
      _unshuffled = null;
      _unshuffledTracks = const [];
      _base = [PlaybackEntry._(survivor.slot, survivor.track)];
      _baseIndex = 0;
      _current = _base.first;
    } else {
      _baseIndex = (removeCurrent ? afterAnchor : afterAnchor - 1).clamp(
        0,
        _base.length - 1,
      );
      if (removeCurrent) {
        // Resume the redo path if the deleted recording was revisited.
        // Otherwise a newer base anchor could be played twice.
        if (_forward.isNotEmpty) {
          _current = _forward.removeLast();
          _baseIndex = (afterAnchor - 1).clamp(0, _base.length - 1);
          if (_forward.isEmpty) _pendingAheadOfForward = 0;
        } else {
          _current = _base[_baseIndex];
          _history.removeWhere((entry) => entry == _current);
        }
      } else if (anchorRemoved &&
          afterAnchor == 0 &&
          _forward.isEmpty &&
          current != _base.first) {
        // The active insertion had not reached the next surviving base item.
        _forward.add(_base.first);
        _pendingAheadOfForward = _pending.length;
      }
      if (_unshuffled case final original?) {
        original.removeWhere(remove);
        _unshuffledTracks = _tracks(original);
      }
    }
    _indexBase();
    return true;
  }

  PlaybackMove? next(
    LoopMode loop, {
    required bool automatic,
    int? alreadyStarting,
    bool Function(PlaybackEntry)? isPlayable,
  }) {
    final active = _current;
    if (active == null) return null;
    bool canPlay(PlaybackEntry entry) => isPlayable?.call(entry) ?? true;
    if (automatic && loop == LoopMode.one && canPlay(active)) {
      return (entry: active, lane: PlaybackLane.repeat);
    }
    if (automatic && alreadyStarting != null) {
      for (final entry in _pending) {
        if (entry.slot == alreadyStarting) {
          return (entry: entry, lane: PlaybackLane.insertion);
        }
      }
      for (final entry in _forward.reversed) {
        if (entry.slot == alreadyStarting) {
          return (entry: entry, lane: PlaybackLane.forward);
        }
      }
      final index = _baseIndexBySlot[alreadyStarting];
      if (index != null) return (entry: _base[index], lane: PlaybackLane.base);
    }

    final split = _forward.isEmpty ? _pending.length : _pendingAheadOfForward;
    for (var index = 0; index < split; index++) {
      final entry = _pending[index];
      if (canPlay(entry)) return (entry: entry, lane: PlaybackLane.insertion);
    }
    for (final entry in _forward.reversed) {
      if (canPlay(entry)) return (entry: entry, lane: PlaybackLane.forward);
    }
    for (var index = split; index < _pending.length; index++) {
      final entry = _pending[index];
      if (canPlay(entry)) return (entry: entry, lane: PlaybackLane.insertion);
    }
    for (var index = _baseIndex + 1; index < _base.length; index++) {
      final entry = _base[index];
      if (canPlay(entry)) return (entry: entry, lane: PlaybackLane.base);
    }
    if (loop == LoopMode.list || (!automatic && loop == LoopMode.one)) {
      for (
        var index = 0;
        index <= _baseIndex && index < _base.length;
        index++
      ) {
        final entry = _base[index];
        if (canPlay(entry)) return (entry: entry, lane: PlaybackLane.base);
      }
    }
    return null;
  }

  void take(PlaybackMove move, {bool skipUnavailable = false}) {
    if (move.lane == PlaybackLane.repeat) return;
    switch (move.lane) {
      case PlaybackLane.insertion:
        final index = skipUnavailable
            ? _pending.indexOf(move.entry)
            : (_pending.firstOrNull == move.entry ? 0 : -1);
        if (index < 0) return;
        _pending.removeAt(index);
        if (index < _pendingAheadOfForward) _pendingAheadOfForward--;
      case PlaybackLane.forward:
        final index = skipUnavailable
            ? _forward.lastIndexOf(move.entry)
            : (_forward.lastOrNull == move.entry ? _forward.length - 1 : -1);
        if (index < 0) return;
        _forward.removeAt(index);
        if (_forward.isEmpty) _pendingAheadOfForward = 0;
      case PlaybackLane.base:
        final index = _baseIndexBySlot[move.entry.slot];
        if (index == null) return;
        _baseIndex = index;
      case PlaybackLane.repeat:
        return;
    }
    final active = _current;
    if (active != null && active != move.entry) {
      if (_history.length == historyLimit) _history.removeAt(0);
      _history.add(active);
    }
    _current = move.entry;
  }

  PlaybackEntry? previous(
    LoopMode loop, {
    bool Function(PlaybackEntry)? isPlayable,
  }) {
    final active = _current;
    if (active == null || _forward.length == historyLimit) return null;
    bool canPlay(PlaybackEntry entry) => isPlayable?.call(entry) ?? true;
    final last = isPlayable == null
        ? _history.length - 1
        : _history.lastIndexWhere(canPlay);
    if (last >= 0) {
      _forward.add(active);
      return _current = _history.removeAt(last);
    }
    final index = _baseIndexBySlot[active.slot];
    if (index == null) return null;
    final count = loop == LoopMode.off ? index : _base.length;
    for (var step = 1; step <= count; step++) {
      final previous = (index - step) % _base.length;
      final entry = _base[previous];
      if (!canPlay(entry)) continue;
      if (_forward.isEmpty) {
        _baseIndex = previous;
      } else {
        _forward.add(active);
      }
      return _current = entry;
    }
    return null;
  }

  /// A failed insertion is neither history nor a candidate for repeat-one.
  bool discardFailedInsertion(PlaybackEntry entry) {
    if (_current != entry || !entry.inserted) return false;
    _history.removeWhere((candidate) => candidate == entry);
    _forward.removeWhere((candidate) => candidate == entry);
    if (_forward.isEmpty) _pendingAheadOfForward = 0;
    _current = _history.isEmpty ? _base[_baseIndex] : _history.removeLast();
    return true;
  }

  void toggleShuffle({Random? random}) {
    if (_base.isEmpty) return;
    final anchor = _base[_baseIndex];
    if (_unshuffled case final original?) {
      _base = original;
      _unshuffled = null;
      _unshuffledTracks = const [];
    } else {
      _unshuffled = List.of(_base);
      _unshuffledTracks = _baseTracks;
      _base.removeAt(_baseIndex);
      _base.shuffle(random);
      _base.insert(0, anchor);
    }
    _indexBase(anchor: anchor);
  }

  void reorderBase(Iterable<dynamic> trackIds) {
    if (_base.isEmpty) return;
    final rank = <dynamic, int>{};
    var index = 0;
    for (final id in trackIds) {
      rank[id] = index++;
    }
    final source = _unshuffled ?? _base;
    final slots = [
      for (var i = 0; i < source.length; i++)
        if (rank.containsKey(source[i].trackId)) i,
    ];
    // Stable ordering for duplicate IDs: sort their distinct existing slots.
    final sorted = List<int>.of(slots)
      ..sort((a, b) {
        final byRank = rank[source[a].trackId]!.compareTo(
          rank[source[b].trackId]!,
        );
        return byRank != 0 ? byRank : a.compareTo(b);
      });
    final reordered = List.of(source);
    for (var i = 0; i < slots.length; i++) {
      reordered[slots[i]] = source[sorted[i]];
    }
    if (shuffled) {
      _unshuffled = reordered;
      _unshuffledTracks = _tracks(reordered);
    } else {
      final anchor = _base[_baseIndex];
      _base = reordered;
      _indexBase(anchor: anchor);
    }
  }

  /// Keep the old base fields readable. Optional session fields reference base
  /// positions and store each insertion only once, even if in history.
  Map<String, Object?> snapshot() {
    final state = <String, Object?>{
      'playingQueue': _baseTracks,
      'playingIndex': _baseIndex,
      'isShuffled': shuffled,
      'unshuffledQueue': _unshuffledTracks,
    };
    final active = _current;
    if (active == null ||
        (_pending.isEmpty &&
            _history.isEmpty &&
            _forward.isEmpty &&
            active == _base[_baseIndex] &&
            !shuffled)) {
      return state;
    }
    final insertedTracks = <Map>[];
    final insertedRefs = <int, int>{};
    int reference(PlaybackEntry entry) => entry.inserted
        ? insertedRefs.putIfAbsent(entry.slot, () {
            insertedTracks.add(entry.track);
            return -insertedTracks.length;
          })
        : _baseIndexBySlot[entry.slot]!;
    state['queueSession'] = {
      'version': 1,
      'current': reference(active),
      'pending': _pending.map(reference).toList(),
      'history': _history.map(reference).toList(),
      'forward': _forward.map(reference).toList(),
      if (_pendingAheadOfForward > 0)
        'pendingAheadOfForward': _pendingAheadOfForward,
      'insertions': insertedTracks,
      if (_unshuffled case final original?)
        'unshuffledSlots': original.map(reference).toList(),
    };
    return state;
  }

  void restore(Map state) {
    final saved = state['playingQueue'];
    final index = state['playingIndex'];
    reset(saved is List ? saved : const [], index is int ? index : 0);
    if (_base.isEmpty) return;
    final extension = state['queueSession'];
    if (extension is Map && extension['version'] == 1) {
      final inserted = extension['insertions'];
      final entryTable = <PlaybackEntry?>[
        if (inserted is List)
          for (final track in inserted)
            _validTrack(track)
                ? PlaybackEntry._(++_lastSlot, track as Map, inserted: true)
                : null,
      ];
      PlaybackEntry? lookup(dynamic value) {
        if (value is! int) return null;
        if (value >= 0) return value < _base.length ? _base[value] : null;
        final index = -(value + 1);
        return index < entryTable.length ? entryTable[index] : null;
      }

      Iterable<PlaybackEntry> read(dynamic values) sync* {
        if (values is! List) return;
        for (final value in values) {
          if (lookup(value) case final entry?) yield entry;
        }
      }

      _current = lookup(extension['current']) ?? _current;
      _history.addAll(read(extension['history']).take(historyLimit));
      _forward.addAll(read(extension['forward']).take(historyLimit));
      final used = <int>{
        _current!.slot,
        for (final entry in _history) entry.slot,
        for (final entry in _forward) entry.slot,
      };
      final pending = extension['pending'];
      final ahead = extension['pendingAheadOfForward'];
      if (pending is List) {
        for (var i = 0; i < pending.length; i++) {
          final entry = lookup(pending[i]);
          if (entry == null || !entry.inserted || !used.add(entry.slot)) {
            continue;
          }
          _pending.add(entry);
          if (_forward.isNotEmpty && ahead is int && i < ahead) {
            _pendingAheadOfForward++;
          }
        }
      }
      if (state['isShuffled'] == true) {
        final original = read(extension['unshuffledSlots']).toList();
        if (original.length == _base.length &&
            original.every((entry) => !entry.inserted) &&
            original.toSet().length == _base.length) {
          _unshuffled = original;
        }
      }
    }
    if (state['isShuffled'] == true && _unshuffled == null) {
      _restoreLegacyShuffle(state['unshuffledQueue']);
    }
    if (_unshuffled case final original?) _unshuffledTracks = _tracks(original);
  }

  void _restoreLegacyShuffle(dynamic original) {
    if (original is! List || original.length != _base.length) return;
    final byId = <int, List<PlaybackEntry>>{};
    for (final entry in _base.reversed) {
      (byId[entry.trackId] ??= []).add(entry);
    }
    final ordered = <PlaybackEntry>[];
    for (final track in original) {
      if (!_validTrack(track)) return;
      final options = byId[(track as Map)['id']];
      if (options == null || options.isEmpty) return;
      ordered.add(options.removeLast());
    }
    _unshuffled = ordered;
  }

  void _indexBase({PlaybackEntry? anchor}) {
    _baseIndexBySlot = {
      for (var i = 0; i < _base.length; i++) _base[i].slot: i,
    };
    _baseTracks = _tracks(_base);
    if (anchor != null) _baseIndex = _baseIndexBySlot[anchor.slot]!;
  }

  static List<dynamic> _tracks(List<PlaybackEntry> entries) =>
      List<dynamic>.unmodifiable(entries.map((entry) => entry.track));

  static bool _validTrack(dynamic track) => track is Map && track['id'] is int;
}
