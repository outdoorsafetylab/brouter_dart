// Port of btools.router.RoutingEngine (BRouter v1.7.10, MIT): routing mode
// only (engineMode 0), one alternative, no output files, no reference-track
// file. Not ported: getInfo, round trips, seed search (SearchBoundary),
// misplaced-via-point correction (snapPathConnection and its roundabout
// helper; both reference profiles leave correctMisplacedViaPoints off), and
// the dirty reference track Java keeps after a timeout (it only feeds the
// reference-track file, which is not ported either).
part of 'router.dart';

class RoutingIslandException implements Exception {}

// Java passes null as the source of a start link; the Dart OsmLink takes a
// node, so a node that is never part of the graph stands in for null.
final OsmNode _noSource = OsmNode.empty();

class RoutingEngine {
  final Directory _segmentDir;
  final List<OsmNodeNamed> waypoints;
  final RoutingContext routingContext;

  NodesCache? _nodesCache;
  final SortedHeap<OsmPath> _openSet = SortedHeap<OsmPath>();
  bool _finished = false;

  int _linksProcessed = 0;

  int _nodeLimit = 0; // used for target island search
  static const int _maxnodesIslandCheck = 500;
  final OsmNodePairSet _islandNodePairs = OsmNodePairSet(_maxnodesIslandCheck);
  static const bool _useNodePoints = false; // use the start/end nodes instead of crosspoint

  static const int _maxDynamicRange = 60000;

  OsmTrack? _foundTrack = OsmTrack();
  OsmTrack? _foundRawTrack;
  int _alternativeIndex = 0;

  String? _errorMessage;

  bool _terminated = false;

  // Java reads System.currentTimeMillis(); a monotonic clock measures the
  // same intervals without jumping when the phone sets its time.
  static final Stopwatch _monotonic = Stopwatch()..start();
  static int _monotonicMillis() => _monotonic.elapsedMilliseconds;
  final int Function() _clock;
  int _startTime = 0;
  int _maxRunningTime = 0;

  OsmPathElement? _matchPath;

  OsmTrack? _guideTrack;

  double _airDistanceCostFactor = 0;
  double _lastAirDistanceCostFactor = 0;

  List<MatchedWaypoint>? _matchedWaypoints;

  static const bool _directWeaving = true;

  /// [segmentDir] holds the rd5 files; the profile ([RoutingContext.localFunction])
  /// is read with the lookups.dat next to it, as ProfileCache does.
  ///
  /// [clock] returns milliseconds and is only for tests; the default is a
  /// monotonic clock.
  RoutingEngine(Directory segmentDir, this.waypoints, this.routingContext, {int Function()? clock})
    : _segmentDir = segmentDir,
      _clock = clock ?? _monotonicMillis {
    _parseProfile(routingContext);
  }

  // ProfileCache.parseProfile without the cache.
  static void _parseProfile(RoutingContext rc) {
    final profileFile = File(rc.localFunction!);
    final lookupFile = File('${profileFile.parent.path}${Platform.pathSeparator}lookups.dat');
    final meta = BExpressionMetaData();
    final way = BExpressionContextWay(meta);
    final node = BExpressionContextNode(meta);
    node.setForeignContext(way);
    meta.readMetaData(lookupFile);
    way.parseFile(profileFile, 'global', rc.keyValues);
    node.parseFile(profileFile, 'global', rc.keyValues);
    rc.expctxWay = way;
    rc.expctxNode = node;
    rc.readGlobalConfig();
    if (rc.processUnusedTags) way.setAllTagsUsed();
  }

  /// Computes the route. With [maxRunningTime] (milliseconds) above 0 the
  /// search stops once it has run that long, and [getErrorMessage] returns
  /// `<operation> timeout after <N> seconds`, where the operation is
  /// `start-island-check`, `target-island-check`, `pass0`, `pass1` or
  /// `re-tracking` and N is the limit in whole seconds. As in Java, the island
  /// checks, pass0 and pass1 share the limit and the clock restarts before each
  /// re-tracking, so the whole call can take longer than the limit: about
  /// twice as long for a route between two points.
  void doRun([int maxRunningTime = 0]) {
    if (waypoints.length < 2) throw ArgumentError('we need two lat/lon points at least!');
    doRouting(maxRunningTime);
  }

