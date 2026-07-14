const String defaultServerBaseUrl = 'http://192.168.31.13:8000';
const String benchmarkServerBaseUrl = 'http://127.0.0.1:65534';

const String serverBaseUrlSetting = String.fromEnvironment(
  'SHIKI_SERVER_URL',
  defaultValue: defaultServerBaseUrl,
);

final String configuredServerBaseUrl = normalizeServerBaseUrl(
  serverBaseUrlSetting,
);

final Uri configuredServerBaseUri = Uri.parse(configuredServerBaseUrl);

String normalizeServerBaseUrl(String? rawBaseUrl) =>
    normalizeServerBaseUri(rawBaseUrl).toString();

Uri normalizeServerBaseUri(String? rawBaseUrl) {
  final candidate = rawBaseUrl?.trim() ?? '';
  final parsed = _validServerBaseUri(candidate);
  if (parsed == null) {
    return Uri.parse(defaultServerBaseUrl);
  }

  final normalizedPath = parsed.path.replaceFirst(RegExp(r'/+$'), '');
  return Uri(
    scheme: parsed.scheme,
    userInfo: parsed.userInfo,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
    path: normalizedPath,
  );
}

Uri buildServerUriForBase(
  String? rawBaseUrl,
  String path, {
  Map<String, Object?>? queryParameters,
}) {
  final base = normalizeServerBaseUri(rawBaseUrl);
  final relativePath = path.trim().replaceFirst(RegExp(r'^/+'), '');
  final basePath = base.path.replaceFirst(RegExp(r'/+$'), '');
  final combinedPath = relativePath.isEmpty
      ? (basePath.isEmpty ? '/' : basePath)
      : '$basePath/$relativePath';

  return base.replace(
    path: combinedPath,
    queryParameters: _safeQueryParameters(queryParameters),
  );
}

Uri configuredServerUri(String path, {Map<String, Object?>? queryParameters}) =>
    buildServerUriForBase(
      configuredServerBaseUrl,
      path,
      queryParameters: queryParameters,
    );

String resolveMediaUrlForBase(String? rawBaseUrl, String mediaUrl) {
  final value = mediaUrl.trim();
  if (value.isEmpty) {
    return '';
  }

  final parsed = Uri.tryParse(value);
  if (parsed != null && parsed.isAbsolute) {
    return mediaUrl;
  }

  final base = normalizeServerBaseUri(rawBaseUrl);
  if (parsed == null) {
    final relativePath = value.replaceFirst(RegExp(r'^/+'), '');
    return buildServerUriForBase(base.toString(), relativePath).toString();
  }

  if (value.startsWith('/') || parsed.hasAuthority) {
    return base.resolveUri(parsed).toString();
  }

  final directoryBase = base.replace(path: '${base.path}/');
  return directoryBase.resolveUri(parsed).toString();
}

String resolveConfiguredMediaUrl(String mediaUrl) =>
    resolveMediaUrlForBase(configuredServerBaseUrl, mediaUrl);

Uri? _validServerBaseUri(String candidate) {
  if (candidate.isEmpty || candidate.contains(RegExp(r'\s'))) {
    return null;
  }

  final parsed = Uri.tryParse(candidate);
  if (parsed == null ||
      (parsed.scheme != 'http' && parsed.scheme != 'https') ||
      !parsed.hasAuthority ||
      parsed.host.isEmpty) {
    return null;
  }
  return parsed;
}

Map<String, dynamic>? _safeQueryParameters(
  Map<String, Object?>? queryParameters,
) {
  if (queryParameters == null || queryParameters.isEmpty) {
    return null;
  }

  final safe = <String, dynamic>{};
  for (final entry in queryParameters.entries) {
    final value = entry.value;
    if (value == null) {
      continue;
    }
    if (value is Iterable<Object?>) {
      final values = value
          .where((item) => item != null)
          .map((item) => item.toString())
          .toList(growable: false);
      if (values.isNotEmpty) {
        safe[entry.key] = values;
      }
      continue;
    }
    safe[entry.key] = value.toString();
  }
  return safe.isEmpty ? null : safe;
}
