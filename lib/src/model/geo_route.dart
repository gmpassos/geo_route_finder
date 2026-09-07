import 'package:geo_osm_pbf/geo_osm_pbf.dart';

/// The result of a successful routing query.
///
/// Implements [Comparable] so a list of routes (e.g. from `findRoutes`) can be
/// sorted directly: fewest tolls first, then shortest distance. Combine with
/// [hasTolls]/[tollCount] to split the result into toll-free and tolled routes.
class GeoRoute implements Comparable<GeoRoute> {
  /// Total driven distance along the route, in meters.
  final double distanceMeters;

  /// Estimated travel duration, derived from per-edge speeds.
  final Duration duration;

  /// Full route geometry from origin to destination, following the real shape
  /// of the underlying roads (including the intermediate shape points that were
  /// collapsed away when the routing graph was compressed).
  final List<GeoCoordinate> geometry;

  /// Number of toll road segments traversed by the route. Lets callers filter
  /// the result of `findRoutes` into toll-free and tolled routes, or order them
  /// by how many tolls they cross.
  final int tollCount;

  const GeoRoute({
    required this.distanceMeters,
    required this.duration,
    required this.geometry,
    this.tollCount = 0,
  });

  /// A sentinel representing "no route found".
  static const GeoRoute none = GeoRoute(
    distanceMeters: double.infinity,
    duration: Duration.zero,
    geometry: [],
  );

  /// Whether a connecting path was actually found.
  bool get found => geometry.isNotEmpty && distanceMeters.isFinite;

  /// Whether the route crosses at least one toll road segment.
  bool get hasTolls => tollCount > 0;

  /// Orders routes by ascending toll count, then ascending distance. A
  /// not-found route sorts after any found one.
  @override
  int compareTo(GeoRoute other) {
    if (found != other.found) return found ? -1 : 1;
    final byTolls = tollCount.compareTo(other.tollCount);
    if (byTolls != 0) return byTolls;
    return distanceMeters.compareTo(other.distanceMeters);
  }

  @override
  String toString() => found
      ? 'GeoRoute(${(distanceMeters / 1000).toStringAsFixed(2)} km, '
            '$duration, ${geometry.length} points, $tollCount tolls)'
      : 'GeoRoute(no route)';
}
