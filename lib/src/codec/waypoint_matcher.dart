// Port of btools.codec.WaypointMatcher (BRouter v1.7.10, MIT).

/// Gets way geometries from the decoder to find the closest matches to the
/// waypoints.
abstract interface class WaypointMatcher {
  bool start(int ilonStart, int ilatStart, int ilonTarget, int ilatTarget, bool useAsStartWay);

  void transferNode(int ilon, int ilat);

  void end();

  bool hasMatch(int lon, int lat);
}
