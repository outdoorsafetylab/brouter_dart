// Port of btools.router.StdPath (BRouter v1.7.10, MIT): the cost model of
// the default StdModel. Java float arithmetic is rounded step by step with
// fround (`docs/design.md` D4); Java compound assignments on int narrow the float or
// double result with d2i, as Java does.
part of 'router.dart';

final class StdPath extends OsmPath {
  // The elevation-hysteresis-buffer (http://www.brouter.de/elevation.html)
  int _ehbd = 0; // in micrometer
  int _ehbu = 0; // in micrometer

  double _totalTime = 0; // Java float, travel time (seconds)
  double _totalEnergy = 0; // Java float, total route energy (Joule)
  double _elevationBuffer = 0; // Java float, for travel time

  int _uphillcostdiv = 0;
  int _downhillcostdiv = 0;

  static const double _gravity = 9.81;

  @override
  void initState(OsmPath orig) {
    final origin = orig as StdPath;
    _ehbd = origin._ehbd;
    _ehbu = origin._ehbu;
    _totalTime = origin._totalTime;
    _totalEnergy = origin._totalEnergy;
    _elevationBuffer = origin._elevationBuffer;
  }

  @override
  void resetState() {
    _ehbd = 0;
    _ehbu = 0;
    _totalTime = 0;
    _totalEnergy = 0;
    _uphillcostdiv = 0;
    _downhillcostdiv = 0;
    _elevationBuffer = 0;
  }

  // Java: float * int, float / int and the like, as float.
  static double _f(double x) => fround(x);

  // Java's implicit int to float conversion, which rounds above 2^24.
  static double _fi(int x) => fround(x.toDouble());

