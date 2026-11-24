// Sizes, counts and offsets read from an rd5 file that no valid file has:
// each is rejected with DataFileException (or, inside the codec,
// FormatException) before it is used. Valid files never reach these checks;
// the golden comparison shows that.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:brouter/src/codec/data_buffers.dart';
import 'package:brouter/src/codec/micro_cache.dart';
import 'package:brouter/src/codec/stat_coder_context.dart';
import 'package:brouter/src/codec/tag_value_coder.dart';
import 'package:brouter/src/expressions/expressions.dart';
import 'package:brouter/src/mapaccess/data_file_exception.dart';
import 'package:brouter/src/mapaccess/direct_weaver.dart';
import 'package:brouter/src/mapaccess/osm_file.dart';
import 'package:brouter/src/mapaccess/osm_nodes_map.dart';
import 'package:brouter/src/mapaccess/physical_file.dart';
import 'package:brouter/src/util/bit_coder_context.dart';
import 'package:brouter/src/util/crc32.dart';
import 'package:test/test.dart';

import 'golden.dart';

const _divisor = 32; // the golden segments are in the new format

/// The start of a micro-cache: two empty tag trees, five noisy-bit counts of
/// 0, the node count, no node ids (for 0 nodes) and the decoded data size.
Uint8List _microCacheHead({required int nodes, int dataSize = 0}) {
  final ab = Uint8List(64);
  final bc = BitCoderContext(ab);
  for (var tree = 0; tree < 2; tree++) {
    bc.encodeBit(false); // leaf
    bc.encodeVarBits(0); // empty
  }
  for (var i = 0; i < 5; i++) {
    bc.encodeVarBits(0);
  }
  bc.encodeBounded(31, nodes & 31);
  bc.encodeVarBits((nodes & 0xffffffff) >> 5);
  bc.encodeBounded(1023, dataSize & 1023);
  bc.encodeVarBits((dataSize & 0xffffffff) >> 10);
  bc.closeAndGetEncodedLength();
  return ab;
}

/// A tag tree that is a chain of [innerNodes] inner nodes, each with an
/// empty leaf on one side.
Uint8List _tagChain(int innerNodes) {
  final ab = Uint8List(256);
  final bc = BitCoderContext(ab);
  for (var i = 0; i < innerNodes; i++) {
    bc.encodeBit(true); // inner node
    bc.encodeBit(false); // leaf
    bc.encodeVarBits(0); // empty
  }
  bc.encodeBit(false);
  bc.encodeVarBits(0);
  bc.closeAndGetEncodedLength();
  return ab;
}

/// The start of a micro-cache of one node with one link whose target index
/// is 0 + [diff], up to that index. Valid links are covered by the golden
/// comparison.
Uint8List _oneNodeOneLink(int diff) {
  final ab = Uint8List(64);
  final bc = BitCoderContext(ab);
  for (var tree = 0; tree < 2; tree++) {
    bc.encodeBit(false);
    bc.encodeVarBits(0);
  }
  for (var i = 0; i < 5; i++) {
    bc.encodeVarBits(0);
  }
  bc.encodeBounded(31, 1); // one node
  bc.encodeVarBits(0);
  bc.encodeBounded((1 << 30) - 1, 0); // its id
  bc.encodeBounded(1023, 0); // no decoded data
  bc.encodeVarBits(0);
  bc.encodeVarBits(0); // no features
  bc.encodeVarBits(0); // elevation
  bc.encodeBounded(1, 1); // one link
  bc.encodeVarBits(0);
  bc.encodeVarBits(diff.abs()); // target index difference, not 0
  bc.encodeBit(diff < 0);
  bc.closeAndGetEncodedLength();
  return ab;
}

/// A way tag tree of one leaf with more tag data than a description holds.
Uint8List _oversizedTags() {
  final ab = Uint8List(2048);
  final bc = BitCoderContext(ab);
  bc.encodeBit(false); // leaf
  for (var i = 0; i < 300; i++) {
    bc.encodeVarBits(1); // next tag
    bc.encodeVarBits(4000); // its value
  }
  bc.encodeVarBits(0);
  return Uint8List.sublistView(ab, 0, bc.closeAndGetEncodedLength());
}

/// A profile whose way expression is nested [deepest] levels deep.
String _nestedProfile(int deepest) =>
    '---context:global\nassign dummy 0\n---context:way\nassign costfactor = ${'add 1 ' * (deepest - 1)}1\n';

