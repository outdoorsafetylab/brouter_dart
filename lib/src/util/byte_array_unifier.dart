// Port of btools.util.IByteArrayUnifier and ByteArrayUnifier
// (BRouter v1.7.10, MIT).
import 'dart:typed_data';

import 'crc32.dart';

/// Returns a byte array equal to `ab[offset, offset + len)`, reusing an
/// earlier instance when it can. Callers treat the result as immutable.
abstract interface class IByteArrayUnifier {
  Uint8List unify(Uint8List ab, int offset, int len);
}

class ByteArrayUnifier implements IByteArrayUnifier {
  final int _size;
  final List<Uint8List?> _cache;
  final Int32List? _crcCrosscheck;

  ByteArrayUnifier(int size, bool validateImmutability)
    : _size = size,
      _cache = List<Uint8List?>.filled(size, null),
      _crcCrosscheck = validateImmutability ? Int32List(size) : null;

  Uint8List unifyAll(Uint8List ab) => unify(ab, 0, ab.length);

  @override
  Uint8List unify(Uint8List ab, int offset, int len) {
    final crc = crc32(ab, offset, len);
    final idx = (crc & 0xfffffff) % _size;
    final abc = _cache[idx];
    if (abc != null && abc.length == len) {
      var i = 0;
      while (i < len) {
        if (ab[offset + i] != abc[i]) break;
        i++;
      }
      if (i == len) return abc;
    }
    final check = _crcCrosscheck;
    if (check != null) {
      final abold = _cache[idx];
      if (abold != null && crc32(abold, 0, abold.length) != check[idx]) {
        throw ArgumentError('ByteArrayUnifier: immutablity validation failed!');
      }
      check[idx] = crc;
    }
    final nab = Uint8List.fromList(ab.sublist(offset, offset + len));
    _cache[idx] = nab;
    return nab;
  }
}
