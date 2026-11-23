// Port of btools.util.Crc32 (BRouter v1.7.10, MIT).
import 'dart:typed_data';

import 'int32.dart';

/// The checksum of rd5 indexes and micro-caches, as a signed 32-bit int.
int crc32(Uint8List ab, int offset, int len) {
  var crc = 0xFFFFFFFF;
  final end = offset + len;
  for (var j = offset; j < end; j++) {
    crc = (crc >> 8) ^ _table[(crc ^ ab[j]) & 0xff];
  }
  return i32(crc);
}

final _table = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();
