// Port of btools.util.CheapRuler (BRouter v1.7.10, MIT), itself after
// mapbox/cheap-ruler (ISC). Cosines come from fdlibm (`docs/design.md` D4).
import 'dart:math' as math;
import 'dart:typed_data';

import 'fdlibm.dart' as fdlibm;

/// Integer coordinates: longitude (degrees + 180) × 1e6, latitude
/// (degrees + 90) × 1e6.
abstract final class CheapRuler {
  static const double ilatlngToLatlng = 1e-6;
  static const int kilometersToMeters = 1000;
  static const double degToRad = math.pi / 180.0;

  static const int _scaleCacheLength = 1800;
  static const int _scaleCacheIncrement = 100000;

  static final List<Float64List> _scaleCache = List.generate(
    _scaleCacheLength,
    (i) => _calcKxKyFromILat(i * _scaleCacheIncrement + _scaleCacheIncrement ~/ 2),
  );

  static Float64List _calcKxKyFromILat(int ilat) {
    final lat = degToRad * (ilat * ilatlngToLatlng - 90);
    final cos = fdlibm.cos(lat);
    final cos2 = 2 * cos * cos - 1;
    final cos3 = 2 * cos * cos2 - cos;
    final cos4 = 2 * cos * cos3 - cos2;
    final cos5 = 2 * cos * cos4 - cos3;
    return Float64List.fromList([
      (111.41513 * cos - 0.09455 * cos3 + 0.00012 * cos5) * ilatlngToLatlng * kilometersToMeters,
      (111.13209 - 0.56605 * cos2 + 0.0012 * cos4) * ilatlngToLatlng * kilometersToMeters,
    ]);
  }

  /// Metres per integer unit of [lon, lat] at [ilat].
  static Float64List getLonLatToMeterScales(int ilat) => _scaleCache[ilat ~/ _scaleCacheIncrement];

  /// Distance in metres.
  static double distance(int ilon1, int ilat1, int ilon2, int ilat2) {
    final kxky = getLonLatToMeterScales((ilat1 + ilat2) >> 1);
    final dlon = (ilon1 - ilon2) * kxky[0];
    final dlat = (ilat1 - ilat2) * kxky[1];
    return math.sqrt(dlat * dlat + dlon * dlon);
  }

  /// The point [distance] metres from (lon1, lat1) at [angle] degrees
  /// clockwise from north.
  static (int, int) destination(int lon1, int lat1, double distance, double angle) {
    final lonlat2m = getLonLatToMeterScales(lat1);
    final lon2m = lonlat2m[0];
    final lat2m = lonlat2m[1];
    angle = 90.0 - angle;
    final st = fdlibm.sin(angle * math.pi / 180.0);
    final ct = fdlibm.cos(angle * math.pi / 180.0);
    final lon2 = (0.5 + lon1 + ct * distance / lon2m).truncate();
    final lat2 = (0.5 + lat1 + st * distance / lat2m).truncate();
    return (lon2, lat2);
  }
}
