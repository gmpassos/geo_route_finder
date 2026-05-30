import 'geo_coordinate.dart';

/// A single vertex in the generic road graph.
///
/// Identifiers are [int] so that 64-bit OpenStreetMap node ids can be carried
/// losslessly on native platforms. Adapters are free to assign their own ids as
/// long as they are unique within a [GeoGraph].
class GeoNode {
  /// Globally unique identifier for the node within its source graph.
  final int id;

  /// Latitude in decimal degrees.
  final double lat;

  /// Longitude in decimal degrees.
  final double lon;

  const GeoNode({required this.id, required this.lat, required this.lon});

  /// This node's position as a [GeoCoordinate].
  GeoCoordinate get coordinate => GeoCoordinate(lat: lat, lon: lon);

  @override
  String toString() => 'GeoNode($id, $lat, $lon)';
}
