// Port of btools.mapaccess.OsmTransferNode (BRouter v1.7.10, MIT).

/// An intermediate point of a link's geometry.
class OsmTransferNode {
  OsmTransferNode? next;

  int ilon = 0;
  int ilat = 0;
  int selev = 0; // Java short
}
