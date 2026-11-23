// Port of btools.mapaccess.OsmNode (BRouter v1.7.10, MIT).
//
// Java compares nodes and links by reference with `==`; this port uses
// `identical`, because `==` here compares positions like Java's equals.
import 'dart:math' as math;
import 'dart:typed_data';

import '../codec/micro_cache.dart';
import '../util/byte_array_unifier.dart';
import '../util/cheap_ruler.dart';
import '../util/int32.dart';
import 'osm_link.dart';
import 'osm_nodes_map.dart';
import 'osm_pos.dart';
import 'turn_restriction.dart';

class OsmNode extends OsmLink implements OsmPos {
  int ilat = 0;

  int ilon = 0;

  /// The elevation in quarter metres (Java short).
  int selev = -32768;

  /// The node tags, if any.
  Uint8List? nodeDescription;

  TurnRestriction? firstRestriction;

  int visitID = 0;

  void addTurnRestriction(TurnRestriction tr) {
    tr.next = firstRestriction;
    firstRestriction = tr;
  }

  /// The links to other nodes.
  OsmLink? firstlink;

  OsmNode.empty();

  OsmNode(this.ilon, this.ilat);

  OsmNode.fromId(int id) : ilon = i32(id >> 32), ilat = i32(id & 0xffffffff);

  @override
  int getILat() => ilat;

  @override
  int getILon() => ilon;

  @override
  int getSElev() => selev;

  @override
  double getElev() => selev / 4.0;

  /// Java's `addLink(OsmLink, boolean, OsmNode)`; Dart has no overloads.
  void addLinkTo(OsmLink link, bool isReverse, OsmNode tn) {
    if (identical(link, firstlink)) {
      throw ArgumentError('UUUUPS');
    }

    if (isReverse) {
      link.n1 = tn;
      link.n2 = this;
      link.next = tn.firstlink;
      link.previous = firstlink;
      tn.firstlink = link;
      firstlink = link;
    } else {
      link.n1 = this;
      link.n2 = tn;
      link.next = firstlink;
      link.previous = tn.firstlink;
      tn.firstlink = link;
      firstlink = link;
    }
  }

  @override
  int calcDistance(OsmPos p) =>
      d2i(math.max(1.0, _javaRound(CheapRuler.distance(ilon, ilat, p.getILon(), p.getILat()))));

  // Java Math.round(double) for the non-negative distances here: half
  // rounds up, and x - floor(x) is exact, so no x + 0.5 rounding error.
  static double _javaRound(double x) {
    if (x.isNaN) return 0;
    final f = x.floorToDouble();
    return x - f >= 0.5 ? f + 1 : f;
  }

  @override
  String toString() => 'n_${ilon - 180000000}_${ilat - 90000000}';

  void parseNodeBody(MicroCache mc, OsmNodesMap hollowNodes, IByteArrayUnifier expCtxWay) {
    if (mc is MicroCache2) {
      parseNodeBody2(mc, hollowNodes, expCtxWay);
    } else {
      throw ArgumentError('unknown cache version: ${mc.runtimeType}');
    }
  }

  void parseNodeBody2(MicroCache2 mc, OsmNodesMap hollowNodes, IByteArrayUnifier expCtxWay) {
    final abUnifier = hollowNodes.getByteArrayUnifier();

    // read turn restrictions
    while (mc.readBoolean()) {
      final tr = TurnRestriction();
      tr.exceptions = mc.readShort();
      tr.isPositive = mc.readBoolean();
      tr.fromLon = mc.readInt();
      tr.fromLat = mc.readInt();
      tr.toLon = mc.readInt();
      tr.toLat = mc.readInt();
      addTurnRestriction(tr);
    }

    selev = mc.readShort();
    final nodeDescSize = mc.readVarLengthUnsigned();
    nodeDescription = nodeDescSize == 0 ? null : mc.readUnified(nodeDescSize, abUnifier);

    while (mc.hasMoreData()) {
      // read link data
      final endPointer = mc.getEndPointer();
      final linklon = i32(ilon + mc.readVarLengthSigned());
      final linklat = i32(ilat + mc.readVarLengthSigned());
      final sizecode = mc.readVarLengthUnsigned();
      final isReverse = (sizecode & 1) != 0;
      Uint8List? description;
      final descSize = sizecode >> 1;
      if (descSize > 0) {
        description = mc.readUnified(descSize, expCtxWay);
      }
      final geometry = mc.readDataUntil(endPointer);

      addLink(linklon, linklat, description, geometry, hollowNodes, isReverse);
    }
    hollowNodes.remove(this);
  }

  void addLink(
    int linklon,
    int linklat,
    Uint8List? description,
    Uint8List? geometry,
    OsmNodesMap hollowNodes,
    bool isReverse,
  ) {
    if (linklon == ilon && linklat == ilat) {
      return; // skip self-ref
    }

    OsmNode? tn; // find the target node
    OsmLink? link;

    // ...in our known links
    for (var l = firstlink; l != null; l = l.getNext(this)) {
      final t = l.getTarget(this);
      if (t.ilon == linklon && t.ilat == linklat) {
        tn = t;
        if (isReverse || (l.descriptionBitmap == null && !l.isReverse(this))) {
          link = l; // the correct one that needs our data
          break;
        }
      }
    }
    if (tn == null) {
      // .. not found, then check the hollow nodes
      tn = hollowNodes.get(linklon, linklat); // target node
      if (tn == null) {
        // node not yet known, create a new hollow proxy
        tn = OsmNode(linklon, linklat);
        tn.setHollow();
        hollowNodes.put(tn);
        addLinkTo(link = tn, isReverse, tn); // technical inheritance: link instance in node
      }
    }
    if (link == null) {
      addLinkTo(link = OsmLink(), isReverse, tn);
    }
    if (!isReverse) {
      link.descriptionBitmap = description;
      link.geometry = geometry;
    }
  }

  bool isHollow() => selev == -12345;

  void setHollow() {
    selev = -12345;
  }

  @override
  int getIdFromPos() => (ilon << 32) | ilat;

  void vanish() {
    if (!isHollow()) {
      var l = firstlink;
      while (l != null) {
        final target = l.getTarget(this);
        final nextLink = l.getNext(this);
        if (!target.isHollow()) {
          unlinkLink(l);
          if (!l.isLinkUnused()) {
            target.unlinkLink(l);
          }
        }
        l = nextLink;
      }
    }
  }

  void unlinkLink(OsmLink link) {
    final n = link.clear(this);

    if (identical(link, firstlink)) {
      firstlink = n;
      return;
    }
    var l = firstlink;
    while (l != null) {
      if (!identical(l.n1, this) && l.n1 != null) {
        // isReverse inline
        final nl = l.previous;
        if (identical(nl, link)) {
          l.previous = n;
          return;
        }
        l = nl;
      } else if (!identical(l.n2, this) && l.n2 != null) {
        final nl = l.next;
        if (identical(nl, link)) {
          l.next = n;
          return;
        }
        l = nl;
      } else {
        throw ArgumentError('unlinkLink: unknown source');
      }
    }
  }

  @override
  bool operator ==(Object other) => other is OsmNode && other.ilon == ilon && other.ilat == ilat;

  @override
  int get hashCode => i32(ilon + ilat);
}
