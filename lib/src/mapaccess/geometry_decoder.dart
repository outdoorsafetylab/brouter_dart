// Port of btools.mapaccess.GeometryDecoder (BRouter v1.7.10, MIT).
import 'dart:typed_data';

import '../util/byte_data.dart';
import '../util/int32.dart';
import 'osm_node.dart';
import 'osm_transfer_node.dart';

class GeometryDecoder {
  final ByteDataReader _r = ByteDataReader(null);
  static const int _nCachedNodes = 128;
  final List<OsmTransferNode> _cachedNodes = List.generate(_nCachedNodes, (_) => OsmTransferNode());

  // result-cache
  OsmTransferNode? _firstTransferNode;
  bool _lastReverse = false;
  Uint8List? _lastGeometry;

  OsmTransferNode? decodeGeometry(Uint8List? geometry, OsmNode sourceNode, OsmNode targetNode, bool reverseLink) {
    if (identical(_lastGeometry, geometry) && _lastReverse == reverseLink) {
      return _firstTransferNode;
    }

    _firstTransferNode = null;
    OsmTransferNode? lastTransferNode;
    final startnode = reverseLink ? targetNode : sourceNode;
    _r.reset(geometry);
    var olon = startnode.ilon;
    var olat = startnode.ilat;
    var oselev = startnode.selev;
    var idx = 0;
    while (_r.hasMoreData()) {
      final trans = idx < _nCachedNodes ? _cachedNodes[idx++] : OsmTransferNode();
      trans.ilon = i32(olon + _r.readVarLengthSigned());
      trans.ilat = i32(olat + _r.readVarLengthSigned());
      trans.selev = i16(oselev + _r.readVarLengthSigned());
      olon = trans.ilon;
      olat = trans.ilat;
      oselev = trans.selev;
      if (reverseLink) {
        // reverse chaining
        trans.next = _firstTransferNode;
        _firstTransferNode = trans;
      } else {
        trans.next = null;
        if (lastTransferNode == null) {
          _firstTransferNode = trans;
        } else {
          lastTransferNode.next = trans;
        }
        lastTransferNode = trans;
      }
    }

    _lastReverse = reverseLink;
    _lastGeometry = geometry;

    return _firstTransferNode;
  }
}
