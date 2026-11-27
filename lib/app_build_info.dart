import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Populated once at startup, never blocks opening Settings.
String appBuildLabel = '';

Future<void> loadAppBuildInfo() async {
  try {
    final info = await PackageInfo.fromPlatform();
    appBuildLabel = info.version;
  } catch (error) {
    debugPrint('Package version unavailable: $error');
  }
}
