import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

final downloadedOnly = DownloadedOnlyMode();

bool downloadedOnlyFromSettings(Map<dynamic, dynamic> settings) =>
    settings['downloadedOnly'] == true;

/// An opt-in, local-only library. Use [client] for work done on behalf of the
/// Django catalog, including its media URLs. Discord is a separate connection.
final class DownloadedOnlyMode extends ValueNotifier<bool> {
  DownloadedOnlyMode() : super(false);

  int _revision = 0;
  final _requests = <Completer<void>>{};

  int get revision => _revision;

  bool permits(int revision) => !value && _revision == revision;

  @override
  set value(bool enabled) {
    if (enabled == value) return;
    _revision++;
    for (final request in _requests.toList()) {
      if (!request.isCompleted) request.complete();
    }
    _requests.clear();
    super.value = enabled;
  }

  /// The caller closes this client. An injected delegate stays caller-owned.
  http.Client client({http.Client? delegate}) => _CatalogClient(this, delegate);
}

final class _CatalogClient extends http.BaseClient {
  _CatalogClient(this._mode, http.Client? delegate)
    : _delegate = delegate,
      _ownsDelegate = delegate == null;

  final DownloadedOnlyMode _mode;
  final bool _ownsDelegate;
  http.Client? _delegate;
  bool _closed = false;
  final _requests = <Completer<void>>{};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw StateError('Catalog HTTP client closed');
    final revision = _mode.revision;
    if (!_mode.permits(revision)) {
      throw http.RequestAbortedException(request.url);
    }
    final abort = Completer<void>();
    _mode._requests.add(abort);
    _requests.add(abort);
    void finish() {
      _mode._requests.remove(abort);
      _requests.remove(abort);
    }

    void checkCurrent() {
      if (!_mode.permits(revision) || abort.isCompleted) {
        throw http.RequestAbortedException(request.url);
      }
    }

    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(
        abortTrigger.then((_) {
          if (!abort.isCompleted) abort.complete();
        }),
      );
    }
    try {
      final response = await Future.any([
        abort.future.then<http.StreamedResponse>((_) {
          finish();
          throw http.RequestAbortedException(request.url);
        }),
        (_delegate ??= http.Client()).send(
          _CatalogRequest(request, abort.future),
        ),
      ]);
      checkCurrent();
      Stream<List<int>> body() async* {
        try {
          checkCurrent();
          await for (final bytes in response.stream) {
            checkCurrent();
            yield bytes;
          }
          checkCurrent();
        } finally {
          finish();
        }
      }

      return http.StreamedResponse(
        body(),
        response.statusCode,
        contentLength: response.contentLength,
        headers: response.headers,
        request: request,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (_) {
      finish();
      rethrow;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final request in _requests) {
      if (!request.isCompleted) request.complete();
    }
    if (_ownsDelegate) _delegate?.close();
  }
}

// Keep the outgoing body streamed. IOClient consumes Abortable's trigger
// both while opening a request and while receiving its body.
// https://pub.dev/documentation/http/1.6.0/http/Abortable-class.html
final class _CatalogRequest extends http.BaseRequest with http.Abortable {
  _CatalogRequest(this.original, this.abortTrigger)
    : super(original.method, original.url) {
    headers.addAll(original.headers);
    contentLength = original.contentLength;
    followRedirects = original.followRedirects;
    maxRedirects = original.maxRedirects;
    persistentConnection = original.persistentConnection;
  }

  final http.BaseRequest original;
  @override
  final Future<void> abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return original.finalize();
  }
}