  void doRouting([int maxRunningTime = 0]) {
    try {
      _startTime = _clock();
      _maxRunningTime = maxRunningTime;

      if (routingContext.allowSamewayback) {
        if (waypoints.length == 2) {
          final onn = OsmNodeNamed.of(OsmNode(waypoints[0].ilon, waypoints[0].ilat));
          onn.name = 'to';
          waypoints.add(onn);
        } else {
          waypoints[waypoints.length - 1].name = 'via${waypoints.length - 1}_center';
          final newpoints = <OsmNodeNamed>[];
          for (var i = waypoints.length - 2; i >= 0; i--) {
            final onn = OsmNodeNamed.of(OsmNode(waypoints[i].ilon, waypoints[i].ilat));
            onn.name = 'via';
            newpoints.add(onn);
          }
          newpoints[newpoints.length - 1].name = 'to';
          waypoints.addAll(newpoints);
        }
      }

      final nsections = waypoints.length - 1;
      var refTracks = List<OsmTrack?>.filled(nsections, null); // used ways for alternatives
      var lastTracks = List<OsmTrack?>.filled(nsections, null);
      final messageList = <String>[];
      for (var i = 0; ; i++) {
        final track = _findTrackAll(refTracks, lastTracks)!;
        track.message =
            'track-length = ${track.distance} filtered ascend = ${track.ascend}'
            ' plain-ascend = ${track.plainAscend} cost=${track.cost}';
        track.name = 'brouter_${routingContext.getProfileName()}_$i';
        messageList.add(track.message!);
        track.messageList = messageList;
        if (i == routingContext.getAlternativeIdx(0, 3)) {
          _foundTrack = track;
          _alternativeIndex = i;
        } else {
          continue;
        }
        break;
      }
    } on ArgumentError catch (e) {
      _errorMessage = '${e.message}';
    } on RoutingIslandException {
      _errorMessage = null;
    } catch (e) {
      _errorMessage = e.toString();
    } finally {
      _nodesCache?.close();
      _nodesCache = null;
      _openSet.clear();
      _finished = true; // this signals termination to outside
    }
  }

  OsmTrack? _findTrackAll(List<OsmTrack?> refTracks, List<OsmTrack?> lastTracks) {
    for (;;) {
      try {
        return _tryFindTrack(refTracks, lastTracks);
      } on RoutingIslandException {
        if (routingContext.useDynamicDistance) {
          for (final mwp in _matchedWaypoints!) {
            if (mwp.name!.contains('_add')) {
              final n1 = mwp.node1!.getIdFromPos();
              final n2 = mwp.node2!.getIdFromPos();
              _islandNodePairs.addTempPair(n1, n2);
            }
          }
        }
        _islandNodePairs.freezeTempPairs();
        _nodesCache!.clean(true);
        _matchedWaypoints = null;
      }
    }
  }

  OsmTrack? _tryFindTrack(List<OsmTrack?> refTracks, List<OsmTrack?> lastTracks) {
    final totaltrack = OsmTrack();
    final nUnmatched = waypoints.length;
    var hasDirectRouting = false;

    if (lastTracks.length < waypoints.length - 1) {
      refTracks = List.filled(waypoints.length - 1, null); // used ways for alternatives
      lastTracks = List.filled(waypoints.length - 1, null);
      hasDirectRouting = true;
    }
    for (final wp in waypoints) {
      if (wp.wpttype == MatchedWaypoint.waypointTypeDirect) hasDirectRouting = true;
    }

    // check for a track for that target (no reference-track file here)
    if (_matchedWaypoints == null) {
      // could exist from the previous alternative level
      final matched = <MatchedWaypoint>[];
      _matchedWaypoints = matched;
      for (var i = 0; i < nUnmatched; i++) {
        final mwp = MatchedWaypoint();
        mwp.waypoint = waypoints[i];
        mwp.name = waypoints[i].name;
        mwp.wpttype = waypoints[i].wpttype;
        matched.add(mwp);
      }
      final startSize = matched.length;
      _matchWaypointsToNodes(matched);
      if (startSize < matched.length) {
        refTracks = List.filled(matched.length - 1, null); // used ways for alternatives
        lastTracks = List.filled(matched.length - 1, null);
        hasDirectRouting = true;
      }

      routingContext.checkMatchedWaypointAgainstNogos(matched);

      // detect target islands: restricted search in inverse direction
      routingContext.inverseDirection = !routingContext.inverseRouting;
      _airDistanceCostFactor = 0.0;
      for (var i = 0; i < matched.length - 1; i++) {
        _nodeLimit = _maxnodesIslandCheck;
        if (matched[i].wpttype == MatchedWaypoint.waypointTypeDirect) continue;
        if (routingContext.inverseRouting) {
          final seg = _findTrack('start-island-check', matched[i], matched[i + 1], null, null, false);
          if (seg == null && _nodeLimit > 0) throw ArgumentError('start island detected for section $i');
        } else {
          final seg = _findTrack('target-island-check', matched[i + 1], matched[i], null, null, false);
          if (seg == null && _nodeLimit > 0) throw ArgumentError('target island detected for section $i');
        }
      }
      routingContext.inverseDirection = false;
      _nodeLimit = 0;
    } else {
      if (lastTracks.length < _matchedWaypoints!.length - 1) {
        refTracks = List.filled(_matchedWaypoints!.length - 1, null); // used ways for alternatives
        lastTracks = List.filled(_matchedWaypoints!.length - 1, null);
        hasDirectRouting = true;
      }
    }
    final matched = _matchedWaypoints!;
    routingContext.hasDirectRouting = hasDirectRouting;

    OsmPath._seg = 1; // set segment counter
    for (var i = 0; i < matched.length - 1; i++) {
      if (lastTracks[i] != null) {
        refTracks[i] ??= OsmTrack();
        refTracks[i]!.addNodes(lastTracks[i]!);
      }

      OsmTrack? seg;
      int wptIndex;
      if (routingContext.inverseRouting) {
        routingContext.inverseDirection = true;
        seg = _searchTrack(matched[i + 1], matched[i], null, refTracks[i]);
        routingContext.inverseDirection = false;
        wptIndex = i + 1;
      } else {
        seg = _searchTrack(matched[i], matched[i + 1], null, refTracks[i]);
        wptIndex = i;
        if (routingContext.continueStraight) {
          if (i < matched.length - 2) {
            final lastPoint = seg!.containsNode(matched[i + 1].node1!) ? matched[i + 1].node1! : matched[i + 1].node2!;
            final nogo = OsmNodeNamed.of(lastPoint);
            nogo.radius = 5;
            nogo.name = 'nogo${i + 1}';
            nogo.nogoWeight = 9999.0;
            nogo.isNogo = true;
            (routingContext.nogopoints ??= []).add(nogo);
          }
        }
      }
      if (seg == null) return null;

      if (routingContext.correctMisplacedViaPoints &&
          matched[i].wpttype != MatchedWaypoint.waypointTypeDirect &&
          matched[i].wpttype != MatchedWaypoint.waypointTypeMeeting &&
          !routingContext.allowSamewayback) {
        throw UnsupportedError('correctMisplacedViaPoints is not ported');
      }
      if (wptIndex > 0) matched[wptIndex].indexInTrack = totaltrack.nodes.length - 1;

      totaltrack.appendTrack(seg);
      lastTracks[i] = seg;
    }

    _postElevationCheck(totaltrack);

    _recalcTrack(totaltrack);

    matched[matched.length - 1].indexInTrack = totaltrack.nodes.length - 1;
    totaltrack.matchedWaypoints = matched;
    // processVoiceHints returns at once without detours or direct routing,
    // and produces nothing ported here otherwise.
    totaltrack.showTime = routingContext.showTime;
    totaltrack.params = routingContext.keyValues;

    if (routingContext.poipoints != null) totaltrack.pois = routingContext.poipoints!;

    return totaltrack;
  }

