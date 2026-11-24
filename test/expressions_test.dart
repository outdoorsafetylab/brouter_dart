// Layer 2 of the golden comparison: the expressions port against Java
// v1.7.10, every way and node description of the golden tiles through the
// hiking-mountain and trekking profiles (FORMAT.md 「第 2 層」).
import 'dart:io';
import 'dart:typed_data';

import 'package:brouter/src/expressions/expressions.dart';
import 'package:brouter/src/util/bit_coder_context.dart';
import 'package:brouter/src/util/crc32.dart';
import 'package:brouter/src/util/float32.dart';
import 'package:test/test.dart';

import 'golden.dart';

const _profiles = ['hiking-mountain', 'trekking'];

// Golden.rules: one metadata, the node context reading the way context,
// both parsed with "global" read-only and no extra parameters.
(BExpressionContextWay, BExpressionContextNode) _load(String profile, int hashSize) {
  final meta = BExpressionMetaData();
  final way = BExpressionContextWay.withHashSize(hashSize, meta);
  final node = BExpressionContextNode.withHashSize(hashSize, meta);
  node.setForeignContext(way);
  meta.readMetaData(goldenInput('lookups.dat'));
  final brf = goldenInput('$profile.brf');
  way.parseFile(brf, 'global', {});
  node.parseFile(brf, 'global', {});
  return (way, node);
}

String _bits(double f) => floatToRawIntBits(f).toRadixString(16).padLeft(8, '0');

