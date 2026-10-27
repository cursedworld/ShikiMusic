import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shiki/app_build_info.dart';

void main() {
  test(
    'settings version comes from actual package, including build number',
    () async {
      PackageInfo.setMockInitialValues(
        appName: 'ShikiMusic',
        packageName: 'com.example.music_player',
        version: '4.2.3',
        buildNumber: '108',
        buildSignature: '',
      );
      final previous = appBuildLabel;
      addTearDown(() => appBuildLabel = previous);
      await loadAppBuildInfo();
      expect(appBuildLabel, '4.2.3 (108)');
    },
  );
}
