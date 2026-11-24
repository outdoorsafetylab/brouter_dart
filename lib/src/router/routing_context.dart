// Port of btools.router.RoutingContext (BRouter v1.7.10, MIT). Global
// profile variables are Java floats: their defaults are rounded with fround
// and float arithmetic on them is rounded too (`docs/design.md` D4).
part of 'router.dart';

class RoutingContext {
  int alternativeIdx = 0;

  void setAlternativeIdx(int idx) => alternativeIdx = idx;

  int getAlternativeIdx(int min, int max) => alternativeIdx < min ? min : (alternativeIdx > max ? max : alternativeIdx);

  /// Path of the .brf profile.
  String? localFunction;
  Map<String, String>? keyValues;

  String getProfileName() {
    var name = localFunction ?? 'unknown';
    if (name.endsWith('.brf')) name = name.substring(0, name.length - 4);
    final idx = name.lastIndexOf(Platform.pathSeparator);
    if (idx >= 0) name = name.substring(idx + 1);
    return name;
  }

  BExpressionContextWay? expctxWay;
  BExpressionContextNode? expctxNode;

  GeometryDecoder geometryDecoder = GeometryDecoder();

  int memoryclass = 64;

  bool carMode = false;
  bool bikeMode = false;
  bool footMode = false;
  bool considerTurnRestrictions = false;
  bool processUnusedTags = false;
  bool forceSecondaryData = false;
  double pass1coefficient = 0;
  double pass2coefficient = 0;
  int elevationpenaltybuffer = 0;
  int elevationmaxbuffer = 0;
  int elevationbufferreduce = 0;

  double cost1speed = 0;
  double additionalcostfactor = 0;
  double changetime = 0;
  double buffertime = 0;
  double waittimeadjustment = 0;
  double inittimeadjustment = 0;
  double starttimeoffset = 0;
  bool transitonly = false;

  double waypointCatchingRange = 0;
  bool correctMisplacedViaPoints = false;
  double correctMisplacedViaPointsDistance = 0;
  bool continueStraight = false;
  bool useDynamicDistance = false;
  bool buildBeelineOnRange = false;

  _StdModel? _pm;

  void _setModel(String? className) {
    if (className == null || className == 'btools.router.StdModel') {
      _pm = _StdModel();
    } else {
      throw ArgumentError('Cannot create path-model: $className is not ported');
    }
    initModel();
  }

  void initModel() {}

  // Java getVariableValue(name, float default) on the global context.
  double _g(String name, double defaultValue) => expctxWay!.getVariableValue(name, fround(defaultValue));

