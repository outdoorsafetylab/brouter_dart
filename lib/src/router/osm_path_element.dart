// Port of btools.router.OsmPathElement (BRouter v1.7.10, MIT).
part of 'router.dart';

/// One point of a found track, linked back to where it came from.
class OsmPathElement implements OsmPos {
  int _ilat = 0;
  int _ilon = 0;
  int _selev = 0; // Java short
  MessageData? message;
  int cost = 0;
  OsmPathElement? origin;

  OsmPathElement._();

  @override
  int getILat() => _ilat;
  @override
  int getILon() => _ilon;
  @override
  int getSElev() => _selev;
  void setSElev(int s) => _selev = i16(s);
  @override
  double getElev() => _selev / 4.0;

  /// Java float.
  double getTime() => message == null ? 0.0 : message!.time;
  void setTime(double t) {
    if (message != null) message!.time = fround(t);
  }

  /// Java float.
  double getEnergy() => message == null ? 0.0 : message!.energy;
  void setEnergy(double e) {
    if (message != null) message!.energy = fround(e);
  }

  void setAngle(double e) {
    if (message != null) message!.turnangle = fround(e);
  }

  @override
  int getIdFromPos() => (_ilon << 32) | _ilat;

  @override
  int calcDistance(OsmPos p) =>
      math.max(1.0, _javaRound(CheapRuler.distance(_ilon, _ilat, p.getILon(), p.getILat())).toDouble()).toInt();

  static OsmPathElement createFrom(OsmPath path) {
    final n = path.getTargetNode();
    final pe = create(n.getILon(), n.getILat(), n.getSElev(), path.originElement);
    pe.cost = path.cost;
    pe.message = path.message;
    return pe;
  }

  static OsmPathElement create(int ilon, int ilat, int selev, OsmPathElement? origin) {
    final pe = OsmPathElement._();
    pe._ilon = ilon;
    pe._ilat = ilat;
    pe._selev = i16(selev);
    pe.origin = origin;
    return pe;
  }

  @override
  String toString() => '${_ilon}_$_ilat';

  bool positionEquals(OsmPathElement e) => _ilat == e._ilat && _ilon == e._ilon;
}
