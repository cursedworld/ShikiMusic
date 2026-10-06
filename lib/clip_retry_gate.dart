/// Missing/failed clips must not restart internet searches on every focus event.
class ClipRetryGate {
  ClipRetryGate({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Map<int, ({String signature, DateTime until})> _failures = {};

  bool canRequest(int id, String signature, {bool force = false}) {
    final failure = _failures[id];
    if (force ||
        failure == null ||
        failure.signature != signature ||
        !failure.until.isAfter(_now())) {
      _failures.remove(id);
      return true;
    }
    return false;
  }

  void recordFailure(int id, String signature, Duration delay) {
    if (_failures.length >= 512 && !_failures.containsKey(id)) {
      _failures.remove(_failures.keys.first);
    }
    _failures[id] = (signature: signature, until: _now().add(delay));
  }

  void clear(int id) => _failures.remove(id);
}