  void _postElevationCheck(OsmTrack track) {
    OsmPathElement? lastPt;
    OsmPathElement? startPt;
    var lastElev = _shortMin;
    var startElev = _shortMin;
    var endElev = _shortMin;
    var startIdx = 0;
    var endIdx = -1;
    var dist = 0;
    final ourSize = track.nodes.length;
    for (var idx = 0; idx < ourSize; idx++) {
      final n = track.nodes[idx];
      if (n.getSElev() == _shortMin && lastElev != _shortMin && idx < ourSize - 1) {
        // start one point before entry point to get better elevation results
        if (idx > 1) startElev = track.nodes[idx - 2].getSElev();
        if (startElev == _shortMin) startElev = lastElev;
        startIdx = idx;
        startPt = lastPt;
        dist = 0;
        if (lastPt != null) dist += n.calcDistance(lastPt);
      } else if (n.getSElev() != _shortMin && lastElev == _shortMin && startElev != _shortMin) {
        // end one point behind exit point to get better elevation results
        if (idx + 1 < track.nodes.length) endElev = track.nodes[idx + 1].getSElev();
        if (endElev == _shortMin) endElev = n.getSElev();
        endIdx = idx;
        var tmpPt = track.nodes[startIdx > 1 ? startIdx - 2 : startIdx - 1];
        final diffElev = endElev - startElev;
        dist += tmpPt.calcDistance(startPt!);
        dist += n.calcDistance(lastPt!);
        var distRest = dist;
        var incline = diffElev / (dist / 100.0);
        var lastMsg = '';
        var tmpincline = 0.0;
        var startincline = 0.0;
        var selev = track.nodes[startIdx > 1 ? startIdx - 2 : startIdx - 1].getSElev().toDouble();
        var hasInclineTags = false;
        for (var i = startIdx - 1; i < endIdx + 1; i++) {
          final tmp = track.nodes[i];
          if (tmp.message != null) {
            final msg = tmp.message!.wayKeyValues!;
            if (msg != lastMsg) {
              final revers = msg.contains('reversedirection=yes');
              var pos = msg.indexOf('incline=');
              if (pos != -1) {
                hasInclineTags = true;
                var s = msg.substring(pos + 8);
                pos = s.indexOf(' ');
                if (pos != -1) s = s.substring(0, pos);
                if (s.isNotEmpty) {
                  var ind = s.indexOf('%');
                  if (ind != -1) s = s.substring(0, ind);
                  ind = s.indexOf('°');
                  if (ind != -1) s = s.substring(0, ind);
                  final parsed = _javaParseDouble(s);
                  if (parsed == null) {
                    tmpincline = 0;
                  } else {
                    tmpincline = parsed;
                    if (revers) tmpincline *= -1;
                  }
                }
              } else {
                tmpincline = 0;
              }
              if (startincline == 0) {
                startincline = tmpincline;
              } else if (startincline < 0 && tmpincline > 0) {
                // for the way up find the exit point
                final diff = endElev - selev;
                tmpincline = diff / (distRest / 100.0);
              }
            }
            lastMsg = msg;
          }
          final tmpdist = tmp.calcDistance(tmpPt);
          distRest -= tmpdist;
          if (hasInclineTags) incline = tmpincline;
          selev = selev + (tmpdist / 100.0 * incline);
          tmp.setSElev(i16(d2i(selev)));
          tmp.message!.ele = i16(d2i(selev));
          tmpPt = tmp;
        }
        dist = 0;
      } else if (n.getSElev() != _shortMin && lastElev == _shortMin && startIdx == 0) {
        // fill at start
        for (var i = 0; i < idx; i++) {
          track.nodes[i].setSElev(n.getSElev());
        }
      } else if (n.getSElev() == _shortMin && idx == track.nodes.length - 1) {
        // fill at end
        startIdx = idx;
        for (var i = startIdx; i < track.nodes.length; i++) {
          track.nodes[i].setSElev(lastElev);
        }
      } else if (n.getSElev() == _shortMin) {
        if (lastPt != null) dist += n.calcDistance(lastPt);
      }
      lastElev = n.getSElev();
      lastPt = n;
    }
  }

