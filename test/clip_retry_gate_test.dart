import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/clip_retry_gate.dart';

void main() {
  test(
    'focus retries wait, expire, and metadata changes bypass old failures',
    () {
      var now = DateTime(2026);
      final gate = ClipRetryGate(now: () => now);
      gate.recordFailure(1, 'old', const Duration(minutes: 15));
      expect(gate.canRequest(1, 'old'), isFalse);
      now = now.add(const Duration(minutes: 15));
      expect(gate.canRequest(1, 'old'), isTrue);
      gate.recordFailure(1, 'old', const Duration(hours: 6));
      expect(gate.canRequest(1, 'new'), isTrue);
    },
  );

  test('explicit retry and successful media unblock a failed track', () {
    final gate = ClipRetryGate();
    gate.recordFailure(1, 'same', const Duration(hours: 6));
    expect(gate.canRequest(1, 'same', force: true), isTrue);
    gate.recordFailure(1, 'same', const Duration(hours: 6));
    gate.clear(1);
    expect(gate.canRequest(1, 'same'), isTrue);
  });
}
