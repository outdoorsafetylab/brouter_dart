// Port of btools.mapaccess.OsmPos (BRouter v1.7.10, MIT).

/// A position: an OsmNode or an OsmPath.
abstract interface class OsmPos {
  int getILat();

  int getILon();

  int getSElev();

  double getElev();

  int calcDistance(OsmPos p);

  int getIdFromPos();
}
