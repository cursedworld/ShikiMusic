import 'dart:async';

enum DownloadComponent { audio, video, cover, lyrics, library }

class TrackDownloadResult {
  TrackDownloadResult({
    required this.id,
    required this.title,
    required this.audioReady,
    required this.videoReady,
    this.videoUnavailable = false,
    Map<DownloadComponent, String> errors = const {},
  }) : errors = Map.unmodifiable(errors);

  final int id;
  final String title;
  final bool audioReady;
  final bool videoReady;
  final bool videoUnavailable;
  final Map<DownloadComponent, String> errors;

  bool get complete => audioReady && videoReady && errors.isEmpty;
  bool get needsRetry =>
      errors.isNotEmpty || !audioReady || (!videoReady && !videoUnavailable);
}

class DownloadBatchResult {
  DownloadBatchResult({required List<TrackDownloadResult> results})
    : results = List.unmodifiable(results);

  final List<TrackDownloadResult> results;

  int get audioReady => results.where((result) => result.audioReady).length;
  int get videoReady => results.where((result) => result.videoReady).length;
  int get videoUnavailable =>
      results.where((result) => result.videoUnavailable).length;
  int get complete => results.where((result) => result.complete).length;
  List<TrackDownloadResult> get retry =>
      results.where((result) => result.needsRetry).toList(growable: false);
  List<TrackDownloadResult> get incomplete =>
      results.where((result) => !result.complete).toList(growable: false);
}

/// Runs a fixed number of workers instead of allocating one pending task per
/// song. Every result is awaited before the batch is reported as finished.
Future<DownloadBatchResult> runDownloadBatch<T>({
  required Iterable<T> tracks,
  required int? Function(T track) trackId,
  required Future<TrackDownloadResult> Function(T track) download,
  String Function(T track)? title,
  int maxConcurrent = 2,
  bool Function()? isCancelled,
}) async {
  if (maxConcurrent < 1) {
    throw ArgumentError.value(
      maxConcurrent,
      'maxConcurrent',
      'must be positive',
    );
  }
  final seen = <int>{};
  final pending = <T>[];
  for (final track in tracks) {
    final id = trackId(track);
    if (id != null && seen.add(id)) pending.add(track);
  }
  final results = List<TrackDownloadResult?>.filled(pending.length, null);
  var next = 0;
  Future<void> worker() async {
    while (next < pending.length && !(isCancelled?.call() ?? false)) {
      final index = next++;
      try {
        results[index] = await download(pending[index]);
      } catch (error) {
        final id = trackId(pending[index])!;
        results[index] = TrackDownloadResult(
          id: id,
          title: title?.call(pending[index]) ?? '$id',
          audioReady: false,
          videoReady: false,
          errors: {DownloadComponent.library: error.toString()},
        );
      }
    }
  }

  await Future.wait(
    List.generate(
      pending.length < maxConcurrent ? pending.length : maxConcurrent,
      (_) => worker(),
    ),
  );
  return DownloadBatchResult(
    results: results.whereType<TrackDownloadResult>().toList(),
  );
}
