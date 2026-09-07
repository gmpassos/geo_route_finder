/// A high-performance, data-source-agnostic, offline-first routing engine
/// written in pure Dart.
///
/// `geo_route_finder` computes routes between geographic coordinates over road
/// graphs that can come from any source (OpenStreetMap is the bundled reference
/// adapter) and be stored in any backend (a compact binary file store is
/// bundled). The engine operates only on a normalized internal model, so it is
/// never coupled to a particular vendor.
///
/// Typical flow:
///
/// ```dart
/// final storage = LocalFileStorage(directory: './maps');
/// await OsmConverter().convert(
///   inputFile: 'sao-paulo.osm.pbf',
///   storage: storage,
///   graphId: 'sao_paulo',
/// );
/// final router = AStarRouter(storage: storage, graphId: 'sao_paulo');
/// final route = await router.findRoute(
///   const GeoCoordinate(lat: -23.5505, lon: -46.6333),
///   const GeoCoordinate(lat: -23.9608, lon: -46.3336),
/// );
/// print(route.distanceMeters);
/// print(route.duration);
/// ```
///
/// Pass a [VehicleProfile] (car, motorcycle, bicycle) to [OsmConverter] to build
/// a graph for that mode — each profile routes over a different network, so build
/// and store one graph per profile. Toll segments are flagged during conversion,
/// and any query can avoid them with `findRoute(start, end, avoidTolls: true)`.
library;

// OpenStreetMap acquisition and decoding, plus the source-level element model,
// all live in the sibling package `geo_osm_pbf` — shared with the vector tile
// builder that reads the same extracts.
//
// They are re-exported here so that `OsmPbfParser`, `GeoCoordinate`, `GeoNode`,
// `GeoWay`, `OsmDownloader` and the download sources remain importable from
// this library exactly as before. These are the same types, not wrappers.
export 'package:geo_osm_pbf/geo_osm_pbf.dart';

// Model — the routing-specific types built on top of that model.
export 'src/model/geo_edge.dart';
export 'src/model/geo_graph.dart';
export 'src/model/geo_route.dart';

// Data source extension point and the OSM adapter.
export 'src/datasource/geo_data_source.dart';
export 'src/osm/osm_converter.dart';
export 'src/osm/osm_data_source.dart';
export 'src/osm/vehicle_profile.dart';

// Graph compilation and optimization.
export 'src/graph/graph_types.dart';
export 'src/graph/graph_builder.dart';
export 'src/graph/graph_compressor.dart';

// Spatial index.
export 'src/spatial/kd_tree.dart';
export 'src/spatial/nearest_node_search.dart';

// Storage extension point and the local file backend.
export 'src/storage/geo_storage.dart';
export 'src/storage/compiled_graph.dart';
export 'src/storage/local_file_storage.dart';

// Serialization.
export 'src/serialization/checksum.dart';
export 'src/serialization/graph_serializer.dart';
export 'src/serialization/graph_deserializer.dart';

// Routing.
export 'src/routing/route_finder.dart'
    show RouteFinder, GraphRouteFinder, RawPath;
export 'src/routing/priority_queue.dart' show MinHeap;
export 'src/routing/dijkstra_router.dart';
export 'src/routing/astar_router.dart';
export 'src/routing/contraction_hierarchy.dart';
