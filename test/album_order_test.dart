import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/album_order.dart';

void main() {
  test(
    'album order respects disc/track and preserves unknown insertion order',
    () {
      final tracks = [
        {'id': 1},
        {'id': 2, 'disc_number': 2, 'track_number': 1},
        {'id': 3, 'track_number': 2},
        {'id': 4, 'track_number': 1},
        {'id': 5},
      ];
      expect(albumTrackOrder(tracks).map((t) => t['id']), [4, 3, 2, 1, 5]);
      expect(tracks.map((t) => t['id']), [1, 2, 3, 4, 5]);
    },
  );
}
