// Port of btools.router.OsmTrack (BRouter v1.7.10, MIT): the parts the
// path search and the track totals use. Not ported: the binary reference
// track (readBinary/writeBinary, used only with rawTrackPath), voice hints,
// detour maps (only filled for voice hints, turnInstructionMode > 0) and
// the text output.
part of 'router.dart';

class OsmPathElementHolder {
  OsmPathElement? node;
  OsmPathElementHolder? nextHolder;
}

class OsmTrack {
  MatchedWaypoint? endPoint;
  List<int>? nogoChecksums;
  int profileTimestamp = 0;
  bool isDirty = false;

  bool showspeed = false;
  bool showSpeedProfile = false;
  bool showTime = false;

  Map<String, String>? params;
  List<OsmNodeNamed> pois = [];

  List<OsmPathElement> nodes = [];

  // Java: a CompactLongMap frozen into a FrozenLongMap; only get and
  // contains are used, so a Map behaves the same.
  Map<int, OsmPathElementHolder>? _nodesMap;

  String? message;
  List<String>? messageList;

  String name = 'unset';

  List<MatchedWaypoint>? matchedWaypoints;

  int distance = 0;
  int ascend = 0;
  int plainAscend = 0;
  int cost = 0;
  int energy = 0;

  void addNode(OsmPathElement node) => nodes.insert(0, node);

  void buildMap() {
    final map = <int, OsmPathElementHolder>{};
    for (final node in nodes) {
      final id = node.getIdFromPos();
      final nh = OsmPathElementHolder()..node = node;
      var h = map[id];
      if (h != null) {
        while (h!.nextHolder != null) {
          h = h.nextHolder;
        }
        h.nextHolder = nh;
      } else {
        map[id] = nh;
      }
    }
    _nodesMap = map;
  }

  void addNodes(OsmTrack t) {
    for (final n in t.nodes) {
      addNode(n);
    }
    buildMap();
  }

  bool containsNode(OsmPos node) => _nodesMap!.containsKey(node.getIdFromPos());

  OsmPathElement? getLink(int n1, int n2) {
    var h = _nodesMap![n2];
    while (h != null) {
      final e1 = h.node!.origin;
      if (e1 != null && e1.getIdFromPos() == n1) return h.node;
      h = h.nextHolder;
    }
    return null;
  }

  void appendTrack(OsmTrack t) {
    final ourSize = nodes.length;
    if (ourSize > 0 && t.nodes.length > 1) {
      final olde = nodes[ourSize - 1];
      t.nodes[1].origin = olde;
    }
    final t0 = ourSize > 0 ? nodes[ourSize - 1].getTime() : 0.0;
    final e0 = ourSize > 0 ? nodes[ourSize - 1].getEnergy() : 0.0;
    final c0 = ourSize > 0 ? nodes[ourSize - 1].cost : 0;
    for (var i = 0; i < t.nodes.length; i++) {
      final e = t.nodes[i];
      if (i == 0 && ourSize > 0 && nodes[ourSize - 1].getSElev() == _shortMin) {
        nodes[ourSize - 1].setSElev(e.getSElev());
      }
      if (i > 0 || ourSize == 0) {
        e.setTime(e.getTime() + t0); // float + float, rounded in setTime
        e.setEnergy(e.getEnergy() + e0);
        e.cost = i32(e.cost + c0);
        final m = e.message;
        if (m != null && !(m.lon == e.getILon() && m.lat == e.getILat())) {
          m.lon = e.getILon();
          m.lat = e.getILat();
        }
        nodes.add(e);
      }
    }
    distance += t.distance;
    ascend += t.ascend;
    plainAscend += t.plainAscend;
    cost += t.cost;
    energy = d2i(nodes[nodes.length - 1].getEnergy());
    showspeed |= t.showspeed;
    showSpeedProfile |= t.showSpeedProfile;
  }

  int getTotalSeconds() {
    // float s = last time - first time; (int) (s + 0.5)
    final s = nodes.length < 2 ? 0.0 : fround(nodes[nodes.length - 1].getTime() - nodes[0].getTime());
    return d2i(s + 0.5);
  }

  bool equalsTrack(OsmTrack t) {
    if (nodes.length != t.nodes.length) return false;
    for (var i = 0; i < nodes.length; i++) {
      final e1 = nodes[i];
      final e2 = t.nodes[i];
      if (e1.getILon() != e2.getILon() || e1.getILat() != e2.getILat()) return false;
    }
    return true;
  }
}
