// NodesCache end to end on the golden tiles, with a way context that keeps
// every way. Layer 3 compares routes against Java; this only checks that
// the cache finds files, weaves nodes and matches waypoints.
import 'dart:typed_data';

import 'package:brouter/src/codec/data_buffers.dart';
import 'package:brouter/src/codec/micro_cache.dart';
import 'package:brouter/src/mapaccess/matched_waypoint.dart';
import 'package:brouter/src/mapaccess/nodes_cache.dart';
import 'package:brouter/src/mapaccess/nodes_cache_context.dart';
import 'package:brouter/src/mapaccess/osm_file.dart';
import 'package:brouter/src/mapaccess/osm_node.dart';
import 'package:brouter/src/mapaccess/osm_node_pair_set.dart';
import 'package:brouter/src/mapaccess/osm_nodes_map.dart';
import 'package:brouter/src/mapaccess/physical_file.dart';
import 'package:test/test.dart';

import 'golden.dart';

class _KeepAll implements NodesCacheContext {
  @override
  final int lookupVersion;
  _KeepAll(this.lookupVersion);

  @override
  int get lookupMinorVersion => 0;
  @override
  int accessType(Uint8List tagValueSet) => 2;
  @override
  Uint8List unify(Uint8List ab, int offset, int len) => Uint8List.fromList(ab.sublist(offset, offset + len));
  @override
  bool isLookupIdxUsed(int idx) => true;
  @override
  void setDecodeForbidden(bool decodeForbidden) {}
  @override
  bool checkStartWay(Uint8List? ab) => true;
}

void main() {
  final rd5 = goldenInput('E120_N25.rd5');
  final ctx = _KeepAll(PhysicalFile.checkVersionIntegrity(rd5));

  // A node near 121.5E 25.05N and its record, read with MicroCache2.
  late int id;
  late OsmNode record;
  late int elevationType;
  setUpAll(() {
    final buffers = DataBuffers();
    final pf = PhysicalFile(rd5, buffers, -1, -1);
    addTearDown(pf.close);
    elevationType = pf.elevationType;
    final osmf = OsmFile(pf, 301, 115, buffers);
    final mc = osmf.createMicroCache(301500000, 115050000, buffers, null, null, null) as MicroCache2;
    id = mc.getIdForIndex(mc.getSize() ~/ 2);
    record = OsmNode.fromId(id)..setHollow();
    final map = OsmNodesMap()..put(record);
    expect(mc.getAndClear(id), isTrue);
    record.parseNodeBody2(mc, map, ctx);
    expect(record.firstlink, isNotNull);
  });

  Set<(int, int)> targets(OsmNode n) => {
    for (var l = n.firstlink; l != null; l = l.getNext(n)) (l.getTarget(n).ilon, l.getTarget(n).ilat),
  };

  test('getStartNode weaves the node and loads its neighbours', () {
    final nc = NodesCache(rd5.parent, ctx, false, 64 << 20, null, false);
    addTearDown(nc.close);
    final start = nc.getStartNode(id)!;
    expect(start.isHollow(), isFalse);
    expect(start.selev, record.selev);
    expect(start.nodeDescription, record.nodeDescription);
    expect(targets(start), containsAll(targets(record)));
    for (var l = start.firstlink; l != null; l = l.getNext(start)) {
      expect(l.getTarget(start).isHollow(), isFalse);
    }
    expect(nc.getElevationType(start.ilon, start.ilat), elevationType);
  });

  test('a node outside every data file is not found', () {
    final nc = NodesCache(rd5.parent, ctx, false, 64 << 20, null, false);
    addTearDown(nc.close);
    expect(nc.getStartNode((10000000 << 32) | 10000000), isNull);
    expect(nc.firstFileAccessFailed, isTrue);
    expect(nc.firstFileAccessName, 'W170_S80.rd5');
  });

  test('waypoints near the node match a way within the radius', () {
    final nc = NodesCache(rd5.parent, ctx, false, 64 << 20, null, false);
    addTearDown(nc.close);
    MatchedWaypoint wp(int dlon, int dlat, String name) => MatchedWaypoint()
      ..waypoint = OsmNode(record.ilon + dlon, record.ilat + dlat)
      ..name = name;
    final wps = [wp(30, 20, 'from'), wp(-400, 300, 'to')];
    expect(nc.matchWaypointsToNodes(wps, 250, OsmNodePairSet(10)), isTrue);
    for (final w in wps) {
      expect(w.crosspoint, isNotNull, reason: w.name);
      expect(w.radius, lessThanOrEqualTo(250), reason: w.name);
      expect(w.node1, isNotNull, reason: w.name);
      expect(w.node2, isNotNull, reason: w.name);
      expect(w.wayNearest.length, inInclusiveRange(1, 5), reason: w.name);
    }
    expect(wps[0].radius, lessThanOrEqualTo(wps[0].wayNearest.last.radius));
  });
}
