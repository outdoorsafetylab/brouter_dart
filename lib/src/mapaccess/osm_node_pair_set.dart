// Port of btools.mapaccess.OsmNodePairSet (BRouter v1.7.10, MIT).
// Java's CompactLongMap is a Map<int, V> here.
import 'dart:typed_data';

/// A set of node pairs.
class OsmNodePairSet {
  final Int64List _n1a;
  final Int64List _n2a;
  int _tempNodes = 0;
  final int _maxTempNodes;
  int _npairs = 0;
  int _freezecount = 0;

  OsmNodePairSet(int maxTempNodeCount)
    : _maxTempNodes = maxTempNodeCount,
      _n1a = Int64List(maxTempNodeCount),
      _n2a = Int64List(maxTempNodeCount);

  Map<int, _OsmNodePair>? _map;

  void addTempPair(int n1, int n2) {
    if (_tempNodes < _maxTempNodes) {
      _n1a[_tempNodes] = n1;
      _n2a[_tempNodes] = n2;
      _tempNodes++;
    }
  }

  void freezeTempPairs() {
    _freezecount++;
    for (var i = 0; i < _tempNodes; i++) {
      _addPair(_n1a[i], _n2a[i]);
    }
    _tempNodes = 0;
  }

  void clearTempPairs() {
    _tempNodes = 0;
  }

  void _addPair(int n1, int n2) {
    final map = _map ??= {};
    _npairs++;

    var e = _getElement(n1, n2);
    if (e == null) {
      e = _OsmNodePair(n2);

      var e0 = map[n1];
      if (e0 != null) {
        while (e0!.next != null) {
          e0 = e0.next;
        }
        e0.next = e;
      } else {
        map[n1] = e;
      }
    }
  }

  int size() => _npairs;

  int tempSize() => _tempNodes;

  int getMaxTmpNodes() => _maxTempNodes;

  int getFreezeCount() => _freezecount;

  bool hasPair(int n1, int n2) => _map != null && (_getElement(n1, n2) != null || _getElement(n2, n1) != null);

  _OsmNodePair? _getElement(int n1, int n2) {
    var e = _map![n1];
    while (e != null) {
      if (e.node2 == n2) {
        return e;
      }
      e = e.next;
    }
    return null;
  }
}

class _OsmNodePair {
  final int node2;
  _OsmNodePair? next;
  _OsmNodePair(this.node2);
}