  void readGlobalConfig() {
    _setModel(expctxWay!.modelClass);

    carMode = 0.0 != _g('validForCars', 0);
    bikeMode = 0.0 != _g('validForBikes', 0);
    footMode = 0.0 != _g('validForFoot', 0);

    considerCrossing = 0.0 != _g('consider_crossing', 0);
    crossingPrioH = d2i(_g('crossing_Prio_H', 0));
    crossingPrioL = d2i(_g('crossing_Prio_L', 0));
    costToLeftFromH = [for (var c = 1; c <= 6; c++) d2i(_g('cost_ToLeft_from_H_class$c', 0))];
    costToRightFromH = [for (var c = 1; c <= 6; c++) d2i(_g('cost_ToRight_from_H_class$c', 0))];

    waypointCatchingRange = _g('waypointCatchingRange', 250);

    // turn-restrictions not used per default for foot profiles
    considerTurnRestrictions = 0.0 != _g('considerTurnRestrictions', footMode ? 0 : 1);

    correctMisplacedViaPoints = 0.0 != _g('correctMisplacedViaPoints', 0);
    correctMisplacedViaPointsDistance = _g('correctMisplacedViaPointsDistance', 400); // 0 == don't use distance

    continueStraight = 0.0 != _g('continueStraight', 0);

    // process tags not used in the profile (to have them in the data-tab)
    processUnusedTags = 0.0 != _g('processUnusedTags', 0);

    forceSecondaryData = 0.0 != _g('forceSecondaryData', 0);
    pass1coefficient = _g('pass1coefficient', 1.5);
    pass2coefficient = _g('pass2coefficient', 0);
    // Java: (int) (float * int), the product in float
    elevationpenaltybuffer = d2i(fround(_g('elevationpenaltybuffer', 5) * 1000000));
    elevationmaxbuffer = d2i(fround(_g('elevationmaxbuffer', 10) * 1000000));
    elevationbufferreduce = d2i(fround(_g('elevationbufferreduce', 0) * 10000));

    cost1speed = _g('cost1speed', 22);
    additionalcostfactor = _g('additionalcostfactor', 1.5);
    changetime = _g('changetime', 180);
    buffertime = _g('buffertime', 120);
    waittimeadjustment = _g('waittimeadjustment', 0.9);
    inittimeadjustment = _g('inittimeadjustment', 0.2);
    starttimeoffset = _g('starttimeoffset', 0);
    transitonly = _g('transitonly', 0) != 0.0;

    showspeed = 0.0 != _g('showspeed', 0);
    showSpeedProfile = 0.0 != _g('showSpeedProfile', 0);
    inverseRouting = 0.0 != _g('inverseRouting', 0);
    showTime = 0.0 != _g('showtime', 0);

    final tiMode = d2i(_g('turnInstructionMode', 0));
    if (tiMode != 1) turnInstructionMode = tiMode;
    turnInstructionCatchingRange = _g('turnInstructionCatchingRange', 40);
    turnInstructionRoundabouts = _g('turnInstructionRoundabouts', footMode ? 0 : 1) != 0.0;

    // Speed computation model (for bikes)
    // Total mass (biker + bike + luggages or hiker), in kg
    totalMass = _g('totalMass', 90);
    // Max speed (before braking), in km/h in profile and m/s in code
    if (footMode) {
      maxSpeed = _g('maxSpeed', 6) / 3.6;
    } else {
      maxSpeed = _g('maxSpeed', 45) / 3.6;
    }
    // Equivalent surface for wind, S * C_x, F = -1/2 * S * C_x * v^2 = - S_C_x * v^2
    sCx = _g('S_C_x', fround(fround(0.5) * fround(0.45)));
    // Default resistance of the road, F = - m * g * C_r (for good quality road)
    defaultCr = _g('C_r', 0.01);
    // Constant power of the biker (in W)
    bikerPower = _g('bikerPower', 100);

    useDynamicDistance = _g('use_dynamic_range', 1) == 1.0;
    buildBeelineOnRange = _g('add_beeline', 0) == 1.0;

    final test = _g('check_start_way', 1) == 1.0;
    if (!test) freeNoWays();
  }

  void freeNoWays() => expctxWay?.freeNoWays();

  List<OsmNodeNamed>? poipoints;

  List<OsmNodeNamed>? nogopoints;
  List<OsmNodeNamed>? _nogopointsAll; // full list not filtered for wayoints-in-nogos
  List<OsmNodeNamed>? _keepnogopoints;
  OsmNodeNamed? _pendingEndpoint;

  int? startDirection;
  bool startDirectionValid = false;
  bool forceUseStartDirection = false;

  bool allowSamewayback = false;

  CheapAngleMeter anglemeter = CheapAngleMeter();

  double nogoCost = 0.0;
  bool isEndpoint = false;

  bool shortestmatch = false;
  double wayfraction = 0;
  int ilatshortest = 0;
  int ilonshortest = 0;

  bool inverseDirection = false;

  bool showspeed = false;
  bool showSpeedProfile = false;
  bool inverseRouting = false;
  bool showTime = false;
  bool hasDirectRouting = false;

  int turnInstructionMode = 0; // 0=none, 1=auto, 2=locus, 3=osmand, 4=comment-style, 5=gpsies-style
  double turnInstructionCatchingRange = 0;
  bool turnInstructionRoundabouts = false;

  // Speed computation model (for bikes)
  double totalMass = 0;
  double maxSpeed = 0;
  double sCx = 0;
  double defaultCr = 0;
  double bikerPower = 0;

  bool considerCrossing = false; // consider crossing
  int crossingPrioH = 0; // min value to considered a HW as "highprio"
  int crossingPrioL = 0; // max value to considered a HW as "lowprio"
  List<int> costToLeftFromH = List.filled(6, 0);
  List<int> costToRightFromH = List.filled(6, 0);

  /// Restores the full nogolist previously saved by cleanNogoList.
  void restoreNogoList() => nogopoints = _nogopointsAll;

