// Port of btools.util.CheapAngleMeter (BRouter v1.7.10, MIT).
import 'dart:math' as math;

import 'cheap_ruler.dart';
import 'fdlibm.dart' as fdlibm;

/// Java's Math.toDegrees since JDK 9: one multiplication by this constant.
const double _radiansToDegrees = 57.29577951308232;

/// The angle defined by three points, with its cosine on the side.
class CheapAngleMeter {
  double _cosangle = 0;

  double getCosAngle() => _cosangle;

  double calcAngle(int lon0, int lat0, int lon1, int lat1, int lon2, int lat2) {
    final lonlat2m = CheapRuler.getLonLatToMeterScales(lat1);
    final lon2m = lonlat2m[0];
    final lat2m = lonlat2m[1];
    final dx10 = (lon1 - lon0) * lon2m;
    final dy10 = (lat1 - lat0) * lat2m;
    final dx21 = (lon2 - lon1) * lon2m;
    final dy21 = (lat2 - lat1) * lat2m;
    final dd = math.sqrt((dx10 * dx10 + dy10 * dy10) * (dx21 * dx21 + dy21 * dy21));
    if (dd == 0.0) {
      _cosangle = 1.0;
      return 0.0;
    }
    var sinp = (dy10 * dx21 - dx10 * dy21) / dd;
    final cosp = (dy10 * dy21 + dx10 * dx21) / dd;
    _cosangle = cosp;
    var offset = 0.0;
    var s2 = sinp * sinp;
    if (s2 > 0.5) {
      if (sinp > 0.0) {
        offset = 90.0;
        sinp = -cosp;
      } else {
        offset = -90.0;
        sinp = cosp;
      }
      s2 = cosp * cosp;
    } else if (cosp < 0.0) {
      sinp = -sinp;
      offset = sinp > 0.0 ? -180.0 : 180.0;
    }
    return offset + sinp * (57.4539 + s2 * (9.57565 + s2 * (4.30904 + s2 * 2.56491)));
  }

  static double getAngle(int lon1, int lat1, int lon2, int lat2) {
    final xdiff = (lat2 - lat1).toDouble();
    final ydiff = (lon2 - lon1).toDouble();
    return fdlibm.atan2(ydiff, xdiff) * _radiansToDegrees;
  }

  static double getDirection(int lon1, int lat1, int lon2, int lat2) =>
      normalize(getAngle(lon1, lat1, lon2, lat2));

  static double normalize(double a) => a >= 360
      ? a - (360 * (a / 360).truncate())
      : a < 0
          ? a - (360 * ((a / 360).truncate() - 1))
          : a;

  static double getDifferenceFromDirection(double b1, double b2) {
    // Java's % on doubles keeps the sign of the dividend: remainder, not %.
    var r = (b2 - b1).remainder(360.0);
    if (r < -180.0) r += 360.0;
    if (r >= 180.0) r -= 360.0;
    return r.abs();
  }
}
