// Port of btools.mapaccess.MatchedWaypoint (BRouter v1.7.10, MIT), without
// writeToStream/readFromStream, which only the area reader uses.
import 'osm_node.dart';

/// A waypoint and where it meets the way network.
class MatchedWaypoint {
  static const int waypointTypeShaping = 1; // route next to this point
  static const int waypointTypeMeeting = 2; // visit this point
  static const int waypointTypeDirect = 3; // from this point go direct to next = beeline routing

  OsmNode? node1;
  OsmNode? node2;
  OsmNode? crosspoint;
  OsmNode? waypoint;
  OsmNode? correctedpoint;
  String? name; // waypoint name used in error messages
  double radius = 0; // distance in meter between waypoint and crosspoint
  int wpttype = waypointTypeShaping;
  int indexInTrack = 0;
  double directionToNext = -1;
  double directionDiff = 361;

  List<MatchedWaypoint> wayNearest = [];
  bool hasUpdate = false;
}