/// A copy of a golden segment whose bytes the tests change, with the
/// checksums BRouter keeps for them.
class _Segment {
  final File file;
  final Uint8List bytes;
  _Segment(this.file) : bytes = file.readAsBytesSync();

  ByteData get _data => ByteData.sublistView(bytes);

  int fileIndex(int i) => _data.getInt64(8 * i) & 0xffffffffffff;

  void setFileIndex(int i, int value) {
    final version = _data.getInt64(8 * i) & ~0xffffffffffff;
    _data.setInt64(8 * i, version | value);
  }

  /// The first square that holds data.
  int get tileWithData {
    for (var t = 0; t < 25; t++) {
      if (fileIndex(t) > squareStart(t)) return t;
    }
    throw StateError('no data');
  }

  int squareStart(int tile) => tile > 0 ? fileIndex(tile - 1) : 200;

  int subIndex(int tile, int i) => _data.getInt32(squareStart(tile) + 4 * i);

  void setSubIndex(int tile, int i, int value) => _data.setInt32(squareStart(tile) + 4 * i, value);

  int blockStart(int tile, int i) => squareStart(tile) + (i == 0 ? 4 * _divisor * _divisor : subIndex(tile, i - 1));
  int blockEnd(int tile, int i) => squareStart(tile) + subIndex(tile, i);

  /// The first block of [tile] at least [length] bytes long.
  int blockOf(int tile, int length) {
    for (var i = 0; i < _divisor * _divisor; i++) {
      if (blockEnd(tile, i) - blockStart(tile, i) >= length) return i;
    }
    throw StateError('no block of $length bytes');
  }

  /// Writes the file with the checksums recomputed: the file index's, the
  /// sub index's of each square and the given block's.
  void save({int? tile, int? block}) {
    final extra = fileIndex(24);
    _data.setInt32(extra + 8, crc32(bytes, 0, 200) ^ 2);
    for (var t = 0; t < 25; t++) {
      if (fileIndex(t) > squareStart(t)) {
        _data.setInt32(extra + 12 + 4 * t, crc32(bytes, squareStart(t), 4 * _divisor * _divisor));
      }
    }
    if (tile != null && block != null) {
      final start = blockStart(tile, block);
      final end = blockEnd(tile, block);
      _data.setInt32(end - 4, crc32(bytes, start, end - 4 - start) ^ 2);
    }
    file.writeAsBytesSync(bytes);
  }

  PhysicalFile open(DataBuffers buffers) => PhysicalFile(file, buffers, -1, -1);

  /// The square [tile] of the copy (E120_N25: lon 120, lat 25).
  OsmFile square(PhysicalFile pf, int tile, DataBuffers buffers) =>
      OsmFile(pf, 300 + tile ~/ 5, 115 + tile % 5, buffers);
}

Matcher _dataFileException(String message) =>
    isA<DataFileException>().having((e) => e.message, 'message', contains(message));

