// Layer 0 of the golden comparison: the util port against Java v1.7.10.
import 'dart:typed_data';

import 'package:brouter/src/util/bit_coder_context.dart';
import 'package:brouter/src/util/byte_data.dart';
import 'package:brouter/src/util/cheap_angle_meter.dart';
import 'package:brouter/src/util/cheap_ruler.dart';
import 'package:brouter/src/util/crc32.dart';
import 'package:brouter/src/util/fdlibm.dart' as fdlibm;
import 'package:test/test.dart';

import 'golden.dart';

void main() {
  final rows = goldenTable('util.tsv.gz');
  Iterable<List<String>> kind(String k) => rows.where((r) => r[0] == k);

  // Every row is checked and every mismatch is listed, not only the first.
  void expectAll(String k, String? Function(List<String>) check) {
    final failures = <String>[];
    var n = 0;
    for (final r in kind(k)) {
      n++;
      final f = check(r);
      if (f != null) failures.add(f);
    }
    expect(n, greaterThan(0), reason: 'no $k rows');
    expect(failures, isEmpty, reason: '${failures.length} of $n $k rows differ, first: ${failures.take(5).join('; ')}');
  }

  test('sin, cos, exp, atan2 match StrictMath bit for bit', () {
    // Past high word 0x413921fb (about 1.65e6) fdlibm needs
    // __kernel_rem_pio2, which is not ported: those inputs must throw rather
    // than give a wrong answer.
    final limit = dbl('413921fbffffffff');
    var beyond = 0;
    for (final (name, f) in [('sin', fdlibm.sin), ('cos', fdlibm.cos)]) {
      expectAll(name, (r) {
        final x = dbl(r[1]);
        if (x.isFinite && x.abs() > limit) {
          beyond++;
          try {
            f(x);
            return '$name($x) should throw';
          } on ArgumentError {
            return null;
          }
        }
        final got = bits(f(x));
        return got == r[2] ? null : '$name(${r[1]}) = $got, want ${r[2]}';
      });
    }
    expect(beyond, 2, reason: 'Double.MAX_VALUE, for sin and cos');
    expectAll('exp', (r) {
      final got = bits(fdlibm.exp(dbl(r[1])));
      return got == r[2] ? null : 'exp(${r[1]}) = $got, want ${r[2]}';
    });
    expectAll('atan2', (r) {
      final got = bits(fdlibm.atan2(dbl(r[1]), dbl(r[2])));
      return got == r[3] ? null : 'atan2(${r[1]}, ${r[2]}) = $got, want ${r[3]}';
    });
  });

  test('CheapRuler and CheapAngleMeter match', () {
    final cam = CheapAngleMeter();
    expectAll('geo', (r) {
      final p = [for (var i = 1; i <= 6; i++) int.parse(r[i])];
      final (lon2, lat2) = CheapRuler.destination(p[0], p[1], dbl(r[7]), dbl(r[8]));
      final angle = cam.calcAngle(p[0], p[1], p[2], p[3], p[4], p[5]);
      final got = [
        bits(CheapRuler.distance(p[0], p[1], p[2], p[3])),
        '$lon2',
        '$lat2',
        bits(angle),
        bits(cam.getCosAngle()),
        bits(CheapAngleMeter.getDirection(p[0], p[1], p[2], p[3])),
      ];
      final want = r.sublist(9, 15);
      return got.join(',') == want.join(',') ? null : '${r.sublist(1, 9)}: $got, want $want';
    });
    expectAll('dir', (r) {
      final got = [
        bits(CheapAngleMeter.getDifferenceFromDirection(dbl(r[1]), dbl(r[2]))),
        bits(CheapAngleMeter.normalize(dbl(r[1]))),
      ];
      return got.join(',') == '${r[3]},${r[4]}' ? null : '${r[1]} ${r[2]}: $got';
    });
  });

  test('crc32 matches', () {
    expectAll('crc', (r) {
      final b = hexBytes(r[1]);
      final got = (crc32(b, 0, b.length) & 0xffffffff).toRadixString(16).padLeft(8, '0');
      return got == r[2] ? null : 'crc(${r[1]}) = $got, want ${r[2]}';
    });
  });

  test('var-length ints encode and decode as Java does', () {
    expectAll('varlen', (r) {
      final v = int.parse(r[1]);
      final w = ByteDataWriter(Uint8List(16));
      w.writeVarLengthSigned(v);
      w.writeVarLengthUnsigned(v);
      final enc = toHex(w.toByteArray());
      if (enc != r[2]) return '$v encodes to $enc, want ${r[2]}';
      final rd = ByteDataReader(hexBytes(r[2]));
      final s = rd.readVarLengthSigned();
      final u = rd.readVarLengthUnsigned();
      return '$s' == r[3] && '$u' == r[4] ? null : '$v decodes to $s / $u, want ${r[3]} / ${r[4]}';
    });
  });

  test('fixed-width ints write and read back as Java does', () {
    expectAll('ints', (r) {
      final w = ByteDataWriter(Uint8List(16));
      w.writeInt(int.parse(r[1]));
      w.writeLong(int.parse(r[2]));
      w.writeShort(int.parse(r[3]));
      w.writeByte(int.parse(r[4]));
      w.writeBoolean(r[5] == 'true');
      final enc = toHex(w.toByteArray());
      if (enc != r[6]) return '${r.sublist(1, 6)} encodes to $enc, want ${r[6]}';
      final rd = ByteDataReader(hexBytes(r[6]));
      final got = [rd.readInt(), rd.readLong(), rd.readShort(), rd.readByte(), rd.readBoolean()].join(',');
      return got == r.sublist(7, 12).join(',') ? null : 'reads $got, want ${r.sublist(7, 12)}';
    });
  });

  test('injectSize moves the data for 1-, 2- and 3-byte prefixes', () {
    expectAll('inject', (r) {
      final lead = hexBytes(r[1]);
      final data = hexBytes(r[2]);
      final w = ByteDataWriter(Uint8List(data.length + 16));
      w.write(lead);
      final at = w.writeSizePlaceHolder();
      w.write(data);
      w.injectSize(at);
      final got = toHex(w.toByteArray());
      return got == r[3] ? null : 'size ${data.length}: differs';
    });
  });

  test('decodeBits and decodeBitsReverse read what Java reads', () {
    expectAll('bitread', (r) {
      final bc = BitCoderContext(hexBytes(r[1]));
      for (final op in r[2].split(',').where((s) => s.isNotEmpty)) {
        final cv = op.substring(1).split(':');
        final count = int.parse(cv[0]);
        final got = op[0] == 'r' ? bc.decodeBitsReverse(count) : bc.decodeBits(count);
        if ('$got' != cv[1]) return '$op: got $got';
      }
      return null;
    });
  });

  test('bit coder encodes the same bytes and decodes the script back', () {
    expectAll('bits', (r) {
      final ops = r[1].split(',').where((s) => s.isNotEmpty).toList();
      final buf = Uint8List(4096);
      final bc = BitCoderContext(buf);
      for (final op in ops) {
        if (op.startsWith('v')) {
          bc.encodeVarBits(int.parse(op.substring(1)));
        } else if (op.startsWith('b')) {
          final mv = op.substring(1).split(':');
          bc.encodeBounded(int.parse(mv[0]), int.parse(mv[1]));
        } else {
          bc.encodeBit(op == '1');
        }
      }
      final len = bc.closeAndGetEncodedLength();
      final enc = toHex(buf.sublist(0, len));
      if (enc != r[2]) return 'encode differs for ${r[1].substring(0, 40)}…';
      final dc = BitCoderContext(hexBytes(r[2]));
      for (final op in ops) {
        if (op.startsWith('v')) {
          final want = int.parse(op.substring(1));
          final got = dc.decodeVarBits();
          if (got != want) return 'decodeVarBits $got, want $want';
        } else if (op.startsWith('b')) {
          final mv = op.substring(1).split(':');
          final got = dc.decodeBounded(int.parse(mv[0]));
          if (got != int.parse(mv[1])) return 'decodeBounded $got, want ${mv[1]}';
        } else {
          if (dc.decodeBit() != (op == '1')) return 'decodeBit differs';
        }
      }
      return null;
    });
  });
}