  /// Removes the nogos with a waypoint inside (circles only here).
  void cleanNogoList(List<OsmNode> waypoints) {
    _nogopointsAll = nogopoints;
    if (nogopoints == null) return;
    final nogos = <OsmNodeNamed>[];
    for (final nogo in nogopoints!) {
      var goodGuy = true;
      for (final wp in waypoints) {
        if (wp.calcDistance(nogo) < nogo.radius) goodGuy = false;
      }
      if (goodGuy) nogos.add(nogo);
    }
    nogopoints = nogos.isEmpty ? null : nogos;
  }

  void checkMatchedWaypointAgainstNogos(List<MatchedWaypoint> matchedWaypoints) {
    if (nogopoints == null) return;
    final theSize = matchedWaypoints.length;
    if (theSize < 2) return;
    var removed = 0;
    final newMatchedWaypoints = <MatchedWaypoint>[];
    MatchedWaypoint? prevMwp;
    var prevMwpIsInside = false;
    for (var i = 0; i < theSize; i++) {
      final mwp = matchedWaypoints[i];
      var isInsideNogo = false;
      final wp = mwp.crosspoint!;
      for (final nogo in nogopoints!) {
        if (nogo.nogoWeight.isNaN && wp.calcDistance(nogo) < nogo.radius) {
          isInsideNogo = true;
          break;
        }
      }
      if (isInsideNogo) {
        var useAnyway = false;
        if (prevMwp == null) {
          useAnyway = true;
        } else if (mwp.wpttype == MatchedWaypoint.waypointTypeDirect) {
          useAnyway = true;
        } else if (prevMwp.wpttype == MatchedWaypoint.waypointTypeDirect) {
          useAnyway = true;
        } else if (prevMwpIsInside) {
          useAnyway = true;
        } else if (i == theSize - 1) {
          throw ArgumentError('last wpt in restricted area ');
        }
        if (useAnyway) {
          prevMwpIsInside = true;
          newMatchedWaypoints.add(mwp);
        } else {
          removed++;
          prevMwpIsInside = false;
        }
      } else {
        prevMwpIsInside = false;
        newMatchedWaypoints.add(mwp);
      }
      prevMwp = mwp;
    }
    if (newMatchedWaypoints.length < 2) {
      throw ArgumentError('a wpt in restricted area ');
    }
    if (removed > 0) {
      matchedWaypoints
        ..clear()
        ..addAll(newMatchedWaypoints);
    }
  }

  bool allInOneNogo(List<OsmNode> waypoints) {
    if (nogopoints == null) return false;
    var allInTotal = false;
    for (final nogo in nogopoints!) {
      var allIn = nogo.nogoWeight.isNaN;
      for (final wp in waypoints) {
        final dist = wp.calcDistance(nogo);
        if (dist < nogo.radius) continue;
        allIn = false;
      }
      allInTotal |= allIn;
    }
    return allInTotal;
  }

  void setWaypoint(OsmNodeNamed wp, bool endpoint, [OsmNodeNamed? pendingEndpoint]) {
    _keepnogopoints = nogopoints;
    nogopoints = [wp, ...?_keepnogopoints];
    isEndpoint = endpoint;
    _pendingEndpoint = pendingEndpoint;
  }

  bool checkPendingEndpoint() {
    if (_pendingEndpoint != null) {
      isEndpoint = true;
      nogopoints![0] = _pendingEndpoint!;
      _pendingEndpoint = null;
      return true;
    }
    return false;
  }

  void unsetWaypoint() {
    nogopoints = _keepnogopoints;
    _pendingEndpoint = null;
    isEndpoint = false;
  }

