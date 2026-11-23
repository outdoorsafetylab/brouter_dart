// Routing does not read MicroCache2: NodesCache decodes with DirectWeaver
// straight into the node graph. The layer 1 table covers MicroCache2 only,
// so this checks that both ways build the same graph for every micro-cache
// of the two tiles: same nodes, elevations, tags, turn restrictions, and
// the same links with the same tags and geometry.
import 'dart:typed_data';

import 'package:brouter/src/codec/data_buffers.dart';
import 'package:brouter/src/codec/micro_cache.dart';
import 'package:brouter/src/mapaccess/osm_file.dart';
import 'package:brouter/src/mapaccess/osm_node.dart';
import 'package:brouter/src/mapaccess/osm_nodes_map.dart';
import 'package:brouter/src/mapaccess/physical_file.dart';
import 'package:brouter/src/util/byte_array_unifier.dart';
import 'package:test/test.dart';

import 'golden.dart';

class _Copy implements IByteArrayUnifier {
  @override
  Uint8List unify(Uint8List ab, int offset, int len) => Uint8List.fromList(ab.sublist(offset, offset + len));
}

String _hex(Uint8List? b) => b == null ? '-' : toHex(b);

/// A node's own data and its links, links sorted: the two decoders add
/// them in different orders. Also returns the number of links.
(String, int) describe(OsmNode n) {
  final trs = <String>[];
  for (var tr = n.firstRestriction; tr != null; tr = tr.next) {
    trs.add('${tr.exceptions},${tr.isPositive},${tr.fromLon},${tr.fromLat},${tr.toLon},${tr.toLat}');
  }
  final links = <String>[];
  for (var l = n.firstlink; l != null; l = l.getNext(n)) {
    final t = l.getTarget(n);
    links.add('${t.ilon},${t.ilat},${l.isReverse(n)},${_hex(l.descriptionBitmap)},${_hex(l.geometry)}');
  }
  links.sort();
  return (
    'selev=${n.selev} desc=${_hex(n.nodeDescription)} tr=[${trs.join(';')}] links=[${links.join(' ')}]',
    links.length,
  );
}

void main() {
  for (final tile in ['E120_N20', 'E120_N25']) {
    test('$tile: DirectWeaver builds the graph MicroCache2 and parseNodeBody2 build', () {
      final buffers = DataBuffers();
      final pf = PhysicalFile(goldenInput('$tile.rd5'), buffers, -1, -1);
      final div = pf.divisor;
      final unifier = _Copy();
      var caches = 0, links = 0;
      final differ = <String>[];
      try {
        for (var dlon = 0; dlon < 5; dlon++) {
          for (var dlat = 0; dlat < 5; dlat++) {
            final lonDegree = 120 + 180 + dlon;
            final latDegree = int.parse(tile.substring(6)) + 90 + dlat;
            final osmf = OsmFile(pf, lonDegree, latDegree, buffers);
            if (!osmf.hasData()) continue;
            for (var i = 0; i < div; i++) {
              for (var j = 0; j < div; j++) {
                final lonIdx = lonDegree * div + i, latIdx = latDegree * div + j;
                final mc = osmf.createMicroCacheAt(lonIdx, latIdx, buffers, null, null, true, null);
                if (mc is! MicroCache2 || mc.getSize() == 0) continue;
                caches++;
                final ids = [for (var k = 0; k < mc.getSize(); k++) mc.getIdForIndex(k)];

                // Both graphs start from hollow nodes for every id of the
                // cache, as NodesCache asks for nodes it already knows of.
                OsmNodesMap hollow(List<OsmNode> into) {
                  final m = OsmNodesMap();
                  for (final id in ids) {
                    final n = OsmNode.fromId(id)..setHollow();
                    m.put(n);
                    into.add(n);
                  }
                  return m;
                }

                final a = <OsmNode>[];
                final mapA = hollow(a);
                for (final n in a) {
                  expect(mc.getAndClear(n.getIdFromPos()), isTrue);
                  n.parseNodeBody2(mc, mapA, unifier);
                }

                final b = <OsmNode>[];
                final mapB = hollow(b);
                final woven = osmf.createMicroCacheAt(lonIdx, latIdx, buffers, null, null, true, mapB);
                expect(woven, same(MicroCache.emptyNonVirgin));

                for (var k = 0; k < ids.length; k++) {
                  expect(b[k].isHollow(), isFalse);
                  final (da, nlinks) = describe(a[k]);
                  final (db, _) = describe(b[k]);
                  links += nlinks;
                  if (da != db && differ.length < 3) differ.add('${a[k]}:\n  parse  $da\n  weave  $db');
                }
              }
            }
          }
        }
      } finally {
        pf.close();
      }
      expect(caches, greaterThan(1000));
      expect(differ, isEmpty, reason: differ.join('\n'));
      expect(links, greaterThan(caches));
    });
  }
}
