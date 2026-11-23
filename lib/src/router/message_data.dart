// Port of btools.router.MessageData (BRouter v1.7.10, MIT): what one path
// section records in detail mode. Only the fields the path search and the
// track totals read are kept; the per-section text output is not ported.
part of 'router.dart';

class MessageData {
  int linkdist = 0;
  int linkelevationcost = 0;
  int linkturncost = 0;
  int linknodecost = 0;
  int linkinitcost = 0;

  double costfactor = 0; // Java float
  int priorityclassifier = 0;
  int classifiermask = 0;
  double turnangle = 0; // Java float
  String? wayKeyValues;
  String? nodeKeyValues;

  int lon = 0;
  int lat = 0;
  int ele = 0; // Java short

  double time = 0; // Java float
  double energy = 0; // Java float
}