  // Java Double.parseDouble on a trimmed string: null where Java throws.
  static double? _javaParseDouble(String s) {
    var t = s.trim();
    if (t.isNotEmpty && 'fFdD'.contains(t[t.length - 1])) t = t.substring(0, t.length - 1);
    return double.tryParse(t);
  }

  void _recalcTrack(OsmTrack t) {
    var totaldist = 0;
    var totaltime = 0;
    var lasttime = 0.0; // Java float
    var speedMin = fround(9999); // Java float
    final directMap = <int, int>{};
    var tmptime = 1.0; // Java float
    var speed = 1.0; // Java float
    int dist;
    double angle;

    var ascend = 0.0;
    var ehb = 0.0;
    final ourSize = t.nodes.length;

    var eleStart = _shortMin;
    var eleEnd = _shortMin;
    final eleFactor = routingContext.inverseRouting ? 0.25 : -0.25;

    for (var i = 0; i < ourSize; i++) {
      final n = t.nodes[i];
      n.message ??= MessageData();
      OsmPathElement? nLast;
      if (i == 0) {
        angle = 0;
        dist = 0;
      } else if (i == 1) {
        angle = 0;
        nLast = t.nodes[0];
        dist = nLast.calcDistance(n);
      } else {
        final lon0 = t.nodes[i - 2].getILon();
        final lat0 = t.nodes[i - 2].getILat();
        final lon1 = t.nodes[i - 1].getILon();
        final lat1 = t.nodes[i - 1].getILat();
        final lon2 = t.nodes[i].getILon();
        final lat2 = t.nodes[i].getILat();
        angle = routingContext.anglemeter.calcAngle(lon0, lat0, lon1, lat1, lon2, lat2);
        nLast = t.nodes[i - 1];
        dist = nLast.calcDistance(n);
      }
      n.message!.linkdist = dist;
      n.message!.turnangle = fround(angle);
      totaldist += dist;
      totaltime = d2i(fround(fround(totaltime.toDouble()) + n.getTime()));
      tmptime = fround(n.getTime() - lasttime);
      if (dist > 0) {
        speed = fround(fround(fround(dist.toDouble()) / tmptime) * fround(3.6));
        speedMin = math.min(speedMin, speed);
      }
      if (tmptime == 1.0) {
        // no time used here
        directMap[i] = dist;
      }

      lasttime = n.getTime();

      final ele = n.getSElev();
      if (ele != _shortMin) eleEnd = ele;
      if (eleStart == _shortMin) eleStart = ele;

      if (nLast != null) {
        final eleLast = nLast.getSElev();
        if (eleLast != _shortMin) ehb = ehb + (eleLast - ele) * eleFactor;
        final filter = _elevationFilter(n);
        if (ehb > 0) {
          ascend += ehb;
          ehb = 0;
        } else if (ehb < filter) {
          ehb = filter;
        }
      }
    }

    t.ascend = d2i(ascend);
    t.plainAscend = d2i((eleStart - eleEnd) * eleFactor + 0.5);

    t.distance = totaldist;

    final keys = directMap.keys.toList()..sort();
    for (final key in keys) {
      final value = directMap[key]!;
      final addTime = fround(fround(value.toDouble()) / fround(speedMin / fround(3.6)));

      var addEnergy = 0.0;
      if (key > 0) {
        const gravity = 9.81; // in meters per second^(-2)
        final incline = (t.nodes[key - 1].getSElev() == _shortMin || t.nodes[key].getSElev() == _shortMin
            ? 0.0
            : (t.nodes[key - 1].getElev() - t.nodes[key].getElev()) / value);
        final fRoll = routingContext.totalMass * gravity * (routingContext.defaultCr + incline);
        final spd = speedMin / 3.6;
        addEnergy = value * (routingContext.sCx * spd * spd + fRoll);
      }
      for (var j = key; j < ourSize; j++) {
        final n = t.nodes[j];
        n.setTime(n.getTime() + addTime);
        n.setEnergy(n.getEnergy() + fround(addEnergy));
      }
    }
    t.energy = d2i(t.nodes[t.nodes.length - 1].getEnergy());
  }

  /// The filter value for 1 s / 3 s elevation sources.
  double _elevationFilter(OsmPos n) {
    final c = _nodesCache;
    if (c != null) {
      final r = c.getElevationType(n.getILon(), n.getILat());
      if (r == 1) return -5.0;
    }
    return -10.0;
  }

