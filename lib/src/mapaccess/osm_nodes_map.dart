// Port of btools.mapaccess.OsmNodesMap (BRouter v1.7.10, MIT).
//
// Java keeps the nodes in a HashMap; this port uses Dart's default map,
// which iterates in insertion order. Only collectOutreachers iterates it,
// so that is the one place the visiting order can differ from Java.
import '../util/byte_array_unifier.dart';
import 'osm_link.dart';
import 'osm_node.dart';

class OsmNodesMap {
  final Map<OsmNode, OsmNode> _hmap = {};

  final ByteArrayUnifier _abUnifier = ByteArrayUnifier(16384, false);

  final OsmNode _testKey = OsmNode.empty();

  int nodesCreated = 0;
  int maxmem = 0;
  int _currentmaxmem = 4000000; // start with 4 MB
  int lastVisitID = 1000;
  int baseID = 1000;

  OsmNode? destination;
  int currentPathCost = 0;
  int currentMaxCost = 1000000000;

  OsmNode? endNode1;
  OsmNode? endNode2;

  int cleanupMode = 0;

  void cleanupAndCount(List<OsmNode> nodes) {
    if (cleanupMode == 0) {
      _justCount(nodes);
    } else {
      _cleanupPeninsulas(nodes);
    }
  }

  void _justCount(List<OsmNode> nodes) {
    for (final n in nodes) {
      if (n.firstlink != null) {
        nodesCreated++;
      }
    }
  }

  void _cleanupPeninsulas(List<OsmNode> nodes) {
    baseID = lastVisitID++;
    for (final n in nodes) {
      // loop over nodes again just for housekeeping
      if (n.firstlink != null) {
        if (n.visitID == 1) {
          try {
            _minVisitIdInSubtree(null, n);
          } on StackOverflowError {
            // as in Java: give up on this subtree
          }
        }
      }
    }
  }

  int _minVisitIdInSubtree(OsmNode? source, OsmNode n) {
    if (n.visitID == 1) {
      n.visitID = baseID; // border node
    } else {
      n.visitID = lastVisitID++;
    }
    var minId = n.visitID;
    nodesCreated++;

    OsmLink? nextLink;
    for (var l = n.firstlink; l != null; l = nextLink) {
      nextLink = l.getNext(n);

      final t = l.getTarget(n);
      if (identical(t, source)) continue;
      if (t.isHollow()) continue;

      var minIdSub = t.visitID;
      if (minIdSub == 1) {
        minIdSub = baseID;
      } else if (minIdSub == 0) {
        final nodesCreatedUntilHere = nodesCreated;
        minIdSub = _minVisitIdInSubtree(n, t);
        if (minIdSub > n.visitID) {
          // peninsula ?
          nodesCreated = nodesCreatedUntilHere;
          n.unlinkLink(l);
          t.unlinkLink(l);
        }
      } else if (minIdSub < baseID) {
        continue;
      } else if (cleanupMode == 2) {
        minIdSub = baseID; // in tree-mode, hitting anything is like a gateway
      }
      if (minIdSub < minId) minId = minIdSub;
    }
    return minId;
  }

  bool isInMemoryBounds(int npaths, bool extend) {
    var total = nodesCreated * 95 + npaths * 200;

    if (extend) {
      total += 100000;

      // when extending, try to have 1 MB  space
      final delta = total + 1900000 - _currentmaxmem;
      if (delta > 0) {
        _currentmaxmem += delta;
        if (_currentmaxmem > maxmem) {
          _currentmaxmem = maxmem;
        }
      }
    }
    return total <= _currentmaxmem;
  }

  List<OsmNode>? _nodes2check;

  /// Whether there is an escape from [n0] to a hollow node (or the
  /// destination).
  bool canEscape(OsmNode n0) {
    final nodes2check = _nodes2check!;
    var sawLowIDs = false;
    lastVisitID++;
    nodes2check.clear();
    nodes2check.add(n0);
    while (nodes2check.isNotEmpty) {
      final n = nodes2check.removeLast();
      if (n.visitID < baseID) {
        n.visitID = lastVisitID;
        nodesCreated++;
        for (var l = n.firstlink; l != null; l = l.getNext(n)) {
          nodes2check.add(l.getTarget(n));
        }
      } else if (n.visitID < lastVisitID) {
        sawLowIDs = true;
      }
    }
    if (sawLowIDs) {
      return true;
    }

    nodes2check.add(n0);
    while (nodes2check.isNotEmpty) {
      final n = nodes2check.removeLast();
      if (n.visitID == lastVisitID) {
        n.visitID = lastVisitID;
        nodesCreated--;
        for (var l = n.firstlink; l != null; l = l.getNext(n)) {
          nodes2check.add(l.getTarget(n));
        }
        n.vanish();
      }
    }

    return false;
  }

  void _addActiveNode(List<OsmNode> nodes2check, OsmNode n) {
    n.visitID = lastVisitID;
    nodesCreated++;
    nodes2check.add(n);
  }

  void clearTemp() {
    _nodes2check = null;
  }

  void collectOutreachers() {
    final nodes2check = _nodes2check = <OsmNode>[];
    nodesCreated = 0;
    for (final n in _hmap.values) {
      _addActiveNode(nodes2check, n);
    }

    lastVisitID++;
    baseID = lastVisitID;

    while (nodes2check.isNotEmpty) {
      final n = nodes2check.removeLast();
      n.visitID = lastVisitID;

      for (var l = n.firstlink; l != null; l = l.getNext(n)) {
        final t = l.getTarget(n);
        if (t.visitID != lastVisitID) {
          _addActiveNode(nodes2check, t);
        }
      }
      final dest = destination;
      if (dest != null && currentMaxCost < 1000000000) {
        final distance = n.calcDistance(dest);
        if (distance > currentMaxCost - currentPathCost + 100) {
          n.vanish();
        }
      }
      if (n.firstlink == null) {
        nodesCreated--;
      }
    }
  }

  ByteArrayUnifier getByteArrayUnifier() => _abUnifier;

  /// The node at the given position, or null.
  OsmNode? get(int ilon, int ilat) {
    _testKey.ilon = ilon;
    _testKey.ilat = ilat;
    return _hmap[_testKey];
  }

  void remove(OsmNode node) {
    // keep endnodes in hollow-map even when loaded (needed for escape analysis)
    if (!identical(node, endNode1) && !identical(node, endNode2)) {
      _hmap.remove(node);
    }
  }

  /// Puts a node into the map; returns the previous node at that position,
  /// or null. Like Java's HashMap, an existing key object is kept.
  OsmNode? put(OsmNode node) {
    final old = _hmap[node];
    _hmap[node] = node;
    return old;
  }
}
