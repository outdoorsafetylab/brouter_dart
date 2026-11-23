// Not in BRouter: the check an app makes after downloading a set of
// segments, before the first route. BRouter makes the same check when the
// engine first opens each segment (PhysicalFile); doing it up front tells a
// broken or mismatched download apart from a route that cannot be found.
import 'dart:io';

import 'codec/data_buffers.dart';
import 'expressions/expressions.dart';
import 'mapaccess/physical_file.dart';

/// Checks that the rd5 segments in [dir] were built for the `lookups.dat`
/// in [dir], and that each one's header and top index read.
///
/// [segments] names the files to check; without it, every `.rd5` file in
/// [dir]. Returns how many were checked.
///
/// Throws a [FormatException] if `lookups.dat` has no lookup version, a
/// [DataFileException] (an [IOException]) for a segment of another lookup
/// version or with a bad header, and a [FileSystemException] for a file that
/// cannot be opened.
int verifyLookups(Directory dir, [Iterable<String>? segments]) {
  final meta = BExpressionMetaData()..readMetaData(File('${dir.path}/lookups.dat'));
  if (meta.lookupVersion < 0) {
    throw FormatException('${dir.path}/lookups.dat has no lookup version');
  }
  final names =
      segments?.toList() ??
      [
        for (final e in dir.listSync())
          if (e is File && e.path.endsWith('.rd5')) e.uri.pathSegments.last,
      ];
  final buffers = DataBuffers();
  for (final name in names) {
    PhysicalFile(File('${dir.path}/$name'), buffers, meta.lookupVersion, meta.lookupMinorVersion).close();
  }
  return names.length;
}
