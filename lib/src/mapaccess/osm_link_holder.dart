// Port of btools.mapaccess.OsmLinkHolder (BRouter v1.7.10, MIT).

abstract interface class OsmLinkHolder {
  void setNextForLink(OsmLinkHolder? holder);

  OsmLinkHolder? getNextForLink();
}