  int calcDistance(int lon1, int lat1, int lon2, int lat2) {
    final lonlat2m = CheapRuler.getLonLatToMeterScales((lat1 + lat2) >> 1);
    final dlon2m = lonlat2m[0];
    final dlat2m = lonlat2m[1];
    var dx = (lon2 - lon1) * dlon2m;
    var dy = (lat2 - lat1) * dlat2m;
    var d = math.sqrt(dy * dy + dx * dx);

    shortestmatch = false;

    final nogos = nogopoints;
    if (nogos != null && nogos.isNotEmpty && d > 0.0) {
      for (var ngidx = 0; ngidx < nogos.length; ngidx++) {
        final nogo = nogos[ngidx];
        final x1 = (lon1 - nogo.ilon) * dlon2m;
        final y1 = (lat1 - nogo.ilat) * dlat2m;
        final x2 = (lon2 - nogo.ilon) * dlon2m;
        final y2 = (lat2 - nogo.ilat) * dlat2m;
        final r12 = x1 * x1 + y1 * y1;
        final r22 = x2 * x2 + y2 * y2;
        var radius = (r12 < r22 ? y1 * dx - x1 * dy : y2 * dx - x2 * dy).abs() / d;

        if (radius < nogo.radius) {
          // 20m
          var s1 = x1 * dx + y1 * dy;
          var s2 = x2 * dx + y2 * dy;

          if (s1 < 0.0) {
            s1 = -s1;
            s2 = -s2;
          }
          if (s2 > 0.0) {
            radius = math.sqrt(s1 < s2 ? r12 : r22);
            if (radius > nogo.radius) continue;
          }
          if (nogo.isNogo) {
            // nogo is a circle
            if (nogo.nogoWeight.isNaN) {
              // default nogo behaviour (ignore completely)
              nogoCost = -1;
            } else {
              // nogo weight, compute distance within the circle
              nogoCost = nogo.distanceWithinRadius(lon1, lat1, lon2, lat2, d) * nogo.nogoWeight;
            }
          } else {
            shortestmatch = true;
            nogo.radius = radius; // shortest distance to way
            // calculate remaining distance
            if (s2 < 0.0) {
              wayfraction = -s2 / (d * d);
              final xm = x2 - wayfraction * dx;
              final ym = y2 - wayfraction * dy;
              ilonshortest = d2i(xm / dlon2m + nogo.ilon);
              ilatshortest = d2i(ym / dlat2m + nogo.ilat);
            } else if (s1 > s2) {
              wayfraction = 0.0;
              ilonshortest = lon2;
              ilatshortest = lat2;
            } else {
              wayfraction = 1.0;
              ilonshortest = lon1;
              ilatshortest = lat1;
            }

            // here it gets nasty: there can be multiple points split
            // the dist between 'start' and 'end' and the calc of
            // the shortest point
            if (isEndpoint) {
              wayfraction = 1.0 - wayfraction;
              lon2 = ilonshortest;
              lat2 = ilatshortest;
            } else {
              nogoCost = 0.0;
              lon1 = ilonshortest;
              lat1 = ilatshortest;
            }
            dx = (lon2 - lon1) * dlon2m;
            dy = (lat2 - lat1) * dlat2m;
            d = math.sqrt(dy * dy + dx * dx);
          }
        }
      }
    }
    return math.max(1.0, _javaRound(d).toDouble()).toInt();
  }

  OsmPath createPathStart(OsmLink link) {
    final p = _pm!.createPath();
    p.initStart(link);
    return p;
  }

  OsmPath createPath(OsmPath origin, OsmLink link, OsmTrack? refTrack, bool detailMode) {
    final p = _pm!.createPath();
    p.initFrom(origin, link, refTrack, detailMode, this);
    return p;
  }
}

/// btools.router.StdModel: no pre-path, StdPath for paths.
final class _StdModel {
  OsmPath createPath() => StdPath();
}

/// The way context as NodesCache wants it (gis's NodesCacheContext): Java
/// hands NodesCache the BExpressionContextWay itself.
final class _WayCacheContext implements NodesCacheContext {
  final BExpressionContextWay _w;
  _WayCacheContext(this._w);

  @override
  int get lookupVersion => _w.meta!.lookupVersion;
  @override
  int get lookupMinorVersion => _w.meta!.lookupMinorVersion;
  @override
  int accessType(Uint8List tagValueSet) => _w.accessType(tagValueSet);
  @override
  Uint8List unify(Uint8List tagValueSet, int offset, int len) => _w.unify(tagValueSet, offset, len);
  @override
  bool isLookupIdxUsed(int idx) => _w.isLookupIdxUsed(idx);
  @override
  void setDecodeForbidden(bool decodeForbidden) => _w.setDecodeForbidden(decodeForbidden);
  @override
  bool checkStartWay(Uint8List? ab) => _w.checkStartWay(ab);
}
