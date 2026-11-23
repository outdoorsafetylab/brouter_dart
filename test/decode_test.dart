// Layer 1 of the golden comparison (FORMAT.md "第 1 層"): every micro-cache
// of the two rd5 tiles decoded by the codec and mapaccess port, digested
// field by field the way golden/src/Golden.java does, against Java v1.7.10.
import 'dart:io';
import 'dart:typed_data';

import 'package:brouter/src/codec/data_buffers.dart';
import 'package:brouter/src/codec/micro_cache.dart';
import 'package:brouter/src/mapaccess/osm_file.dart';
import 'package:brouter/src/mapaccess/physical_file.dart';
import 'package:brouter/src/util/byte_array_unifier.dart';
import 'package:brouter/src/util/byte_data.dart';
import 'package:test/test.dart';

import 'golden.dart';

const tiles = ['E120_N20', 'E120_N25'];

/// Copies instead of unifying, so nothing depends on a cache (as Golden.java).
class _Copy implements IByteArrayUnifier {
  @override
  Uint8List unify(Uint8List ab, int offset, int len) => Uint8List.fromList(ab.sublist(offset, offset + len));
}

final _copy = _Copy();

/// Every non-empty micro-cache of [rd5]: one-degree square by square (lon,
/// then lat), lonIdx then latIdx within each; no way validator, no
/// waypoint matcher. Golden.eachCache.
void eachCache(File rd5, void Function(int lonIdx, int latIdx, MicroCache2 mc) visit) {
  final buffers = DataBuffers();
  final pf = PhysicalFile(rd5, buffers, -1, -1);
  try {
    final div = pf.divisor;
    final name = rd5.uri.pathSegments.last; // E120_N20.rd5
    final lon = int.parse(name.substring(1, name.indexOf('_'))) * (name[0] == 'W' ? -1 : 1);
    final latPart = name.substring(name.indexOf('_') + 1, name.indexOf('.'));
    final lat = int.parse(latPart.substring(1)) * (latPart[0] == 'S' ? -1 : 1);
    for (var dlon = 0; dlon < 5; dlon++) {
      for (var dlat = 0; dlat < 5; dlat++) {
        final lonDegree = lon + 180 + dlon;
        final latDegree = lat + 90 + dlat;
        final osmf = OsmFile(pf, lonDegree, latDegree, buffers);
        if (!osmf.hasData()) continue;
        for (var i = 0; i < div; i++) {
          for (var j = 0; j < div; j++) {
            final lonIdx = lonDegree * div + i;
            final latIdx = latDegree * div + j;
            final mc = osmf.createMicroCacheAt(lonIdx, latIdx, buffers, null, null, true, null);
            if (mc is MicroCache2 && mc.getSize() > 0) visit(lonIdx, latIdx, mc);
          }
        }
      }
    }
  } finally {
    pf.close();
  }
}

class Link {
  final int lon, lat;
  final bool reverse;
  final Uint8List description, geometry;
  Link(this.lon, this.lat, this.reverse, this.description, this.geometry);
}

class Node {
  final int ilon, ilat, selev;
  final List<List<int>> restrictions;
  final Uint8List description;
  final List<Link> links;
  Node(this.ilon, this.ilat, this.restrictions, this.selev, this.description, this.links);
}

/// The nodes as OsmNode.parseNodeBody2 reads them, in cache order.
/// Golden.nodes.
List<Node> nodes(MicroCache2 mc) {
  final out = <Node>[];
  final size = mc.getSize();
  final ids = [for (var i = 0; i < size; i++) mc.getIdForIndex(i)];
  for (final id in ids) {
    if (!mc.getAndClear(id)) throw StateError('node not found $id');
    final ilon = (id >> 32).toSigned(32);
    final ilat = (id & 0xffffffff).toSigned(32);
    final trs = <List<int>>[];
    while (mc.readBoolean()) {
      final exceptions = mc.readShort();
      final positive = mc.readBoolean() ? 1 : 0;
      trs.add([exceptions, positive, mc.readInt(), mc.readInt(), mc.readInt(), mc.readInt()]);
    }
    final selev = mc.readShort();
    final nodeDescSize = mc.readVarLengthUnsigned();
    final nodeDesc = nodeDescSize == 0 ? Uint8List(0) : mc.readUnified(nodeDescSize, _copy);
    final links = <Link>[];
    while (mc.hasMoreData()) {
      final end = mc.getEndPointer();
      final linklon = (ilon + mc.readVarLengthSigned()).toSigned(32);
      final linklat = (ilat + mc.readVarLengthSigned()).toSigned(32);
      final sizecode = mc.readVarLengthUnsigned();
      final descSize = sizecode >> 1;
      final desc = descSize > 0 ? mc.readUnified(descSize, _copy) : Uint8List(0);
      final geometry = mc.readDataUntil(end);
      links.add(Link(linklon, linklat, (sizecode & 1) != 0, desc, geometry ?? Uint8List(0)));
    }
    out.add(Node(ilon, ilat, trs, selev, nodeDesc, links));
  }
  return out;
}