  void _matchWaypointsToNodes(List<MatchedWaypoint> unmatchedWaypoints) {
    _resetCache(false);
    final useDynamicDistance = routingContext.useDynamicDistance;
    final bAddBeeline = routingContext.buildBeelineOnRange;
    var range = routingContext.waypointCatchingRange;
    var ok = _nodesCache!.matchWaypointsToNodes(unmatchedWaypoints, range, _islandNodePairs);
    if (!ok && useDynamicDistance) {
      _resetCache(false);
      range = -_maxDynamicRange.toDouble();
      final tmp = <MatchedWaypoint>[];
      for (final mwp in unmatchedWaypoints) {
        if (mwp.crosspoint == null || mwp.radius >= routingContext.waypointCatchingRange) tmp.add(mwp);
      }
      ok = _nodesCache!.matchWaypointsToNodes(tmp, range, _islandNodePairs);
    }
    if (!ok) {
      for (final mwp in unmatchedWaypoints) {
        if (mwp.crosspoint == null) throw ArgumentError('${mwp.name}-position not mapped in existing datafile');
      }
    }
    if (useDynamicDistance && !_useNodePoints && bAddBeeline) {
      throw UnsupportedError('add_beeline is not ported');
    }
  }

  OsmTrack? _searchTrack(MatchedWaypoint startWp, MatchedWaypoint endWp, OsmTrack? nearbyTrack, OsmTrack? refTrack) {
    try {
      final calcBeeline = startWp.wpttype == MatchedWaypoint.waypointTypeDirect;
      if (!calcBeeline) return _searchRoutedTrack(startWp, endWp, nearbyTrack, refTrack);

      // we want a beeline-segment
      final startLink = OsmLink()..n2 = startWp.crosspoint;
      var path = routingContext.createPathStart(startLink);
      path = routingContext.createPath(path, OsmLink.between(startWp.crosspoint!, endWp.crosspoint!), null, false);
      return _compileTrack(path, false);
    } finally {
      routingContext.restoreNogoList();
    }
  }

  OsmTrack _searchRoutedTrack(
    MatchedWaypoint startWp,
    MatchedWaypoint endWp,
    OsmTrack? nearbyTrack,
    OsmTrack? refTrack,
  ) {
    OsmTrack? track;
    final airDistanceCostFactors = [routingContext.pass1coefficient, routingContext.pass2coefficient];

    for (var cfi = 0; cfi < airDistanceCostFactors.length; cfi++) {
      if (cfi > 0) _lastAirDistanceCostFactor = airDistanceCostFactors[cfi - 1];
      _airDistanceCostFactor = airDistanceCostFactors[cfi];

      if (_airDistanceCostFactor < 0.0) continue;

      var t = _findTrack(cfi == 0 ? 'pass0' : 'pass1', startWp, endWp, track, refTrack, false);
      if (t == null && track != null && _matchPath != null) {
        // ups, didn't find it, use a merge
        t = _mergeTrack(_matchPath!, track);
      }
      if (t != null) {
        track = t;
      } else {
        throw ArgumentError('no track found at pass=$cfi');
      }
    }
    if (track == null) throw ArgumentError('no track found');

    if (refTrack == null) {
      track.endPoint = endWp;
      track.isDirty = false;
      _foundRawTrack = track;
    }

    // final run for verbose log info and detail nodes
    _airDistanceCostFactor = 0.0;
    _lastAirDistanceCostFactor = 0.0;
    _guideTrack = track;
    _startTime = _clock(); // reset timeout...
    try {
      final tt = _findTrack('re-tracking', startWp, endWp, null, refTrack, false);
      if (tt == null) throw ArgumentError('error re-tracking track');
      return tt;
    } finally {
      _guideTrack = null;
    }
  }

  void _resetCache(bool detailed) {
    final maxmem = routingContext.memoryclass * 1024 * 1024; // in MB
    _nodesCache = NodesCache(
      _segmentDir,
      _WayCacheContext(routingContext.expctxWay!),
      routingContext.forceSecondaryData,
      maxmem,
      _nodesCache,
      detailed,
    );
    _islandNodePairs.clearTempPairs();
  }

  OsmPath? _getStartPathFor(OsmNode n1, OsmNode n2, MatchedWaypoint mwp, OsmNodeNamed? endPos, bool sameSegmentSearch) {
    if (endPos != null) endPos.radius = 1.5;
    final p = _getStartPath(n1, n2, OsmNodeNamed.of(mwp.crosspoint!), endPos, sameSegmentSearch);

    // special case: start+end on same segment
    if (p != null && p.cost >= 0 && sameSegmentSearch && endPos != null && endPos.radius < 1.5) {
      p.treedepth = 0; // hack: mark for the final-check
    }
    return p;
  }

  OsmPath? _getStartPath(OsmNode n1, OsmNode n2, OsmNodeNamed wp, OsmNodeNamed? endPos, bool sameSegmentSearch) {
    try {
      routingContext.setWaypoint(wp, false, sameSegmentSearch ? endPos : null);
      OsmPath? bestPath;
      OsmLink? bestLink;
      final startLink = OsmLink()..n2 = n1; // Java: new OsmLink(null, n1)
      final startPath = routingContext.createPathStart(startLink);
      startLink.addLinkHolder(startPath, _noSource);
      var minradius = 1e10;
      for (var link = n1.firstlink; link != null; link = link.getNext(n1)) {
        final nextNode = link.getTarget(n1);
        if (nextNode.isHollow()) continue; // border node?
        if (nextNode.firstlink == null) continue; // don't care about dead ends
        if (identical(nextNode, n1)) continue; // ?
        if (!identical(nextNode, n2)) continue; // just that link

        wp.radius = 1.5;
        final testPath = routingContext.createPath(startPath, link, null, _guideTrack != null);
        testPath.airdistance = endPos == null ? 0 : nextNode.calcDistance(endPos);
        if (wp.radius < minradius) {
          bestPath = testPath;
          minradius = wp.radius;
          bestLink = link;
        }
      }
      if (bestLink != null) bestLink.addLinkHolder(bestPath!, n1);
      if (bestPath != null) bestPath.treedepth = 1;
      return bestPath;
    } finally {
      routingContext.unsetWaypoint();
    }
  }

