import 'geo_coordinate.dart';

/// The result of a successful routing query.
class GeoRoute {
  /// Total driven distance along the route, in meters.
  final double distanceMeters;

  /// Estimated travel duration, derived from per-edge speeds.
  final Duration duration;

  /// Full route geometry from origin to destination, following the real shape
  /// of the underlying roads (including the intermediate shape points that were
  /// collapsed away when the routing graph was compressed).
  final List<GeoCoordinate> geometry;

  const GeoRoute({
    required this.distanceMeters,
    required this.duration,
    required this.geometry,
  });

  /// A sentinel representing "no route found".
  static const GeoRoute none = GeoRoute(
    distanceMeters: double.infinity,
    duration: Duration.zero,
    geometry: [],
  );

  /// Whether a connecting path was actually found.
  bool get found => geometry.isNotEmpty && distanceMeters.isFinite;

  @override
  String toString() => found
      ? 'GeoRoute(${(distanceMeters / 1000).toStringAsFixed(2)} km, '
            '$duration, ${geometry.length} points)'
      : 'GeoRoute(no route)';
}
