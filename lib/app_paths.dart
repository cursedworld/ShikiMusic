import 'dart:io';

import 'package:path_provider/path_provider.dart';

const String appDataDirectoryOverride = String.fromEnvironment(
  'SHIKI_DATA_DIR',
);

bool get hasAppDataDirectoryOverride =>
    appDataDirectoryOverride.trim().isNotEmpty;

Future<Directory> getDocumentsRootDirectory() =>
    getApplicationDocumentsDirectory();

Future<Directory> getShikiDataDirectory() async {
  final Directory directory;
  if (hasAppDataDirectoryOverride) {
    directory = Directory(appDataDirectoryOverride);
  } else {
    final documents = await getDocumentsRootDirectory();
    directory = Directory(
      '${documents.path}${Platform.pathSeparator}ShikiMusic',
    );
  }
  await directory.create(recursive: true);
  return directory;
}
