// The checksums of an rd5 file: PhysicalFile.checkFileIntegrity checks
// every micro-cache without decoding it. Decoding a cache to its end skips
// the check, so the golden comparison alone never exercises it.
import 'dart:io';
import 'dart:typed_data';

import 'package:brouter/src/mapaccess/data_file_exception.dart';
import 'package:brouter/src/mapaccess/physical_file.dart';
import 'package:brouter/src/util/byte_data.dart';
import 'package:test/test.dart';

import 'golden.dart';

void main() {
  for (final tile in ['E120_N20', 'E120_N25']) {
    test('$tile passes the integrity check', () {
      final f = goldenInput('$tile.rd5');
      expect(PhysicalFile.checkFileIntegrity(f), isNull);
      expect(PhysicalFile.checkVersionIntegrity(f), greaterThan(0));
    });
  }

  test('a flipped byte inside a micro-cache fails the integrity check', () {
    final bytes = goldenInput('E120_N25.rd5').readAsBytesSync();
    // The first square's index starts at 200; its first cache follows the
    // 32 × 32 four-byte end offsets.
    final r = ByteDataReader(bytes, 200);
    var start = 200 + 32 * 32 * 4;
    for (var i = 0; i < 32 * 32; i++) {
      final end = 200 + r.readInt();
      if (end - start > 8) break;
      start = end;
    }
    final dir = Directory.systemTemp.createTempSync('brouter_integrity');
    addTearDown(() => dir.deleteSync(recursive: true));
    final broken = Uint8List.fromList(bytes);
    broken[start + 2] ^= 0x10;
    final f = File('${dir.path}/E120_N25.rd5')..writeAsBytesSync(broken);
    expect(
      () => PhysicalFile.checkFileIntegrity(f),
      throwsA(isA<DataFileException>().having((e) => e.message, 'message', 'checkum error')),
    );
  });
}