void main() {
  group('micro-cache', () {
    StatCoderContext head({required int nodes, int dataSize = 0}) =>
        StatCoderContext(_microCacheHead(nodes: nodes, dataSize: dataSize));

    for (final nodes in [maxMicroCacheNodes + 1, -1]) {
      test('a node count of $nodes is rejected before anything is allocated', () {
        expect(
          () => MicroCache2(head(nodes: nodes), DataBuffers(), 0, 0, _divisor, null, null),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('$nodes nodes'))),
        );
        expect(
          () => DirectWeaver(head(nodes: nodes), DataBuffers(), 0, 0, _divisor, null, null, OsmNodesMap()),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('$nodes nodes'))),
        );
      });
    }

    test('the limits themselves are accepted', () {
      expect(() => checkMicroCacheNodes(maxMicroCacheNodes), returnsNormally);
      // An empty micro-cache claiming the largest data size decodes.
      expect(MicroCache2(head(nodes: 0, dataSize: maxMicroCacheDataSize), DataBuffers(), 0, 0, _divisor, null, null).getSize(), 0);
    });

    for (final dataSize in [maxMicroCacheDataSize + 1, -1]) {
      test('a decoded data size of $dataSize is rejected', () {
        expect(
          () => MicroCache2(head(nodes: 0, dataSize: dataSize), DataBuffers(), 0, 0, _divisor, null, null),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('$dataSize bytes'))),
        );
      });
    }
  });

  group('tag tree', () {
    test('a tree $maxTagTreeDepth inner nodes deep decodes', () {
      expect(() => TagValueCoder(StatCoderContext(_tagChain(maxTagTreeDepth)), DataBuffers(), null), returnsNormally);
    });

    test('a deeper tree is rejected', () {
      expect(
        () => TagValueCoder(StatCoderContext(_tagChain(maxTagTreeDepth + 1)), DataBuffers(), null),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('tag tree deeper'))),
      );
    });
  });

  group('link target', () {
    for (final diff in [1, -1]) {
      test('a link to node 0 + $diff of a one-node micro-cache is rejected', () {
        final matcher = throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('link to node $diff of 1')));
        expect(() => MicroCache2(StatCoderContext(_oneNodeOneLink(diff)), DataBuffers(), 0, 0, _divisor, null, null), matcher);
        expect(
          () => DirectWeaver(StatCoderContext(_oneNodeOneLink(diff)), DataBuffers(), 0, 0, _divisor, null, null, OsmNodesMap()),
          matcher,
        );
      });
    }
  });

  group('profile', () {
    BExpressionContextWay way() {
      final meta = BExpressionMetaData();
      final way = BExpressionContextWay.withHashSize(4096, meta);
      meta.readMetaData(goldenInput('lookups.dat'));
      return way;
    }

    test('an expression $maxProfileNesting levels deep parses', () {
      expect(() => way().parseProfile('deep.brf', _nestedProfile(maxProfileNesting), 'global', {}), returnsNormally);
    });

    test('an expression at the limit parses and evaluates in a spawned isolate', () async {
      // a lookup at the bottom, so nothing folds into a constant and
      // evaluating recurses through every level
      final description = goldenTable('ways.hex.gz').elementAt(100)[0];
      final lookups = goldenInput('lookups.dat').path;
      final text =
          '---context:way\nassign costfactor = ${'add 1 ' * (maxProfileNesting - 1)}highway=track\n';
      final costfactor = await Isolate.run(() {
        final meta = BExpressionMetaData();
        final way = BExpressionContextWay.withHashSize(0, meta);
        meta.readMetaData(File(lookups));
        way.parseProfile('deep.brf', text, 'global', {});
        way.evaluate(false, hexBytes(description));
        return way.getCostfactor();
      });
      expect(costfactor, greaterThanOrEqualTo(maxProfileNesting - 1));
    });

    test('a deeper expression is rejected', () {
      expect(
        () => way().parseProfile('deep.brf', _nestedProfile(maxProfileNesting + 1), 'global', {}),
        throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', contains('nested deeper than'))),
      );
    });
  });

  group('rd5 file', () {
    late Directory tmp;
    late _Segment segment;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('brouter_limits');
      segment = _Segment(goldenInput('E120_N25.rd5').copySync('${tmp.path}/E120_N25.rd5'));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('the unchanged copy reads, so each change below is what fails', () {
      segment.save();
      final buffers = DataBuffers();
      final pf = segment.open(buffers);
      final tile = segment.tileWithData;
      final block = segment.blockOf(tile, 24);
      final osmf = segment.square(pf, tile, buffers);
      expect(osmf.hasData(), isTrue);
      final lonIdx = (300 + tile ~/ 5) * _divisor + block % _divisor;
      final latIdx = (115 + tile % 5) * _divisor + block ~/ _divisor;
      expect(osmf.createMicroCacheAt(lonIdx, latIdx, buffers, null, null, true, null), isA<MicroCache2>());
      pf.close();
    });

    test('a file index starting inside the header is rejected', () {
      segment.setFileIndex(0, 100);
      segment.save();
      expect(() => segment.open(DataBuffers()), throwsA(_dataFileException('file index starts inside the header')));
    });

    test('a file index out of order is rejected', () {
      final tile = segment.tileWithData;
      segment.setFileIndex(tile, segment.squareStart(tile) - 1);
      segment.save();
      expect(() => segment.open(DataBuffers()), throwsA(_dataFileException('file index out of order')));
    });

    group('sub index', () {
      late int tile;
      late int block;
      setUp(() {
        tile = segment.tileWithData;
        block = segment.blockOf(tile, 24);
      });

      void expectRejected() {
        segment.save();
        final buffers = DataBuffers();
        final pf = segment.open(buffers);
        try {
          expect(() => segment.square(pf, tile, buffers), throwsA(_dataFileException('sub index out of order')));
        } finally {
          pf.close();
        }
      }

      test('a block ending before it starts is rejected', () {
        final start = segment.blockStart(tile, block) - segment.squareStart(tile);
        segment.setSubIndex(tile, block, start - 1);
        expectRejected();
      });

      test('a block too short for its checksum is rejected', () {
        final start = segment.blockStart(tile, block) - segment.squareStart(tile);
        segment.setSubIndex(tile, block, start + 3);
        expectRejected();
      });

      test('a block ending beyond its square is rejected', () {
        // 16 bytes beyond: long enough not to be rejected as too short
        final last = _divisor * _divisor - 1;
        segment.setSubIndex(tile, last, segment.fileIndex(tile) - segment.squareStart(tile) + 16);
        expectRejected();
      });
    });

    test('a micro-cache claiming too many nodes is a DataFileException', () {
      final tile = segment.tileWithData;
      final block = segment.blockOf(tile, 24);
      final head = _microCacheHead(nodes: maxMicroCacheNodes + 1);
      final start = segment.blockStart(tile, block);
      final end = segment.blockEnd(tile, block);
      segment.bytes.fillRange(start, end - 4, 0);
      segment.bytes.setRange(start, start + 16, head);
      segment.save(tile: tile, block: block);

      final buffers = DataBuffers();
      final pf = segment.open(buffers);
      try {
        final osmf = segment.square(pf, tile, buffers);
        final lonIdx = (300 + tile ~/ 5) * _divisor + block % _divisor;
        final latIdx = (115 + tile % 5) * _divisor + block ~/ _divisor;
        for (final hollow in [null, OsmNodesMap()]) {
          expect(
            () => osmf.createMicroCacheAt(lonIdx, latIdx, buffers, null, null, true, hollow),
            throwsA(_dataFileException('${maxMicroCacheNodes + 1} nodes')),
          );
        }
      } finally {
        pf.close();
      }
    });
    test('a micro-cache that runs past its block decodes the same whatever the buffer held', () {
      // zeros: a variable-length number whose prefix runs to the checksum,
      // and whose value then needs as many bits again, past the block
      final tile = segment.tileWithData;
      final block = segment.blockOf(tile, 24);
      final start = segment.blockStart(tile, block);
      final end = segment.blockEnd(tile, block);
      segment.bytes.fillRange(start, end - 4, 0);
      segment.save(tile: tile, block: block);

      String decode(int leftover) {
        final buffers = DataBuffers();
        final pf = segment.open(buffers);
        try {
          final osmf = segment.square(pf, tile, buffers);
          buffers.iobuffer.fillRange(0, buffers.iobuffer.length, leftover);
          final lonIdx = (300 + tile ~/ 5) * _divisor + block % _divisor;
          final latIdx = (115 + tile % 5) * _divisor + block ~/ _divisor;
          osmf.createMicroCacheAt(lonIdx, latIdx, buffers, null, null, true, null);
          return 'decoded';
        } on DataFileException catch (e) {
          return e.message;
        } finally {
          pf.close();
        }
      }

      final afterZeros = decode(0x00);
      expect(decode(0xff), afterZeros);
      expect(afterZeros, isNot('decoded'));
    });

    test('a micro-cache that overruns a decoder buffer is a DataFileException', () {
      final tile = segment.tileWithData;
      final tags = _oversizedTags();
      final block = segment.blockOf(tile, tags.length + 4);
      final start = segment.blockStart(tile, block);
      final end = segment.blockEnd(tile, block);
      segment.bytes.fillRange(start, end - 4, 0);
      segment.bytes.setRange(start, start + tags.length, tags);
      segment.save(tile: tile, block: block);

      final buffers = DataBuffers();
      final pf = segment.open(buffers);
      try {
        final osmf = segment.square(pf, tile, buffers);
        final lonIdx = (300 + tile ~/ 5) * _divisor + block % _divisor;
        final latIdx = (115 + tile % 5) * _divisor + block ~/ _divisor;
        for (final hollow in [null, OsmNodesMap()]) {
          expect(
            () => osmf.createMicroCacheAt(lonIdx, latIdx, buffers, null, null, true, hollow),
            throwsA(_dataFileException('micro-cache does not decode: RangeError')),
          );
        }
      } finally {
        pf.close();
      }
    });
  });
}
