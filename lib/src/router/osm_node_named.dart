// Port of btools.router.OsmNodeNamed (BRouter v1.7.10, MIT).
part of 'router.dart';

/// A waypoint or a nogo circle. While a section is searched, the engine also
/// puts its target here, with [isNogo] false, to find where the path reaches
/// it (RoutingContext.setWaypoint).
class OsmNodeNamed extends OsmNode {
  String? name;
  double radius = 0; // metres
  double nogoWeight = 0;
  bool isNogo = false;
  int wpttype = MatchedWaypoint.waypointTypeShaping;

  OsmNodeNamed() : super.empty();

  OsmNodeNamed.of(OsmNode n) : super(n.ilon, n.ilat);

  @override
  String toString() => nogoWeight.isNaN ? '$ilon,$ilat,$name' : '$ilon,$ilat,$name,$nogoWeight';

  double distanceWithinRadius(int lon1, int lat1, int lon2, int lat2, double totalSegmentLength) {
    final lonlat2m = CheapRuler.getLonLatToMeterScales((lat1 + lat2) >> 1);
    var isFirstPointWithinCircle = CheapRuler.distance(lon1, lat1, ilon, ilat) < radius;
    var isLastPointWithinCircle = CheapRuler.distance(lon2, lat2, ilon, ilat) < radius;
    if (isFirstPointWithinCircle) {
      if (isLastPointWithinCircle) return totalSegmentLength;
      var tmp = lon2;
      lon2 = lon1;
      lon1 = tmp;
      tmp = lat2;
      lat2 = lat1;
      lat1 = tmp;
      isLastPointWithinCircle = isFirstPointWithinCircle;
      isFirstPointWithinCircle = false;
    }
    final initialToProject =
        ((lon2 - lon1) * (ilon - lon1) * lonlat2m[0] * lonlat2m[0] +
            (lat2 - lat1) * (ilat - lat1) * lonlat2m[1] * lonlat2m[1]) /
        totalSegmentLength;
    final initialToCenter = CheapRuler.distance(ilon, ilat, lon1, lat1);
    final halfDistanceWithin = math.sqrt(
      radius * radius - (initialToCenter * initialToCenter - initialToProject * initialToProject),
    );
    if (isLastPointWithinCircle) {
      return halfDistanceWithin + (totalSegmentLength - initialToProject);
    }
    return 2 * halfDistanceWithin;
  }
}
