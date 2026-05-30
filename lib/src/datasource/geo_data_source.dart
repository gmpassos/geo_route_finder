import '../model/geo_graph.dart';

/// The single extension point through which map data enters the engine.
///
/// Any provider — OpenStreetMap, HERE, TomTom, an in-house dataset, a unit-test
/// fixture — implements this interface to produce a normalized [GeoGraph]. The
/// routing engine knows nothing about where the data came from.
///
/// ```dart
/// class MyDataSource implements GeoDataSource {
///   @override
///   Future<GeoGraph> loadGraph() async => GeoGraph(nodes: [...], edges: [...]);
/// }
/// ```
abstract interface class GeoDataSource {
  /// Produces the normalized routing graph for this source.
  ///
  /// Implementations may stream, download, or read from disk internally, but
  /// must ultimately return data in the generic model. The call is asynchronous
  /// so that adapters can perform I/O without blocking.
  Future<GeoGraph> loadGraph();
}