  @override
  double processWaySection(RoutingContext rc, double distance, double deltaH, double elevation, double angle,
      double cosangle, bool isStartpoint, int nsection, int lastpriorityclassifier) {
    final w = rc.expctxWay!;
    // calculate the costfactor inputs
    final turncostbase = w.getTurncost();
    final uphillcutoff = _f(w.getUphillcutoff() * 10000);
    final downhillcutoff = _f(w.getDownhillcutoff() * 10000);
    final uphillmaxslope = _f(w.getUphillmaxslope() * 10000);
    final downhillmaxslope = _f(w.getDownhillmaxslope() * 10000);
    var cfup = w.getUphillCostfactor();
    var cfdown = w.getDownhillCostfactor();
    final cf = w.getCostfactor();
    cfup = cfup == 0.0 ? cf : cfup;
    cfdown = cfdown == 0.0 ? cf : cfdown;

    _downhillcostdiv = d2i(w.getDownhillcost());
    if (_downhillcostdiv > 0) _downhillcostdiv = 1000000 ~/ _downhillcostdiv;

    var downhillmaxslopecostdiv = d2i(w.getDownhillmaxslopecost());
    if (downhillmaxslopecostdiv > 0) {
      downhillmaxslopecostdiv = 1000000 ~/ downhillmaxslopecostdiv;
    } else {
      // if not given, use legacy behavior
      downhillmaxslopecostdiv = _downhillcostdiv;
    }

    _uphillcostdiv = d2i(w.getUphillcost());
    if (_uphillcostdiv > 0) _uphillcostdiv = 1000000 ~/ _uphillcostdiv;

    var uphillmaxslopecostdiv = d2i(w.getUphillmaxslopecost());
    if (uphillmaxslopecostdiv > 0) {
      uphillmaxslopecostdiv = 1000000 ~/ uphillmaxslopecostdiv;
    } else {
      // if not given, use legacy behavior
      uphillmaxslopecostdiv = _uphillcostdiv;
    }

    final dist = d2i(distance); // legacy arithmetics needs int

    // penalty for turning angle
    var turncost = d2i((1.0 - cosangle) * turncostbase + 0.2); // e.g. turncost=90 -> 90 degree = 90m penalty
    final newPrio = d2i(w.getPriorityClassifier());
    final oldPrio = lastpriorityclassifier;
    if (rc.bikeMode) {
      if (rc.considerCrossing &&
          oldPrio > 0 &&
          nsection == 0 &&
          oldPrio >= rc.crossingPrioH &&
          newPrio <= rc.crossingPrioL) {
        if (angle < 0) turncost += _crossingCost(rc, rc.costToLeftFromH);
        if (angle > 0) turncost += _crossingCost(rc, rc.costToRightFromH);
      }
    }

    if (message != null) {
      message!.linkturncost += turncost;
      message!.turnangle = fround(angle);
    }

    var sectionCost = turncost.toDouble();

    // *** penalty for elevation
    // only the part of the descend that does not fit into the elevation-hysteresis-buffers
    // leads to an immediate penalty

    final deltaHMicros = d2i(1000000.0 * deltaH);
    // Java: ehbd += -delta_h_micros - dist * downhillcutoff, all in float
    _ehbd = d2i(_f(_fi(_ehbd) + _f(_fi(i32(-deltaHMicros)) - _f(_fi(dist) * downhillcutoff))));
    _ehbu = d2i(_f(_fi(_ehbu) + _f(_fi(deltaHMicros) - _f(_fi(dist) * uphillcutoff))));

    var downweight = 0.0;
    if (_ehbd > rc.elevationpenaltybuffer) {
      downweight = 1.0;

      var excess = i32(_ehbd - rc.elevationpenaltybuffer);
      var reduce = i32(dist * rc.elevationbufferreduce);
      if (reduce > excess) {
        downweight = _f(_fi(excess) / _fi(reduce));
        reduce = excess;
      }
      excess = i32(_ehbd - rc.elevationmaxbuffer);
      if (reduce < excess) reduce = excess;
      _ehbd = i32(_ehbd - reduce);
      var elevationCost = 0.0;
      if (_downhillcostdiv > 0) {
        elevationCost = _f(elevationCost + _f(_fmin(_fi(reduce), _f(_fi(dist) * downhillmaxslope)) / _fi(_downhillcostdiv)));
      }
      if (downhillmaxslopecostdiv > 0) {
        elevationCost = _f(elevationCost +
            _f(_fmax(0.0, _f(_fi(reduce) - _f(_fi(dist) * downhillmaxslope))) / _fi(downhillmaxslopecostdiv)));
      }
      if (elevationCost > 0) {
        sectionCost += elevationCost;
        if (message != null) {
          message!.linkelevationcost = d2i(_f(_fi(message!.linkelevationcost) + elevationCost));
        }
      }
    } else if (_ehbd < 0) {
      _ehbd = 0;
    }

    var upweight = 0.0;
    if (_ehbu > rc.elevationpenaltybuffer) {
      upweight = 1.0;

      var excess = i32(_ehbu - rc.elevationpenaltybuffer);
      var reduce = i32(dist * rc.elevationbufferreduce);
      if (reduce > excess) {
        upweight = _f(_fi(excess) / _fi(reduce));
        reduce = excess;
      }
      excess = i32(_ehbu - rc.elevationmaxbuffer);
      if (reduce < excess) reduce = excess;
      _ehbu = i32(_ehbu - reduce);
      var elevationCost = 0.0;
      if (_uphillcostdiv > 0) {
        elevationCost = _f(elevationCost + _f(_fmin(_fi(reduce), _f(_fi(dist) * uphillmaxslope)) / _fi(_uphillcostdiv)));
      }
      if (uphillmaxslopecostdiv > 0) {
        elevationCost = _f(elevationCost +
            _f(_fmax(0.0, _f(_fi(reduce) - _f(_fi(dist) * uphillmaxslope))) / _fi(uphillmaxslopecostdiv)));
      }
      if (elevationCost > 0) {
        sectionCost += elevationCost;
        if (message != null) {
          message!.linkelevationcost = d2i(_f(_fi(message!.linkelevationcost) + elevationCost));
        }
      }
    } else if (_ehbu < 0) {
      _ehbu = 0;
    }

    // get the effective costfactor (slope dependent)
    // cfup * upweight + cf * (1.f - upweight - downweight) + cfdown * downweight, in float
    final costfactor =
        _f(_f(_f(cfup * upweight) + _f(cf * _f(_f(1.0 - upweight) - downweight))) + _f(cfdown * downweight));

    if (message != null) message!.costfactor = costfactor;

    sectionCost += _f(_f(_fi(dist) * costfactor) + 0.5);

    return sectionCost;
  }

  // Java Math.min/Math.max on floats: NaN wins, and -0.0 is below 0.0.
  static double _fmin(double a, double b) => math.min(a, b);
  static double _fmax(double a, double b) => math.max(a, b);

  // The extra turn cost at a crossing, by the node's estimated crossing
  // class (bike profiles only).
  int _crossingCost(RoutingContext rc, List<int> costByClass) {
    final desc = sourceNode!.nodeDescription;
    if (desc == null) return 0;
    final nodeAccessGranted = rc.expctxWay!.getNodeAccessGranted() != 0.0;
    final nodeTags = rc.expctxNode!.getKeyValueDescription(nodeAccessGranted, desc);
    final classIndex = nodeTags.indexOf('estimated_crossing_class=');
    if (classIndex < 0) return 0;
    final crossingClass = nodeTags.substring(classIndex + 25, classIndex + 26);
    final c = int.tryParse(crossingClass);
    return c != null && c >= 1 && c <= 6 ? costByClass[c - 1] : 0;
  }