  OsmTrack? _findTrack(
    String operationName,
    MatchedWaypoint startWp,
    MatchedWaypoint? endWp,
    OsmTrack? costCuttingTrack,
    OsmTrack? refTrack,
    bool fastPartialRecalc,
  ) {
    try {
      final wpts2 = <OsmNode>[];
      wpts2.add(startWp.waypoint!);
      if (endWp != null) wpts2.add(endWp.waypoint!);
      routingContext.cleanNogoList(wpts2);

      final detailed = _guideTrack != null;
      _resetCache(detailed);
      _nodesCache!.nodesMap.cleanupMode = detailed ? 0 : (routingContext.considerTurnRestrictions ? 2 : 1);
      return _findTrackInner(operationName, startWp, endWp, costCuttingTrack, refTrack, fastPartialRecalc);
    } finally {
      routingContext.restoreNogoList();
      _nodesCache!.clean(false); // clean only non-virgin caches
    }
  }

  OsmTrack? _findTrackInner(
    String operationName,
    MatchedWaypoint startWp,
    MatchedWaypoint? endWp,
    OsmTrack? costCuttingTrack,
    OsmTrack? refTrack,
    bool fastPartialRecalc,
  ) {
    final cache = _nodesCache!;
    final verbose = _guideTrack != null;

    var maxTotalCost = _guideTrack != null ? _guideTrack!.cost + 5000 : 1000000000;
    var firstMatchCost = 1000000000;

    _matchPath = null;
    var nodesVisited = 0;

    final startNodeId1 = startWp.node1!.getIdFromPos();
    final startNodeId2 = startWp.node2!.getIdFromPos();
    final endNodeId1 = endWp == null ? -1 : endWp.node1!.getIdFromPos();
    final endNodeId2 = endWp == null ? -1 : endWp.node2!.getIdFromPos();
    OsmNode? end1;
    OsmNode? end2;
    OsmNodeNamed? endPos;

    var sameSegmentSearch = false;
    final start1 = cache.getGraphNode(startWp.node1!);
    final start2 = cache.getGraphNode(startWp.node2!);
    if (endWp != null) {
      end1 = cache.getGraphNode(endWp.node1!);
      end2 = cache.getGraphNode(endWp.node2!);
      cache.nodesMap.endNode1 = end1;
      cache.nodesMap.endNode2 = end2;
      endPos = OsmNodeNamed.of(endWp.crosspoint!);
      sameSegmentSearch =
          (identical(start1, end1) && identical(start2, end2)) || (identical(start1, end2) && identical(start2, end1));
    }
    if (!cache.obtainNonHollowNode(start1)) return null;
    cache.expandHollowLinkTargets(start1);
    if (!cache.obtainNonHollowNode(start2)) return null;
    cache.expandHollowLinkTargets(start2);

    routingContext.startDirectionValid = routingContext.forceUseStartDirection || fastPartialRecalc;
    routingContext.startDirectionValid &= routingContext.startDirection != null && !routingContext.inverseDirection;

    final startPath1 = _getStartPathFor(start1, start2, startWp, endPos, sameSegmentSearch);
    final startPath2 = _getStartPathFor(start2, start1, startWp, endPos, sameSegmentSearch);

    // check for an INITIAL match with the cost-cutting-track
    if (costCuttingTrack != null) {
      final pe1 = costCuttingTrack.getLink(startNodeId1, startNodeId2);
      if (pe1 != null) {
        var c = startPath1!.cost - pe1.cost;
        if (c < 0) c = 0;
        if (c < firstMatchCost) firstMatchCost = c;
      }
      final pe2 = costCuttingTrack.getLink(startNodeId2, startNodeId1);
      if (pe2 != null) {
        var c = startPath2!.cost - pe2.cost;
        if (c < 0) c = 0;
        if (c < firstMatchCost) firstMatchCost = c;
      }
    }

    if (startPath1 == null) return null;
    if (startPath2 == null) return null;

    _openSet.clear();
    _addToOpenset(startPath1);
    _addToOpenset(startPath2);
    final openBorderList = <OsmPath>[];
    var memoryPanicMode = false;
    var needNonPanicProcessing = false;

    for (;;) {
      if (_terminated) throw ArgumentError('operation killed by thread-priority-watchdog');

      if (_maxRunningTime > 0) {
        final timeout = (_matchPath == null && fastPartialRecalc) ? _maxRunningTime ~/ 3 : _maxRunningTime;
        if (_clock() - _startTime > timeout) {
          throw ArgumentError('$operationName timeout after ${timeout ~/ 1000} seconds');
        }
      }

      final path = _openSet.popLowestKeyValue();
      if (path == null) {
        if (openBorderList.isEmpty) break;
        for (final p in openBorderList) {
          _openSet.add(i32(p.cost + d2i(p.airdistance * _airDistanceCostFactor)), p);
        }
        openBorderList.clear();
        memoryPanicMode = false;
        needNonPanicProcessing = true;
        continue;
      }

      if (path.airdistance == -1) continue;

      if (_directWeaving && cache.hasHollowLinkTargets(path.getTargetNode())) {
        if (!memoryPanicMode) {
          if (!cache.nodesMap.isInMemoryBounds(_openSet.getSize(), false)) {
            cache.nodesMap.collectOutreachers();
            for (;;) {
              final p3 = _openSet.popLowestKeyValue();
              if (p3 == null) break;
              if (p3.airdistance != -1 && cache.nodesMap.canEscape(p3.getTargetNode())) openBorderList.add(p3);
            }
            cache.nodesMap.clearTemp();
            for (final p in openBorderList) {
              _openSet.add(i32(p.cost + d2i(p.airdistance * _airDistanceCostFactor)), p);
            }
            openBorderList.clear();
            if (!cache.nodesMap.isInMemoryBounds(_openSet.getSize(), true)) {
              if (maxTotalCost < 1000000000 || needNonPanicProcessing || fastPartialRecalc) {
                throw ArgumentError('memory limit reached');
              }
              memoryPanicMode = true;
            }
          }
        }
        if (memoryPanicMode) {
          openBorderList.add(path);
          continue;
        }
      }
      needNonPanicProcessing = false;

      if (_nodeLimit > 0) {
        // check node-limit for target island search
        if (--_nodeLimit == 0) return null;
      }

      nodesVisited++;
      _linksProcessed++;

      final currentLink = path.getLink()!;
      final sourceNode = path.getSourceNode()!;
      final currentNode = path.getTargetNode();

      if (currentLink.isLinkUnused()) continue;

      final currentNodeId = currentNode.getIdFromPos();
      final sourceNodeId = sourceNode.getIdFromPos();

      if (!path.didEnterDestinationArea()) _islandNodePairs.addTempPair(sourceNodeId, currentNodeId);

      if (path.treedepth != 1) {
        if (path.treedepth == 0) {
          // hack: sameSegment Paths marked treedepth=0 to pass above check
          path.treedepth = 1;
        }

        if ((sourceNodeId == endNodeId1 && currentNodeId == endNodeId2) ||
            (sourceNodeId == endNodeId2 && currentNodeId == endNodeId1)) {
          // track found, compile
          final t = _compileTrack(path, verbose);
          t.showspeed = routingContext.showspeed;
          t.showSpeedProfile = routingContext.showSpeedProfile;
          return t;
        }

        // check for a match with the cost-cutting-track
        if (costCuttingTrack != null) {
          final pe = costCuttingTrack.getLink(sourceNodeId, currentNodeId);
          if (pe != null) {
            // remember first match cost for fast termination of partial recalcs
            var parentcost = path.originElement == null ? 0 : path.originElement!.cost;

            // hitting start-element of costCuttingTrack?
            final c = path.cost - parentcost - pe.cost;
            if (c > 0) parentcost += c;

            if (parentcost < firstMatchCost) firstMatchCost = parentcost;

            final costEstimate = path.cost + path.elevationCorrection() + (costCuttingTrack.cost - pe.cost);
            if (costEstimate <= maxTotalCost) _matchPath = OsmPathElement.createFrom(path);
            if (costEstimate < maxTotalCost) maxTotalCost = costEstimate;
          }
        }
      }

      final firstLinkHolder = currentLink.getFirstLinkHolder(sourceNode);
      for (var linkHolder = firstLinkHolder; linkHolder != null; linkHolder = linkHolder.getNextForLink()) {
        (linkHolder as OsmPath).airdistance = -1; // invalidate the entry in the open set;
      }

      if (path.treedepth > 1) {
        final isBidir = currentLink.isBidirectional();
        sourceNode.unlinkLink(currentLink);

        // if the counterlink is alive and does not yet have a path, remove it
        if (isBidir &&
            currentLink.getFirstLinkHolder(currentNode) == null &&
            !routingContext.considerTurnRestrictions) {
          currentNode.unlinkLink(currentLink);
        }
      }

      // recheck cutoff before doing expensive stuff
      const addDiff = 100;
      if (path.cost + path.airdistance > maxTotalCost + addDiff) continue;

      cache.nodesMap.currentMaxCost = maxTotalCost;
      cache.nodesMap.currentPathCost = path.cost;
      cache.nodesMap.destination = endPos;

      // Java builds the pre-paths here; StdModel has none, but the loop
      // still loads the neighbours, which the search depends on.
      for (var link = currentNode.firstlink; link != null; link = link.getNext(currentNode)) {
        final nextNode = link.getTarget(currentNode);
        if (!cache.obtainNonHollowNode(nextNode)) continue; // border node?
        if (nextNode.firstlink == null) continue; // don't care about dead ends
        if (identical(nextNode, sourceNode)) continue; // border node?
      }

      for (var link = currentNode.firstlink; link != null; link = link.getNext(currentNode)) {
        final nextNode = link.getTarget(currentNode);

        if (!cache.obtainNonHollowNode(nextNode)) continue; // border node?
        if (nextNode.firstlink == null) continue; // don't care about dead ends
        if (identical(nextNode, sourceNode)) continue; // border node?

        if (_guideTrack != null) {
          final gidx = path.treedepth + 1;
          if (gidx >= _guideTrack!.nodes.length) continue;
          final guideNode =
              _guideTrack!.nodes[routingContext.inverseRouting ? _guideTrack!.nodes.length - 1 - gidx : gidx];
          final nextId = nextNode.getIdFromPos();
          if (nextId != guideNode.getIdFromPos()) {
            // not along the guide-track, discard, but register for voice
            // hint processing (turnInstructionMode > 0, not ported)
            if (routingContext.turnInstructionMode > 0) {
              throw UnsupportedError('turnInstructionMode > 0 is not ported');
            }
            continue;
          }
        }

        OsmPath? bestPath;

        var isFinalLink = false;
        final targetNodeId = nextNode.getIdFromPos();
        if (currentNodeId == endNodeId1 || currentNodeId == endNodeId2) {
          if (targetNodeId == endNodeId1 || targetNodeId == endNodeId2) isFinalLink = true;
        }

        for (var linkHolder = firstLinkHolder; linkHolder != null; linkHolder = linkHolder.getNextForLink()) {
          final otherPath = linkHolder as OsmPath;
          try {
            if (isFinalLink) {
              endPos!.radius = 1.5; // 1.5 meters is the upper limit that will not change the unit-test result..
              routingContext.setWaypoint(endPos, true);
            }
            final testPath = routingContext.createPath(otherPath, link, refTrack, _guideTrack != null);
            if (testPath.cost >= 0 &&
                (bestPath == null || testPath.cost < bestPath.cost) &&
                (testPath.sourceNode!.getIdFromPos() != testPath.targetNode!.getIdFromPos())) {
              bestPath = testPath;
            }
          } finally {
            if (isFinalLink) routingContext.unsetWaypoint();
          }
        }
        if (bestPath != null) {
          bestPath.airdistance = isFinalLink ? 0 : nextNode.calcDistance(endPos!);

          if (isFinalLink ||
              bestPath.cost + bestPath.airdistance <=
                  (_lastAirDistanceCostFactor != 0.0 ? maxTotalCost * _lastAirDistanceCostFactor : maxTotalCost) +
                      addDiff) {
            // add only if this may beat an existing path for that link
            var dominator = link.getFirstLinkHolder(currentNode);
            while (dominator != null) {
              final dp = dominator as OsmPath;
              if (dp.airdistance != -1 && bestPath.definitlyWorseThan(dp)) break;
              dominator = dominator.getNextForLink();
            }

            if (dominator == null) {
              bestPath.treedepth = path.treedepth + 1;
              link.addLinkHolder(bestPath, currentNode);
              _addToOpenset(bestPath);
            }
          }
        }
      }
    }

    if (nodesVisited < _maxnodesIslandCheck && _islandNodePairs.getFreezeCount() < 5) {
      throw RoutingIslandException();
    }

    return null;
  }

