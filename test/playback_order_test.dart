import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/globals.dart' show LoopMode;
import 'package:shiki/playback_order.dart';

Map<String, Object> _track(int id) => {'id': id, 'title': 'Track $id'};

int? _next(
  PlaybackOrder order, {
  LoopMode loop = LoopMode.off,
  bool automatic = true,
  int? starting,
}) {
  final move = order.next(
    loop,
    automatic: automatic,
    alreadyStarting: starting,
  );
  if (move != null) order.take(move);
  return move?.entry.trackId;
}

void main() {
  test(
    'deleting an owned track drops every occurrence, not the other slots',
    () {
      final order = PlaybackOrder()
        ..reset([_track(-1), _track(2), _track(3)], 0);
      order.insertNext([_track(-1), _track(4), _track(-1)]);
      expect(_next(order), -1);
      expect(order.removeTracks((track) => track['id'] == -1), isTrue);
      expect(order.current?.trackId, 2);
      expect(order.baseTracks.map((track) => track['id']), [2, 3]);
      expect(order.insertions.map((entry) => entry.trackId), [4]);
      expect(order.previous(LoopMode.off), isNull);
      final restored = PlaybackOrder()
        ..restore(jsonDecode(jsonEncode(order.snapshot())) as Map);
      expect([_next(restored), _next(restored), _next(restored)], [4, 3, null]);
    },
  );

  test('current insertion survives deletion of the base anchor', () {
    final order = PlaybackOrder()..reset([_track(-1), _track(2)], 0);
    order.insertNext([_track(3), _track(4)]);
    expect(_next(order), 3);
    expect(order.removeTracks((track) => track['id'] == -1), isTrue);
    expect(order.current?.trackId, 3);
    expect([_next(order), _next(order)], [4, 2]);
  });

  test(
    'deleting the sole base track retains a playing insertion and upcoming slots',
    () {
      final order = PlaybackOrder()..reset([_track(-1)], 0);
      order.insertNext([_track(3), _track(4)]);
      expect(_next(order), 3);
      order.removeTracks((track) => track['id'] == -1);
      expect(order.current?.trackId, 3);
      expect(order.baseTracks.map((track) => track['id']), [3]);
      expect([_next(order), _next(order)], [4, null]);
    },
  );

  test(
    'deleting a revisited current track resumes redo without duplicating the anchor',
    () {
      final order = PlaybackOrder()
        ..reset([_track(-1), _track(2), _track(3)], 0);
      expect([_next(order), _next(order)], [2, 3]);
      expect(order.previous(LoopMode.off)?.trackId, 2);
      expect(order.previous(LoopMode.off)?.trackId, -1);
      order.removeTracks((track) => track['id'] == -1);
      expect(order.current?.trackId, 2);
      expect([_next(order), _next(order)], [3, null]);
    },
  );

  test('a batch plays in visible order, then resumes the untouched base', () {
    final base = [_track(1), _track(2), _track(3)];
    final order = PlaybackOrder()..reset(base, 0);
    expect(order.insertNext([_track(4), _track(5)]), 2);
    expect(order.current?.track, same(base.first));
    expect(order.baseIndex, 0);
    expect([for (var i = 0; i < 4; i++) _next(order)], [4, 5, 2, 3]);
    expect(order.insertionCount, 0);
    expect(order.baseTracks, base);
    expect(_next(order), isNull);
  });

  test('later groups go first; duplicate track IDs have independent slots', () {
    final track = _track(2);
    final order = PlaybackOrder()..reset([_track(1), track, track], 0);
    order.insertNext([track, _track(3)]);
    order.insertNext([track, _track(4)]);
    final entries = order.insertions.toList();
    expect(entries.map((entry) => entry.trackId), [2, 4, 2, 3]);
    expect(entries[0].slot, isNot(entries[2].slot));
    expect(order.removeInsertion(entries[2].slot), isTrue);
    expect([for (var i = 0; i < 5; i++) _next(order)], [2, 4, 3, 2, 2]);
    expect(order.baseTracks.length, 3);
  });

  test(
    'repeat-one defers insertions until manual Next; repeat-list does not replay them',
    () {
      final order = PlaybackOrder()..reset([_track(1), _track(2)], 0);
      order.insertNext([_track(4)]);
      expect(_next(order, loop: LoopMode.one), 1);
      expect(order.insertionCount, 1);
      expect(_next(order, loop: LoopMode.one, automatic: false), 4);
      expect(_next(order, loop: LoopMode.one), 4);
      expect(_next(order, loop: LoopMode.list), 2);
      expect(_next(order, loop: LoopMode.list), 1);
      expect(_next(order, loop: LoopMode.list), 2);
    },
  );

  test(
    'Previous rewinds actual visits; Next plays new insertions then retraces',
    () {
      final order = PlaybackOrder()
        ..reset([_track(1), _track(2), _track(3)], 0);
      order.insertNext([_track(4), _track(5)]);
      expect([_next(order), _next(order), _next(order)], [4, 5, 2]);
      expect(order.previous(LoopMode.off)?.trackId, 5);
      expect(order.previous(LoopMode.off)?.trackId, 4);
      expect(order.insertionCount, 0);
      order.insertNext([_track(6)]);
      expect([for (var i = 0; i < 4; i++) _next(order)], [6, 5, 2, 3]);
      expect(order.previous(LoopMode.off)?.trackId, 2);
      expect(order.previous(LoopMode.off)?.trackId, 5);
      expect(order.previous(LoopMode.off)?.trackId, 6);
      expect(order.previous(LoopMode.off)?.trackId, 4);
    },
  );

  test(
    'legacy Previous before the first actual visit uses the preceding base slot',
    () {
      final order = PlaybackOrder()
        ..reset([_track(1), _track(2), _track(3)], 2);
      expect(order.previous(LoopMode.off)?.trackId, 2);
      expect(_next(order), 3);
      expect(order.previous(LoopMode.off)?.trackId, 2);
    },
  );

  test('old pending tracks wait behind redo, including after a restart', () {
    final order = PlaybackOrder()..reset([_track(1), _track(2), _track(3)], 0);
    order.insertNext([_track(4), _track(5)]);
    expect(_next(order), 4);
    expect(order.previous(LoopMode.off)!.trackId, 1);
    order.insertNext([_track(6), _track(7)]);
    final restored = PlaybackOrder()
      ..restore(jsonDecode(jsonEncode(order.snapshot())) as Map);
    expect([for (var i = 0; i < 6; i++) _next(restored)], [6, 7, 4, 5, 2, 3]);
  });

  test(
    'audible base track stays first; manual Next still overrides overlap',
    () {
      final order = PlaybackOrder()
        ..reset([_track(1), _track(2), _track(3)], 0);
      final reserved = order.next(LoopMode.off, automatic: true)!.entry;
      order.insertNext([_track(4), _track(5)], alreadyStarting: reserved.slot);
      expect(
        order
            .next(
              LoopMode.off,
              automatic: false,
              alreadyStarting: reserved.slot,
            )
            ?.entry
            .trackId,
        4,
      );
      expect(_next(order, starting: reserved.slot), 2);
      expect([_next(order), _next(order), _next(order)], [4, 5, 3]);
    },
  );

  test(
    'audible insertion cannot be cleared and new batches go right after it',
    () {
      final order = PlaybackOrder()..reset([_track(1), _track(2)], 0);
      order.insertNext([_track(4), _track(5)]);
      final pin = order.insertions.first.slot;
      order.insertNext([_track(6), _track(7)], alreadyStarting: pin);
      expect(order.insertions.map((entry) => entry.trackId), [4, 6, 7, 5]);
      expect(order.removeInsertion(pin, alreadyStarting: pin), isFalse);
      expect(order.clearInsertions(alreadyStarting: pin), isTrue);
      expect(order.insertions.single.slot, pin);
      expect([_next(order, starting: pin), _next(order)], [4, 2]);
    },
  );

  test('reorder and shuffle keep the actual anchor among duplicate IDs', () {
    final first = _track(1);
    final second = _track(1);
    final order = PlaybackOrder()
      ..reset([first, _track(3), second, _track(2)], 2);
    final slot = order.current?.slot;
    order.insertNext([_track(4), _track(5)]);
    expect(_next(order), 4);
    final active = order.current;
    order.toggleShuffle(random: Random(16));
    expect(order.baseTracks.first, same(second));
    order.reorderBase([2, 1, 3]);
    expect(order.baseTracks.first, same(second));
    order.toggleShuffle();
    expect(order.current, same(active));
    expect(order.baseIndex, 2);
    expect(order.baseTracks[2], same(second));
    expect(order.previous(LoopMode.off)?.slot, slot);
    expect(order.insertions.single.trackId, 5);
    expect([_next(order), _next(order), _next(order)], [4, 5, 3]);
  });

  test('a failed insertion disappears from repeat and history', () {
    final order = PlaybackOrder()..reset([_track(1), _track(2)], 0);
    order.insertNext([_track(4), _track(5)]);
    expect(_next(order), 4);
    expect(order.discardFailedInsertion(order.current!), isTrue);
    expect(order.current?.trackId, 1);
    expect([_next(order), _next(order)], [5, 2]);
    expect(order.previous(LoopMode.off)?.trackId, 5);
    expect(order.previous(LoopMode.off)?.trackId, 1);
    expect(order.discardFailedInsertion(order.current!), isFalse);
  });

  test(
    'snapshot restores current insertion, duplicate refs and forward history once',
    () {
      final order = PlaybackOrder()
        ..reset([_track(1), _track(2), _track(3)], 0);
      final sameRecording = _track(8);
      order.insertNext([sameRecording, sameRecording]);
      expect([_next(order), _next(order), _next(order)], [8, 8, 2]);
      expect(order.previous(LoopMode.off)?.trackId, 8);
      order.insertNext([_track(9)]);
      final disk = jsonDecode(jsonEncode(order.snapshot())) as Map;
      final restored = PlaybackOrder()..restore(disk);
      expect(restored.baseIndex, 1);
      expect(restored.current?.inserted, isTrue);
      expect(restored.current?.trackId, 8);
      final restoredSlot = restored.current?.slot;
      expect(restored.previous(LoopMode.off)?.trackId, 8);
      expect(restored.current?.slot, isNot(restoredSlot));
      expect([for (var i = 0; i < 4; i++) _next(restored)], [9, 8, 2, 3]);
    },
  );

  test(
    'old JSON and invalid extended references fall back to the saved base',
    () {
      final order = PlaybackOrder()
        ..restore({
          'playingQueue': [_track(2), _track(1), _track(3)],
          'playingIndex': 0,
          'isShuffled': true,
          'unshuffledQueue': [_track(1), _track(2), _track(3)],
          'queueSession': {
            'version': 1,
            'current': -3,
            'pending': [1, -50],
          },
        });
      expect(order.current?.trackId, 2);
      expect(order.insertionCount, 0);
      order.toggleShuffle();
      expect(order.baseIndex, 1);
      expect(_next(order), 3);
    },
  );

  test('starting a fresh list clears insertions and navigation history', () {
    final order = PlaybackOrder();
    expect(order.insertNext([_track(7)]), 0);
    order.reset([_track(1), _track(2)], 0);
    order.insertNext([_track(7), _track(8)]);
    _next(order);
    order.reset([_track(3), _track(4)], 0);
    expect(order.insertionCount, 0);
    expect(order.previous(LoopMode.off), isNull);
    expect(order.snapshot().containsKey('queueSession'), isFalse);
    expect(_next(order), 4);
  });

  test(
    'history snapshots bound repeated transitions without mutating the base',
    () {
      final order = PlaybackOrder()..reset([_track(1), _track(2)], 0);
      for (var i = 0; i < 200; i++) {
        _next(order, loop: LoopMode.list);
      }
      final snapshot = order.snapshot()['queueSession'] as Map;
      expect(snapshot['history'], hasLength(PlaybackOrder.historyLimit));
      expect(snapshot['insertions'], isEmpty);
      expect(order.baseTracks, hasLength(2));
    },
  );
}
