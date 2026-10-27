import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiki/platform_capabilities.dart';

void main() {
  test(
    'vinyl rotation is never available on mobile, including wide layouts',
    () {
      for (final platform in TargetPlatform.values) {
        expect(
          vinylRotationSupportedOn(platform),
          [
            TargetPlatform.windows,
            TargetPlatform.linux,
            TargetPlatform.macOS,
          ].contains(platform),
          reason: platform.name,
        );
      }
    },
  );
}