void main() {
  final ways = [for (final r in goldenTable('ways.hex.gz')) r[0]];
  final nodes = [for (final r in goldenTable('nodes.hex.gz')) r[0]];
  final wayVars = BExpressionContextWay.buildInVariableNames;

  test('inputs are the ones FORMAT.md describes', () {
    expect(ways.length, 103306);
    expect(nodes.length, 1192);
  });

  // Every value of every line is compared; all differences are counted and
  // the first ones listed.
  void compare(String profile, {required int hashSize}) {
    final rows = goldenTable('$profile.rules.tsv.gz');
    expect(rows.length, ways.length + nodes.length, reason: 'one row per way, then per node');
    final (way, node) = _load(profile, hashSize);
    final failures = <String>[];
    var compared = 0;
    void check(int line, String what, String want, double got) {
      compared++;
      final g = _bits(got);
      if (g != want) failures.add('line $line $what: want $want, got $g');
    }

    for (var i = 0; i < ways.length; i++) {
      final row = rows[i];
      expect(row.sublist(0, 2), ['way', ways[i]], reason: 'line ${i + 1}');
      expect(row.length, 42, reason: 'line ${i + 1}');
      final ab = hexBytes(ways[i]);
      for (final (dir, inverse, col) in [('forward', false, 2), ('reverse', true, 22)]) {
        way.evaluate(inverse, ab);
        for (var v = 0; v < 20; v++) {
          check(i + 1, '$dir ${wayVars[v]}', row[col + v], way.getBuildInVariable(v));
        }
      }
    }
    for (var j = 0; j < nodes.length; j++) {
      final line = ways.length + j + 1;
      final row = rows[line - 1];
      expect(row, hasLength(4), reason: 'line $line');
      expect(row.sublist(0, 2), ['node', nodes[j]], reason: 'line $line');
      final ab = hexBytes(nodes[j]);
      for (final (granted, col) in [(false, 2), (true, 3)]) {
        node.evaluate(granted, ab);
        check(line, 'initialcost nodeaccessgranted=$granted', row[col], node.getInitialcost());
      }
    }
    expect(compared, ways.length * 40 + nodes.length * 2);
    expect(failures, isEmpty,
        reason: '${failures.length} of $compared values differ, first:\n${failures.take(10).join('\n')}');
  }

  for (final profile in _profiles) {
    test('$profile matches Java bit for bit, no result cache', () => compare(profile, hashSize: 0));
  }

  // Not in the golden run, but core evaluates through the cache: it must
  // give the same values.
  for (final profile in _profiles) {
    test('$profile matches Java with the result cache', () => compare(profile, hashSize: 4096));
  }

  // sub, divide, min, max, xor, not, equal and v: appear in neither golden
  // profile: golden/ops.brf uses them on every description, and ops.tsv.gz
  // holds one CRC32 per variable (FORMAT.md 「規則沒用到的運算子」).
  test('operators the golden profiles do not use match Java', () {
    final rows = goldenTable('ops.tsv.gz');
    expect(rows, hasLength(42));
    final meta = BExpressionMetaData();
    final way = BExpressionContextWay.withHashSize(0, meta);
    final node = BExpressionContextNode.withHashSize(0, meta);
    node.setForeignContext(way);
    meta.readMetaData(goldenInput('lookups.dat'));
    way.parseFile(File('golden/ops.brf'), 'global', {});
    node.parseFile(File('golden/ops.brf'), 'global', {});
    final wayBits = [for (var i = 0; i < 40; i++) ByteData(4 * ways.length)];
    for (var w = 0; w < ways.length; w++) {
      final ab = hexBytes(ways[w]);
      for (var d = 0; d < 2; d++) {
        way.evaluate(d == 1, ab);
        for (var v = 0; v < 20; v++) {
          wayBits[20 * d + v].setUint32(4 * w, floatToRawIntBits(way.getBuildInVariable(v)));
        }
      }
    }
    final nodeBits = [for (var g = 0; g < 2; g++) ByteData(4 * nodes.length)];
    for (var n = 0; n < nodes.length; n++) {
      final ab = hexBytes(nodes[n]);
      for (var g = 0; g < 2; g++) {
        node.evaluate(g == 1, ab);
        nodeBits[g].setUint32(4 * n, floatToRawIntBits(node.getInitialcost()));
      }
    }
    String crc(ByteData b) => (crc32(b.buffer.asUint8List(), 0, b.lengthInBytes) & 0xffffffff).toRadixString(16).padLeft(8, '0');
    final got = [
      for (var i = 0; i < 40; i++) ['way', i < 20 ? 'forward' : 'reverse', wayVars[i % 20], crc(wayBits[i])],
      for (var g = 0; g < 2; g++) ['node', '${g == 1}', 'initialcost', crc(nodeBits[g])],
    ];
    final differ = [
      for (var i = 0; i < 42; i++)
        if (rows[i].join('\t') != got[i].join('\t')) 'line ${i + 1}: want ${rows[i].join(' ')}, got ${got[i].join(' ')}',
    ];
    expect(differ, isEmpty, reason: '${differ.length} of 42 differ:\n${differ.join('\n')}');
  });

  // Tiles encoded with a newer lookups minor version can hold value indexes
  // past the table: Java reads those as 1 (unknown), except >= 1000, which
  // are numbers. The golden tiles use the same lookups.dat, so never do.
  test('value indexes past the lookup table decode as unknown', () {
    final (way, _) = _load('trekking', 0);
    final lookups = goldenInput('lookups.dat').readAsLinesSync();
    final wayLines = lookups.sublist(lookups.indexOf('---context:way'), lookups.indexOf('---context:node'));
    final tableSize = 2 + wayLines.where((l) => l.startsWith('highway;')).length; // "" and unknown first
    int decodedHighway(int d) {
      final buf = Uint8List(16);
      final bc = BitCoderContext(buf);
      bc.encodeVarBits(1); // highway is lookup 1
      bc.encodeVarBits(d < 2 ? 7 : (d < 9 ? d - 2 : d - 1)); // the encoder's value rotation
      bc.encodeVarBits(0);
      final desc = Uint8List.sublistView(buf, 0, bc.closeAndGetEncodedLength());
      final ld = way.createNewLookupData()!;
      way.decodeInto(ld, false, desc);
      return ld[1];
    }

    expect(decodedHighway(tableSize - 1), tableSize - 1);
    expect(decodedHighway(tableSize), 1);
    expect(decodedHighway(999), 1);
    expect(decodedHighway(1250), 1250);
  });

  // Java takes and returns float here, so a missing variable's default comes
  // back rounded like a profile value does. Compare the doubles themselves:
  // their float bits would round again and hide the difference.
  test('getVariableValue rounds the default to float', () {
    final (way, _) = _load('trekking', 0);
    expect(way.getVariableValue('no_such_variable', 0.01), 0.009999999776482582);
  });

  test('profiles cannot assign read-only variables or divide by zero', () {
    BExpressionContextWay parse(String text) {
      final meta = BExpressionMetaData();
      final way = BExpressionContextWay.withHashSize(0, meta);
      meta.readMetaData(goldenInput('lookups.dat'));
      way.parseProfile('test', text, 'global', {});
      return way;
    }

    const global = '---context:global\nassign limit 3\n';
    expect(() => parse('$global---context:way\nassign limit 4\n'), throwsArgumentError);
    expect(parse('$global---context:way\nassign costfactor limit\n').getVariableValue('limit', 0), 3);
    final ab = hexBytes(ways[100]);
    for (final zero in ['0', 'multiply -1 0']) {
      expect(() => parse('---context:way\nassign costfactor divide 1 $zero\n').evaluate(false, ab),
          throwsArgumentError, reason: 'divide by $zero');
    }
    parse('---context:way\nassign costfactor divide 1 2\n').evaluate(false, ab);
  });

  test('unify returns the cached array for an evaluated description', () {
    final (way, _) = _load('trekking', 64);
    final ab = hexBytes(ways[100]);
    way.evaluate(false, ab);
    final copy = Uint8List.fromList([0xff, ...ab, 0xff]);
    expect(way.unify(copy, 1, ab.length), same(ab));
    final other = hexBytes(ways[101]);
    expect(way.unify(other, 0, other.length), allOf(equals(other), isNot(same(other))));
  });

  // Checked offline against Java 21 on 73,000 values (random bits, decimals
  // next to float midpoints, every grammar branch); these few guard the
  // tricky ones.
  test('javaParseFloat and javaFloatToString follow Java', () {
    final parse = {
      '1.000000059604644775390625': '3f800000', // exact midpoint: ties to even
      '1.000000059604644775390625001': '3f800001', // a double round trip gives 3f800000
      '7.006492321624086e-46': '00000001',
      '3.4028235677973366e38': '7f7fffff',
      '1e5f': '47c35000',
      '0X1.8P-1f': '3f400000',
      ' -0 ': '80000000',
    };
    parse.forEach((s, want) => expect(_bits(javaParseFloat(s)), want, reason: s));
    for (final s in ['.', '1,5', '', 'e5', '0x1', 'inf', '1e']) {
      expect(() => javaParseFloat(s), throwsFormatException, reason: s);
    }
    final show = {
      0x80000000: '-0.0',
      0x00000001: '1.4E-45',
      0x7f7fffff: '3.4028235E38',
      0x3a83126f: '0.001',
      0x4b18967f: '9999999.0',
      0x4b189680: '1.0E7',
      0x19b89cd8: '1.9088503E-23',
    };
    show.forEach((b, want) => expect(javaFloatToString(intBitsToFloat(b)), want, reason: b.toRadixString(16)));
  });
}
