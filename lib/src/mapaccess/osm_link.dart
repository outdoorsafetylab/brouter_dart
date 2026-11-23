// Port of btools.mapaccess.OsmLink (BRouter v1.7.10, MIT).
//
// Java compares nodes and links here by reference, so this port uses
// `identical`: OsmNode's `==` compares positions.
import 'dart:typed_data';

import 'osm_link_holder.dart';
import 'osm_node.dart';

/// A link between two nodes. A link knows only its target; for the reverse
/// direction source and target are swapped, and [previous] is the
/// next-link pointer of the reverse direction.
class OsmLink {
  /// The way tags, valid for both directions.
  Uint8List? descriptionBitmap;

  /// The intermediate points, null for none, valid for both directions.
  Uint8List? geometry;

  // Java protected: package-internal.
  OsmNode? n1;
  OsmNode? n2;
  OsmLink? previous;
  OsmLink? next;

  OsmLinkHolder? _reverselinkholder;
  OsmLinkHolder? _firstlinkholder;

  OsmLink();

  OsmLink.between(OsmNode source, OsmNode target) : n1 = source, n2 = target;

  /// The target node for the given source.
  OsmNode getTarget(OsmNode source) => !identical(n2, source) && n2 != null ? n2! : n1!;

  /// The next-link pointer for the given source.
  OsmLink? getNext(OsmNode source) => !identical(n2, source) && n2 != null ? next : previous;

  /// Resets this link for the given direction.
  OsmLink? clear(OsmNode source) {
    OsmLink? n;
    if (n2 != null && !identical(n2, source)) {
      n = next;
      next = null;
      n2 = null;
      _firstlinkholder = null;
    } else if (n1 != null && !identical(n1, source)) {
      n = previous;
      previous = null;
      n1 = null;
      _reverselinkholder = null;
    } else {
      throw ArgumentError('internal error: setNext: unknown source');
    }
    if (n1 == null && n2 == null) {
      descriptionBitmap = null;
      geometry = null;
    }
    return n;
  }

  void setFirstLinkHolder(OsmLinkHolder? holder, OsmNode source) {
    if (n2 != null && !identical(n2, source)) {
      _firstlinkholder = holder;
    } else if (n1 != null && !identical(n1, source)) {
      _reverselinkholder = holder;
    } else {
      throw ArgumentError('internal error: setFirstLinkHolder: unknown source');
    }
  }

  OsmLinkHolder? getFirstLinkHolder(OsmNode source) {
    if (n2 != null && !identical(n2, source)) {
      return _firstlinkholder;
    } else if (n1 != null && !identical(n1, source)) {
      return _reverselinkholder;
    } else {
      throw ArgumentError('internal error: getFirstLinkHolder: unknown source');
    }
  }

  bool isReverse(OsmNode source) => !identical(n1, source) && n1 != null;

  bool isBidirectional() => n1 != null && n2 != null;

  bool isLinkUnused() => n1 == null && n2 == null;

  void addLinkHolder(OsmLinkHolder holder, OsmNode source) {
    final firstHolder = getFirstLinkHolder(source);
    if (firstHolder != null) {
      holder.setNextForLink(firstHolder);
    }
    setFirstLinkHolder(holder, source);
  }
}