/// FORMAT.md "節點紀錄", big-endian. Golden.canonical.
Uint8List canonical(int lonIdx, int latIdx, List<Node> nodes) {
  var len = 12;
  for (final n in nodes) {
    len += 12 + n.restrictions.length * 19 + 2 + 4 + n.description.length + 4;
    for (final l in n.links) {
      len += 9 + 4 + l.description.length + 4 + l.geometry.length;
    }
  }
  final o = ByteDataWriter(Uint8List(len));
  void bytes(Uint8List b) {
    o.writeInt(b.length);
    o.write(b);
  }

  o.writeInt(lonIdx);
  o.writeInt(latIdx);
  o.writeInt(nodes.length);
  for (final n in nodes) {
    o.writeInt(n.ilon);
    o.writeInt(n.ilat);
    o.writeInt(n.restrictions.length);
    for (final tr in n.restrictions) {
      o.writeShort(tr[0]);
      o.writeByte(tr[1]);
      for (var k = 2; k < 6; k++) {
        o.writeInt(tr[k]);
      }
    }
    o.writeShort(n.selev);
    bytes(n.description);
    o.writeInt(n.links.length);
    for (final l in n.links) {
      o.writeInt(l.lon);
      o.writeInt(l.lat);
      o.writeByte(l.reverse ? 1 : 0);
      bytes(l.description);
      bytes(l.geometry);
    }
  }
  if (o.size() != len) throw StateError('record length ${o.size()}, computed $len');
  return o.ab!;
}

/// One micro-cache as text, the same lines `Golden dump` prints.
String dump(List<Node> nodes) {
  final sb = StringBuffer();
  for (final n in nodes) {
    sb.writeln('node ${n.ilon} ${n.ilat} selev=${n.selev} desc=${toHex(n.description)}');
    for (final tr in n.restrictions) {
      sb.writeln('  restriction [${tr.join(', ')}]');
    }
    for (final l in n.links) {
      sb.writeln(
        '  link ${l.lon} ${l.lat}${l.reverse ? ' reverse' : ''} desc=${toHex(l.description)} '
        'geom=${toHex(l.geometry)}',
      );
    }
  }
  return sb.toString();
}

void main() {
  for (final tile in tiles) {
    test('$tile: every micro-cache decodes as Java does', () {
      // Rows go square by square, so lonIdx alone is not their order: key
      // by (lonIdx, latIdx).
      final want = <(int, int), (int, String)>{};
      for (final r in goldenTable('$tile.decode.tsv.gz')) {
        want[(int.parse(r[0]), int.parse(r[1]))] = (int.parse(r[2]), r[3]);
      }
      final got = <(int, int), (int, String)>{};
      final differ = <String>[];
      eachCache(goldenInput('$tile.rd5'), (lonIdx, latIdx, mc) {
        final ns = nodes(mc);
        final digest = toHex(sha256(canonical(lonIdx, latIdx, ns)).sublist(0, 16));
        got[(lonIdx, latIdx)] = (ns.length, digest);
        final w = want[(lonIdx, latIdx)];
        if (w != null && (w.$1 != ns.length || w.$2 != digest) && differ.length < 3) {
          differ.add(
            '($lonIdx, $latIdx): ${ns.length} nodes $digest, want ${w.$1} ${w.$2}; '
            'compare with `Golden dump <rd5> $lonIdx $latIdx`:\n${dump(ns).split('\n').take(20).join('\n')}',
          );
        }
      });
      expect(want, isNotEmpty);
      expect(got.keys.toSet().difference(want.keys.toSet()), isEmpty, reason: 'cells Java does not have');
      expect(want.keys.toSet().difference(got.keys.toSet()), isEmpty, reason: 'cells Java has');
      final mismatched = [
        for (final k in want.keys)
          if (got[k] != want[k]) k,
      ];
      expect(mismatched, isEmpty, reason: '${mismatched.length} of ${want.length} cells differ:\n${differ.join('\n')}');
    });
  }

  test('the comparison covers the 8,158 micro-caches of the two tiles', () {
    expect(tiles.map((t) => goldenTable('$t.decode.tsv.gz').length).reduce((a, b) => a + b), 8158);
  });

  test('sha256 matches the FIPS 180-4 examples', () {
    String h(String s) => toHex(sha256(Uint8List.fromList(s.codeUnits)));
    expect(h(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(h('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(
      h('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
      '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    );
  });
}
