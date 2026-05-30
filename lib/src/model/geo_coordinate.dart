import 'dart:math' as math;

/// Mean radius of the Earth in meters (WGS84 authalic radius).
const double earthRadiusMeters = 6371008.8;

/// An immutable geographic coordinate expressed in decimal degrees.
///
/// This is the primary value type exchanged with callers of the routing
/// engine. It is intentionally tiny and free of any data-source specific
/// concepts so that it can be reused across every adapter.
class GeoCoordinate {
  /// Latitude in decimal degrees, in the range `[-90, 90]`.
  final double lat;

  /// Longitude in decimal degrees, in the range `[-180, 180]`.
  final double lon;

  const GeoCoordinate({required this.lat, required this.lon});

  /// Great-circle distance, in meters, between this coordinate and [other]
  /// using the haversine formula.
  ///
  /// The haversine formula is numerically stable for the small distances that
  /// dominate road routing and avoids the catastrophic cancellation that the
  /// spherical law of cosines suffers from at short ranges.
  double distanceTo(GeoCoordinate other) =>
      haversineMeters(lat, lon, other.lat, other.lon);

  @override
  bool operator ==(Object other) =>
      other is GeoCoordinate && other.lat == lat && other.lon == lon;

  @override
  int get hashCode => Object.hash(lat, lon);

  @override
  String toString() => 'GeoCoordinate($lat, $lon)';
}

const double _degToRad = math.pi / 180.0;

/// Haversine great-circle distance in meters between two lat/lon pairs.
double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  final dLat = (lat2 - lat1) * _degToRad;
  final dLon = (lon2 - lon1) * _degToRad;
  final rLat1 = lat1 * _degToRad;
  final rLat2 = lat2 * _degToRad;

  final sinDLat = math.sin(dLat * 0.5);
  final sinDLon = math.sin(dLon * 0.5);
  final a =
      sinDLat * sinDLat + math.cos(rLat1) * math.cos(rLat2) * sinDLon * sinDLon;
  final c = 2 * math.asin(math.min(1.0, math.sqrt(a)));
  return earthRadiusMeters * c;
}

/// Squared planar distance in an equirectangular projection centred on
/// [refLatRad]. This is *not* a real distance, but it preserves ordering for
/// nearest-neighbour comparisons and is far cheaper than haversine, which makes
/// it ideal as the comparison key inside the KD-tree.
double equirectSquared(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
  double cosRefLat,
) {
  final x = (lon2 - lon1) * cosRefLat;
  final y = (lat2 - lat1);
  return x * x + y * y;
}
