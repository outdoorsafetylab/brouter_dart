// Port of btools.mapaccess.StorageConfigHelper (BRouter v1.7.10, MIT).
import 'dart:io';

/// Reads storageconfig.txt in the segment directory.
abstract final class StorageConfigHelper {
  static Directory? getSecondarySegmentDir(Directory segmentDir) =>
      _getStorageLocation(segmentDir, 'secondary_segment_dir=');

  static Directory? getAdditionalMaptoolDir(Directory segmentDir) =>
      _getStorageLocation(segmentDir, 'additional_maptool_dir=');

  static Directory? _getStorageLocation(Directory segmentDir, String tag) {
    Directory? res;
    final configFile = File('${segmentDir.path}/storageconfig.txt');
    try {
      for (var line in configFile.readAsLinesSync()) {
        line = line.trim();
        if (line.startsWith('#')) continue;
        if (line.startsWith(tag)) {
          final path = line.substring(tag.length).trim();
          res = path.startsWith('/') ? Directory(path) : Directory('${segmentDir.path}/$path');
          // Java's File.exists: a file or a directory
          if (FileSystemEntity.typeSync(res.path) == FileSystemEntityType.notFound) res = null;
          break;
        }
      }
    } on Exception {
      // ignore, as Java does
    }
    return res;
  }
}