  @override
  double processTargetNode(RoutingContext rc) {
    final desc = targetNode!.nodeDescription;
    // finally add node-costs for target node
    if (desc != null) {
      final nodeAccessGranted = rc.expctxWay!.getNodeAccessGranted() != 0.0;
      final n = rc.expctxNode!;
      n.evaluate(nodeAccessGranted, desc);
      final initialcost = n.getInitialcost();
      if (initialcost >= 1000000.0) return -1.0;
      if (message != null) {
        message!.linknodecost += d2i(initialcost);
        message!.nodeKeyValues = n.getKeyValueDescription(nodeAccessGranted, desc);
      }
      return initialcost;
    }
    return 0.0;
  }

  @override
  int elevationCorrection() =>
      (_downhillcostdiv > 0 ? _ehbd ~/ _downhillcostdiv : 0) + (_uphillcostdiv > 0 ? _ehbu ~/ _uphillcostdiv : 0);

  @override
  bool definitlyWorseThan(OsmPath path) {
    final p = path as StdPath;
    var c = p.cost;
    if (p._downhillcostdiv > 0) {
      final delta = p._ehbd ~/ p._downhillcostdiv - (_downhillcostdiv > 0 ? _ehbd ~/ _downhillcostdiv : 0);
      if (delta > 0) c += delta;
    }
    if (p._uphillcostdiv > 0) {
      final delta = p._ehbu ~/ p._uphillcostdiv - (_uphillcostdiv > 0 ? _ehbu ~/ _uphillcostdiv : 0);
      if (delta > 0) c += delta;
    }
    return cost > c;
  }

  double _calcIncline(double dist) {
    const minDelta = 3.0;
    var shift = 0.0;
    if (_elevationBuffer > minDelta) {
      shift = -minDelta;
    } else if (_elevationBuffer < -minDelta) {
      shift = minDelta;
    }
    final decayFactor = fdlibm.exp(-dist / 100.0);
    final newElevationBuffer = fround((_elevationBuffer + shift) * decayFactor - shift);
    final incline = _f(_elevationBuffer - newElevationBuffer) / dist;
    _elevationBuffer = newElevationBuffer;
    return incline;
  }

  @override
  void computeKinematic(RoutingContext rc, double dist, double deltaH, bool detailMode) {
    if (!detailMode) return;

    // compute incline
    _elevationBuffer = _f(_elevationBuffer + deltaH);
    final incline = _calcIncline(dist);

    var maxSpeed = rc.maxSpeed;
    final speedLimit = _f(rc.expctxWay!.getMaxspeed() / fround(3.6));
    if (speedLimit > 0) maxSpeed = math.min(maxSpeed, speedLimit);

    var speed = maxSpeed; // Travel speed
    final fRoll = rc.totalMass * _gravity * (rc.defaultCr + incline);
    if (rc.footMode) {
      // Use Tobler's hiking function for walking sections
      speed = rc.maxSpeed * fdlibm.exp(-3.5 * (incline + 0.05).abs());
    } else if (rc.bikeMode) {
      speed = _solveCubic(rc.sCx, fRoll, rc.bikerPower);
      speed = math.min(speed, maxSpeed);
    }
    final dt = _f(dist / speed);
    _totalTime = _f(_totalTime + dt);
    // Calc energy assuming biking (no good model yet for hiking)
    // (Count only positive, negative would mean breaking to enforce
    // maxspeed)
    final energy = dist * (rc.sCx * speed * speed + fRoll);
    if (energy > 0.0) _totalEnergy = _f(_totalEnergy + energy);
  }

  static double _solveCubic(double a, double c, double d) {
    // Solves a * v^3 + c * v = d with a Newton method
    // to get the speed v for the section.
    var v = 8.0;
    var findingStartvalue = true;
    for (var i = 0; i < 10; i++) {
      final y = (a * v * v + c) * v - d;
      if (y < .1) {
        if (findingStartvalue) {
          v *= 2.0;
          continue;
        }
        break;
      }
      findingStartvalue = false;
      final yPrime = 3 * a * v * v + c;
      v -= y / yPrime;
    }
    return v;
  }

  @override
  double getTotalTime() => _totalTime;

  @override
  double getTotalEnergy() => _totalEnergy;
}
