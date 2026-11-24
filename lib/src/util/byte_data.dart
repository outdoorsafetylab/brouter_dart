// Port of btools.util.ByteDataReader and ByteDataWriter (BRouter v1.7.10, MIT).
import 'dart:typed_data';

import 'int32.dart';

/// Fast reading from a byte array. Java's `byte[]` is a [Uint8List] here;
/// methods that return a Java `byte` or `short` return it sign-extended.
class ByteDataReader {
  Uint8List? ab;
  int aboffset = 0;
  int aboffsetEnd = 0;

  ByteDataReader(Uint8List? byteArray, [int offset = 0]) {
    ab = byteArray;
    aboffset = offset;
    aboffsetEnd = byteArray == null ? 0 : byteArray.length;
  }

  void reset(Uint8List? byteArray) {
    ab = byteArray;
    aboffset = 0;
    aboffsetEnd = byteArray == null ? 0 : byteArray.length;
  }

  int readInt() {
    final a = ab!;
    final v = (a[aboffset] << 24) | (a[aboffset + 1] << 16) | (a[aboffset + 2] << 8) | a[aboffset + 3];
    aboffset += 4;
    return i32(v);
  }

  int readLong() {
    final a = ab!;
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | a[aboffset++];
    }
    return v; // Dart's int is Java's long, two's complement 64-bit
  }

  bool readBoolean() => ab![aboffset++] != 0;

  int readByte() => i8(ab![aboffset++]);

  int readShort() {
    final a = ab!;
    final v = (a[aboffset] << 8) | a[aboffset + 1];
    aboffset += 2;
    return i16(v);
  }

  /// Reads a size and returns the offset just past a section of that size.
  int getEndPointer() {
    final size = readVarLengthUnsigned();
    return aboffset + size;
  }

  Uint8List? readDataUntil(int endPointer) {
    final size = endPointer - aboffset;
    if (size == 0) return null;
    final data = Uint8List(size);
    readFully(data);
    return data;
  }

  Uint8List? readVarBytes() {
    final len = readVarLengthUnsigned();
    if (len == 0) return null;
    final bytes = Uint8List(len);
    readFully(bytes);
    return bytes;
  }

  int readVarLengthSigned() {
    final v = readVarLengthUnsigned();
    return (v & 1) == 0 ? sar(v, 1) : i32(-sar(v, 1));
  }

  int readVarLengthUnsigned() {
    final a = ab!;
    var b = a[aboffset++];
    var v = b & 0x7f;
    if (b < 0x80) return v;
    b = a[aboffset++];
    v |= (b & 0x7f) << 7;
    if (b < 0x80) return v;
    b = a[aboffset++];
    v |= (b & 0x7f) << 14;
    if (b < 0x80) return v;
    b = a[aboffset++];
    v |= (b & 0x7f) << 21;
    if (b < 0x80) return v;
    b = a[aboffset++];
    v |= (b & 0xf) << 28;
    return i32(v);
  }

  void readFully(Uint8List ta) {
    ta.setRange(0, ta.length, ab!, aboffset);
    aboffset += ta.length;
  }

  bool hasMoreData() => aboffset < aboffsetEnd;
}

/// Fast writing to a byte array.
class ByteDataWriter extends ByteDataReader {
  ByteDataWriter(super.byteArray);

  void writeInt(int v) {
    final a = ab!;
    a[aboffset++] = (v >> 24) & 0xff;
    a[aboffset++] = (v >> 16) & 0xff;
    a[aboffset++] = (v >> 8) & 0xff;
    a[aboffset++] = v & 0xff;
  }

  void writeLong(int v) {
    final a = ab!;
    for (var s = 56; s >= 0; s -= 8) {
      a[aboffset++] = (v >> s) & 0xff;
    }
  }

  void writeBoolean(bool v) => ab![aboffset++] = v ? 1 : 0;

  void writeByte(int v) => ab![aboffset++] = v & 0xff;

  void writeShort(int v) {
    final a = ab!;
    a[aboffset++] = (v >> 8) & 0xff;
    a[aboffset++] = v & 0xff;
  }

  void write(Uint8List sa, [int offset = 0, int? len]) {
    final n = len ?? sa.length;
    ab!.setRange(aboffset, aboffset + n, sa, offset);
    aboffset += n;
  }

  void writeVarBytes(Uint8List? sa) {
    if (sa == null) {
      writeVarLengthUnsigned(0);
    } else {
      writeVarLengthUnsigned(sa.length);
      write(sa, 0, sa.length);
    }
  }

  void writeModeAndDesc(bool isReverse, Uint8List? sa) {
    final len = sa == null ? 0 : sa.length;
    writeVarLengthUnsigned((len << 1) | (isReverse ? 1 : 0));
    if (len > 0) write(sa!, 0, len);
  }

  Uint8List toByteArray() => Uint8List.fromList(ab!.sublist(0, aboffset));

  /// Reserves one byte for a size written later by [injectSize].
  int writeSizePlaceHolder() => aboffset++;

  void injectSize(int sizeoffset) {
    var size = 0;
    final datasize = aboffset - sizeoffset - 1;
    var v = datasize;
    do {
      v = sar(v, 7);
      size++;
    } while (v != 0);
    if (size > 1) {
      final a = ab!;
      a.setRange(sizeoffset + size, sizeoffset + size + datasize, Uint8List.fromList(a.sublist(sizeoffset + 1, sizeoffset + 1 + datasize)));
    }
    aboffset = sizeoffset;
    writeVarLengthUnsigned(datasize);
    aboffset = sizeoffset + size + datasize;
  }

  void writeVarLengthSigned(int v) {
    writeVarLengthUnsigned(v < 0 ? shl(-v, 1) | 1 : shl(v, 1));
  }

  void writeVarLengthUnsigned(int v) {
    final a = ab!;
    v &= 0xffffffff; // Java's >>> treats the int as unsigned
    for (var i = 0; i < 4; i++) {
      final i7 = v & 0x7f;
      v >>= 7;
      if (v == 0) {
        a[aboffset++] = i7;
        return;
      }
      a[aboffset++] = i7 | 0x80;
    }
    a[aboffset++] = v & 0xff;
  }

  int size() => aboffset;
}
