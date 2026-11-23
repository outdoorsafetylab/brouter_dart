// Port of btools.router.OsmPath (BRouter v1.7.10, MIT). Java float fields
// hold Float32-rounded doubles, and every float operation is rounded with
// fround, as `docs/design.md` D4 requires.
part of 'router.dart';

abstract class OsmPath implements OsmLinkHolder {
  // The cost of that path (a modified distance).
  int cost = 0;

  // The elevation at the target node (Java short).
  int selev = 0;

  int airdistance = 0; // distance to endpos

  OsmNode? sourceNode;
  OsmNode? targetNode;
  OsmLink? link;
  OsmPathElement? originElement;
  OsmPathElement? myElement;

  OsmLinkHolder? _nextForLink;

  int treedepth = 0;

  // the position of the waypoint just before this path position (for
  // angle calculation)
  int originLon = 0;
  int originLat = 0;

  // the classifier of the segment just before this paths position
  double lastClassifier = 0; // Java float
  double lastInitialCost = 0; // Java float

  int priorityclassifier = 0;

  static const int _pathStartBit = 1;
  static const int _canLeaveDestinationBit = 2;
  static const int _isOnDestinationBit = 4;
  static const int _hadDestinationStartBit = 8;

  int bitfield = _pathStartBit;

  bool _getBit(int mask) => (bitfield & mask) != 0;

  void _setBit(int mask, bool bit) {
    if (_getBit(mask) != bit) bitfield ^= mask;
  }

  bool didEnterDestinationArea() => !_getBit(_hadDestinationStartBit) && _getBit(_isOnDestinationBit);

  MessageData? message;

  void initStart(OsmLink link) {
    this.link = link;
    targetNode = link.n2 ?? link.n1; // Java getTarget(null)
    selev = targetNode!.getSElev();
    originLon = -1;
    originLat = -1;
  }

  void initFrom(OsmPath origin, OsmLink link, OsmTrack? refTrack, bool detailMode, RoutingContext rc) {
    origin.myElement ??= OsmPathElement.createFrom(origin);
    originElement = origin.myElement;
    this.link = link;
    sourceNode = origin.targetNode;
    targetNode = link.getTarget(sourceNode!);
    cost = origin.cost;
    lastClassifier = origin.lastClassifier;
    lastInitialCost = origin.lastInitialCost;
    bitfield = origin.bitfield;
    priorityclassifier = origin.priorityclassifier;
    initState(origin);
    _addAddionalPenalty(refTrack, detailMode, origin, link, rc);
  }

  void initState(OsmPath orig);

  void resetState();

  static int _seg = 1;

