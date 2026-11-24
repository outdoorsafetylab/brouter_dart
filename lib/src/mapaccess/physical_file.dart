// Port of btools.mapaccess.PhysicalFile (BRouter v1.7.10, MIT), without the
// command-line main.
import 'dart:io';
import 'dart:typed_data';

import '../codec/data_buffers.dart';
import '../util/byte_data.dart';
import '../util/crc32.dart';
import '../util/int32.dart';
import 'data_file_exception.dart';
import 'osm_file.dart';

/// An open rd5 file: 5 × 5 one-degree squares and their indexes.
class PhysicalFile {
  RandomAccessFile? ra;
  final Int64List fileIndex = Int64List(25);
  Int32List? fileHeaderCrcs;

  int creationTime = 0;

  String fileName;

  int divisor = 80;
  int elevationType = 3; // Java byte

  /// The lookup version in the file header, or -1 if it cannot be read.
  static int checkVersionIntegrity(File f) {
    var version = -1;
    RandomAccessFile? raf;
    try {
      final iobuffer = Uint8List(200);
      raf = f.openSync();
      readFully(raf, iobuffer, 200);
      final dis = ByteDataReader(iobuffer);
      final lv = dis.readLong();
      version = i32(lv >> 48);
    } on IOException {
      // as in Java: version stays -1
    } finally {
      raf?.closeSync();
    }
    return version;
  }

  /// Checks the checksum of every index and micro-cache of [f] without
  /// decoding (Java passes MicroCache.debug, false outside its main); throws
  /// on the first error. Returns null, as the Java version does.
  static String? checkFileIntegrity(File f) {
    PhysicalFile? pf;
    try {
      final dataBuffers = DataBuffers();
      pf = PhysicalFile(f, dataBuffers, -1, -1);
      final div = pf.divisor;
      for (var lonDegree = 0; lonDegree < 5; lonDegree++) {
        // doesn't really matter..
        for (var latDegree = 0; latDegree < 5; latDegree++) {
          // ..where on earth we are
          final osmf = OsmFile(pf, lonDegree, latDegree, dataBuffers);
          if (osmf.hasData()) {
            for (var lonIdx = 0; lonIdx < div; lonIdx++) {
              for (var latIdx = 0; latIdx < div; latIdx++) {
                osmf.createMicroCacheAt(
                  lonDegree * div + lonIdx,
                  latDegree * div + latIdx,
                  dataBuffers,
                  null,
                  null,
                  false,
                  null,
                );
              }
            }
          }
        }
      }
    } finally {
      pf?.close();
    }
    return null;
  }

  PhysicalFile(File f, DataBuffers dataBuffers, int lookupVersion, int lookupMinorVersion)
    : fileName = f.uri.pathSegments.last {
    final ra = this.ra = f.openSync();
    // Java leaves the file open when the header does not read; here it is
    // closed before the error goes on, or every failed check would keep one
    // file open.
    try {
      _readHeader(ra, dataBuffers, lookupVersion);
    } catch (_) {
      close();
      rethrow;
    }
  }

  void _readHeader(RandomAccessFile ra, DataBuffers dataBuffers, int lookupVersion) {
    final iobuffer = dataBuffers.iobuffer;
    readFully(ra, iobuffer, 200);
    final fileIndexCrc = crc32(iobuffer, 0, 200);
    var dis = ByteDataReader(iobuffer);
    for (var i = 0; i < 25; i++) {
      final lv = dis.readLong();
      final readVersion = i16(lv >> 48);
      if (i == 0 && lookupVersion != -1 && readVersion != lookupVersion) {
        throw DataFileException('lookup version mismatch (old rd5?) lookups.dat=$lookupVersion $fileName=$readVersion');
      }
      fileIndex[i] = lv & 0xffffffffffff;
    }
    // Each one-degree square ends where the next starts, the first after this
    // 200-byte index; the end of the last is checked against the file length
    // below. BRouter does not check this.
    if (fileIndex[0] < 200) {
      throw DataFileException('file index starts inside the header');
    }
    for (var i = 1; i < 25; i++) {
      if (fileIndex[i] < fileIndex[i - 1]) {
        throw DataFileException('file index out of order');
      }
    }

    // read some extra info from the end of the file, if present
    final len = ra.lengthSync();

    final pos = fileIndex[24];
    var extraLen = 8 + 26 * 4;

    if (len == pos) return; // old format o.k.

    if ((len - pos) > extraLen) {
      extraLen++;
    }

    if (len < pos + extraLen) {
      // > is o.k. for future extensions!
      throw DataFileException('file of size $len too short, should be ${pos + extraLen}');
    }

    ra.setPositionSync(pos);
    readFully(ra, iobuffer, extraLen);
    dis = ByteDataReader(iobuffer);
    creationTime = dis.readLong();

    final crcData = dis.readInt();
    if (crcData == fileIndexCrc) {
      divisor = 80; // old format
    } else if ((crcData ^ 2) == fileIndexCrc) {
      divisor = 32; // new format
    } else {
      throw DataFileException('top index checksum error');
    }
    final crcs = fileHeaderCrcs = Int32List(25);
    for (var i = 0; i < 25; i++) {
      crcs[i] = dis.readInt();
    }
    // Java reads this byte inside a try. Without the extra byte it reads
    // whatever the io buffer held there before; only a buffer too short for
    // it keeps the default.
    try {
      elevationType = dis.readByte();
    } on RangeError {
      // keep the default
    }
  }

  void close() {
    try {
      ra?.closeSync();
    } on IOException {
      // ignore, as Java does
    }
  }

  /// Java's RandomAccessFile.readFully: reads [len] bytes into the start of
  /// [buffer] or throws at end of file.
  static void readFully(RandomAccessFile ra, Uint8List buffer, int len) {
    var off = 0;
    while (off < len) {
      final n = ra.readIntoSync(buffer, off, len);
      if (n <= 0) throw DataFileException('unexpected end of file');
      off += n;
    }
  }
}