  void _addToOpenset(OsmPath path) {
    if (path.cost >= 0) {
      _openSet.add(i32(path.cost + d2i(path.airdistance * _airDistanceCostFactor)), path);
    }
  }

  OsmTrack _compileTrack(OsmPath path, bool verbose) {
    OsmPathElement? element = OsmPathElement.createFrom(path);

    // for final track, cut endnode
    if (_guideTrack != null && element.origin != null) element = element.origin;

    final totalTime = element!.getTime();
    final totalEnergy = element.getEnergy();

    final track = OsmTrack();
    track.cost = path.cost;
    track.energy = d2i(path.getTotalEnergy());

    var distance = 0;

    while (element != null) {
      if (_guideTrack != null && element.message == null) element.message = MessageData();
      final nextElement = element.origin;
      // ignore double element
      if (nextElement != null && nextElement.positionEquals(element)) {
        element = nextElement;
        continue;
      }
      if (routingContext.inverseRouting) {
        element.setTime(totalTime - element.getTime());
        element.setEnergy(totalEnergy - element.getEnergy());
        track.nodes.add(element);
      } else {
        track.nodes.insert(0, element);
      }

      if (nextElement != null) distance += element.calcDistance(nextElement);
      element = nextElement;
    }
    track.distance = distance;
    track.buildMap();
    return track;
  }

  OsmTrack _mergeTrack(OsmPathElement match, OsmTrack oldTrack) {
    OsmPathElement? element = match;
    final track = OsmTrack();
    track.cost = oldTrack.cost;

    while (element != null) {
      track.addNode(element);
      element = element.origin;
    }
    var lastId = 0;
    final id1 = match.getIdFromPos();
    final id0 = match.origin == null ? 0 : match.origin!.getIdFromPos();
    var appending = false;
    for (final n in oldTrack.nodes) {
      if (appending) track.nodes.add(n);
      final id = n.getIdFromPos();
      if (id == id1 && lastId == id0) appending = true;
      lastId = id;
    }
    track.buildMap();
    return track;
  }

  bool isFinished() => _finished;
  int getLinksProcessed() => _linksProcessed;
  OsmTrack? getFoundTrack() => _foundTrack;
  int getAlternativeIndex() => _alternativeIndex;
  OsmTrack? getFoundRawTrack() => _foundRawTrack;
  String? getErrorMessage() => _errorMessage;
  void terminate() => _terminated = true;
}