  void _addAddionalPenalty(OsmTrack? refTrack, bool detailMode, OsmPath origin, OsmLink link, RoutingContext rc) {
    final description = link.descriptionBitmap;
    final sourceNode = this.sourceNode!;
    final targetNode = this.targetNode!;
    if (description == null) {
      // could be a beeline path
      final m = MessageData();
      message = m;
      m.turnangle = 0;
      m.time = 1;
      m.energy = 0;
      m.priorityclassifier = 0;
      m.classifiermask = 0;
      m.lon = targetNode.getILon();
      m.lat = targetNode.getILat();
      m.ele = _shortMin;
      m.linkdist = sourceNode.calcDistance(targetNode);
      m.wayKeyValues = 'direct_segment=$_seg';
      _seg++;
      return;
    }

    final recordTransferNodes = detailMode;

    rc.nogoCost = 0.0;

    // extract the 3 positions of the first section
    var lon0 = origin.originLon;
    var lat0 = origin.originLat;

    var lon1 = sourceNode.getILon();
    var lat1 = sourceNode.getILat();
    var ele1 = origin.selev;

    var linkdisttotal = 0;

    message = detailMode ? MessageData() : null;

    final isReverse = link.isReverse(sourceNode);

    // evaluate the way tags
    final ctxWay = rc.expctxWay!;
    ctxWay.evaluate(rc.inverseDirection ^ isReverse, description);

    // calculate the costfactor inputs
    final costfactor = ctxWay.getCostfactor();
    final isTrafficBackbone = cost == 0 && ctxWay.getIsTrafficBackbone() > 0.0;
    final lastpriorityclassifier = priorityclassifier;
    priorityclassifier = d2i(ctxWay.getPriorityClassifier());

    // *** add initial cost if the classifier changed
    final newClassifier = ctxWay.getInitialClassifier();
    final newInitialCost = ctxWay.getInitialcost();
    final classifierDiff = fround(newClassifier - lastClassifier);
    if (newClassifier != 0.0 && lastClassifier != 0.0 && (classifierDiff > 0.0005 || classifierDiff < -0.0005)) {
      final initialcost = rc.inverseDirection ? lastInitialCost : newInitialCost;
      if (initialcost >= 1000000.0) {
        cost = -1;
        return;
      }
      final iicost = d2i(initialcost);
      if (message != null) message!.linkinitcost += iicost;
      cost = i32(cost + iicost);
    }
    lastClassifier = newClassifier;
    lastInitialCost = newInitialCost;

    // *** destination logic: no destination access in between
    final classifiermask = d2i(ctxWay.getClassifierMask());
    final newDestination = (classifiermask & 64) != 0;
    final oldDestination = _getBit(_isOnDestinationBit);
    if (_getBit(_pathStartBit)) {
      _setBit(_pathStartBit, false);
      _setBit(_canLeaveDestinationBit, newDestination);
      _setBit(_hadDestinationStartBit, newDestination);
    } else {
      if (oldDestination && !newDestination) {
        if (_getBit(_canLeaveDestinationBit)) {
          _setBit(_canLeaveDestinationBit, false);
        } else {
          cost = -1;
          return;
        }
      }
    }
    _setBit(_isOnDestinationBit, newDestination);

    var transferNode = link.geometry == null
        ? null
        : rc.geometryDecoder.decodeGeometry(link.geometry, sourceNode, targetNode, isReverse);

    for (var nsection = 0;; nsection++) {
      originLon = lon1;
      originLat = lat1;

      // compute the stuff for the next section
      int lon2;
      int lat2;
      int ele2;
      int originEle2;

      if (transferNode == null) {
        lon2 = targetNode.ilon;
        lat2 = targetNode.ilat;
        originEle2 = targetNode.selev;
      } else {
        lon2 = transferNode.ilon;
        lat2 = transferNode.ilat;
        originEle2 = transferNode.selev;
      }
      ele2 = originEle2;

      var isStartpoint = lon0 == -1 && lat0 == -1;

      // check turn restrictions (n detail mode (=final pass) no TR to not
      // mess up voice hints)
      if (nsection == 0 && rc.considerTurnRestrictions && !detailMode && !isStartpoint) {
        if (rc.inverseDirection
            ? TurnRestriction.isTurnForbidden(
                sourceNode.firstRestriction, lon2, lat2, lon0, lat0, rc.bikeMode || rc.footMode, rc.carMode)
            : TurnRestriction.isTurnForbidden(
                sourceNode.firstRestriction, lon0, lat0, lon2, lat2, rc.bikeMode || rc.footMode, rc.carMode)) {
          cost = -1;
          return;
        }
      }

      // if recording, new MessageData for each section (needed for turn
      // instructions)
      if (message != null && message!.wayKeyValues != null) {
        originElement!.message = message;
        message = MessageData();
      }

      var dist = rc.calcDistance(lon1, lat1, lon2, lat2);

      var stopAtEndpoint = false;
      if (rc.shortestmatch) {
        if (rc.isEndpoint) {
          stopAtEndpoint = true;
          ele2 = interpolateEle(ele1, ele2, rc.wayfraction);
        } else {
          // we just start here, reset everything
          cost = 0;
          resetState();
          lon0 = -1; // reset turncost-pipe
          lat0 = -1;
          isStartpoint = true;

          if (recordTransferNodes) {
            if (rc.wayfraction > 0.0) {
              ele1 = interpolateEle(ele1, ele2, 1.0 - rc.wayfraction);
              originElement = OsmPathElement.create(rc.ilonshortest, rc.ilatshortest, ele1, null);
            } else {
              originElement = null; // prevent duplicate point
            }
          }

          if (rc.checkPendingEndpoint()) {
            dist = rc.calcDistance(rc.ilonshortest, rc.ilatshortest, lon2, lat2);
            if (rc.shortestmatch) {
              stopAtEndpoint = true;
              ele2 = interpolateEle(ele1, ele2, rc.wayfraction);
            }
          }
        }
      }

      if (message != null) message!.linkdist += dist;
      linkdisttotal += dist;

      // apply a start-direction if appropriate (by faking the origin
      // position)
      if (isStartpoint) {
        if (rc.startDirectionValid) {
          final dir = rc.startDirection! * CheapRuler.degToRad;
          final lonlat2m = CheapRuler.getLonLatToMeterScales((lon0 + lat1) >> 1);
          lon0 = lon1 - d2i(1000.0 * fdlibm.sin(dir) / lonlat2m[0]);
          lat0 = lat1 - d2i(1000.0 * fdlibm.cos(dir) / lonlat2m[1]);
        } else {
          lon0 = lon1 - (lon2 - lon1);
          lat0 = lat1 - (lat2 - lat1);
        }
      }
      final angle = rc.anglemeter.calcAngle(lon0, lat0, lon1, lat1, lon2, lat2);
      final cosangle = rc.anglemeter.getCosAngle();

      // *** elevation stuff
      var deltaH = 0.0;
      if (ele2 == _shortMin) ele2 = ele1;
      if (ele1 != _shortMin) {
        deltaH = (ele2 - ele1) / 4.0;
        if (rc.inverseDirection) deltaH = -deltaH;
      }

      final elevation = ele2 == _shortMin ? 100.0 : ele2 / 4.0;

      var sectionCost = processWaySection(
          rc, dist.toDouble(), deltaH, elevation, angle, cosangle, isStartpoint, nsection, lastpriorityclassifier);
      if ((sectionCost < 0.0 || costfactor > 9998.0 && !detailMode) || sectionCost + cost >= 2000000000.0) {
        cost = -1;
        return;
      }

      if (isTrafficBackbone) sectionCost = 0.0;

      cost = i32(cost + d2i(sectionCost));

      // calculate traffic
      computeKinematic(rc, dist.toDouble(), deltaH, detailMode);

      if (message != null) {
        final m = message!;
        m.turnangle = fround(angle);
        m.time = fround(getTotalTime());
        m.energy = fround(getTotalEnergy());
        m.priorityclassifier = priorityclassifier;
        m.classifiermask = classifiermask;
        m.lon = lon2;
        m.lat = lat2;
        m.ele = originEle2;
        m.wayKeyValues = ctxWay.getKeyValueDescription(isReverse, description);
      }

      if (stopAtEndpoint) {
        if (recordTransferNodes) {
          originElement = OsmPathElement.create(rc.ilonshortest, rc.ilatshortest, originEle2, originElement);
          originElement!.cost = cost;
          if (message != null) originElement!.message = message;
        }
        if (rc.nogoCost < 0) {
          cost = -1;
        } else {
          cost = d2i(cost + rc.nogoCost);
        }
        return;
      }

      if (transferNode == null) {
        // *** penalty for being part of the reference track
        if (refTrack != null && refTrack.containsNode(targetNode) && refTrack.containsNode(sourceNode)) {
          final reftrackcost = linkdisttotal;
          cost = i32(cost + reftrackcost);
        }
        selev = ele2;
        break;
      }
      transferNode = transferNode.next;

      if (recordTransferNodes) {
        originElement = OsmPathElement.create(lon2, lat2, originEle2, originElement);
        originElement!.cost = cost;
      }
      lon0 = lon1;
      lat0 = lat1;
      lon1 = lon2;
      lat1 = lat2;
      ele1 = ele2;
    }

    // check for nogo-matches (after the *actual* start of segment)
    if (rc.nogoCost < 0) {
      cost = -1;
      return;
    } else {
      cost = d2i(cost + rc.nogoCost);
    }

    // add target-node costs
    final targetCost = processTargetNode(rc);
    if (targetCost < 0.0 || targetCost + cost >= 2000000000.0) {
      cost = -1;
      return;
    }
    cost = i32(cost + d2i(targetCost));
  }

  int interpolateEle(int e1, int e2, double fraction) {
    if (e1 == _shortMin || e2 == _shortMin) return _shortMin;
    return i16(d2i(e1 * (1.0 - fraction) + e2 * fraction));
  }

  double processWaySection(RoutingContext rc, double dist, double deltaH, double elevation, double angle,
      double cosangle, bool isStartpoint, int nsection, int lastpriorityclassifier);

  double processTargetNode(RoutingContext rc);

  void computeKinematic(RoutingContext rc, double dist, double deltaH, bool detailMode) {}

  int elevationCorrection();

  bool definitlyWorseThan(OsmPath p);

  OsmNode? getSourceNode() => sourceNode;

  OsmNode getTargetNode() => targetNode!;

  OsmLink? getLink() => link;

  @override
  void setNextForLink(OsmLinkHolder? holder) => _nextForLink = holder;

  @override
  OsmLinkHolder? getNextForLink() => _nextForLink;

  double getTotalTime() => 0.0;

  double getTotalEnergy() => 0.0;
}
