// Port of the package btools.router (BRouter v1.7.10, MIT): the path search
// and the costs along it. One part file per Java class, so the members Java
// keeps package-private stay private to this library.
//
// Ported for the profiles that use the default StdModel (both reference
// profiles do). Not ported: the kinematic models (KinematicModel,
// KinematicPath, KinematicNoCostModel, KinematicNoCostPath, OsmPrePath), the
// output formats (Formatter, FormatGpx, FormatJson, FormatKml, FormatCsv),
// voice hints, nogo polygons, round trips, area info and the server's
// parameter parsing. A profile asking for another model is refused.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../expressions/expressions.dart';
import '../mapaccess/geometry_decoder.dart';
import '../mapaccess/matched_waypoint.dart';
import '../mapaccess/nodes_cache.dart';
import '../mapaccess/nodes_cache_context.dart';
import '../mapaccess/osm_link.dart';
import '../mapaccess/osm_link_holder.dart';
import '../mapaccess/osm_node.dart';
import '../mapaccess/osm_node_pair_set.dart';
import '../mapaccess/osm_pos.dart';
import '../mapaccess/turn_restriction.dart';
import '../util/cheap_angle_meter.dart';
import '../util/cheap_ruler.dart';
import '../util/fdlibm.dart' as fdlibm;
import '../util/float32.dart';
import '../util/int32.dart';

part 'message_data.dart';
part 'osm_node_named.dart';
part 'osm_path_element.dart';
part 'osm_path.dart';
part 'std_path.dart';
part 'routing_context.dart';
part 'osm_track.dart';
part 'sorted_heap.dart';
part 'routing_engine.dart';

const int _shortMin = -32768;

/// Java `Math.round(d)` for a double: floor(d + 0.5), as a long.
int _javaRound(double d) {
  if (d.isNaN) return 0;
  return (d + 0.5).floorToDouble().toInt();
}
