import 'dart:typed_data';

import '../model/geo_coordinate.dart';

/// The compiled, search-optimized routing graph.
///
/// Unlike the generic [GeoGraph] (a list of object instances), this structure
/// stores the topology in flat, primitive [TypedData] arrays using the
/// Compressed-Sparse-Row (CSR) layout. This is the representation the routers,
/// the KD-tree and the binary serializer all operate on. Benefits:
///
/// * **Cache friendly.** A node's outgoing edges are contiguous in memory.
/// * **Memory efficient.** No per-node/per-edge object headers; a city graph of
///   a few hundred thousand vertices fits in a handful of megabytes.
/// * **Zero-copy serialization.** The arrays map directly to/from bytes.
///
/// Vertices are densely numbered `0 .. nodeCount-1`. For a vertex `u`, its
/// outgoing edges occupy the half-open range `[adjOffset[u], adjOffset[u+1])`
/// of the edge arrays.
class RoutingGraph {
  /// Latitude of each vertex, length [nodeCount].
  final Float64List lat;

  /// Longitude of each vertex, length [nodeCount].
  final Float64List lon;

  /// Original (source) id of each vertex, length [nodeCount]. Preserved for
  /// round-tripping and debugging; not used during search.
  final Int64List originalId;

  /// CSR row pointers, length `nodeCount + 1`.
  final Int32List adjOffset;

  /// Target vertex of each directed edge, length [edgeCount].
  final Int32List adjTarget;

  /// Travel time weight of each edge in seconds, length [edgeCount].
  final Float64List adjTime;

  /// Ground distance of each edge in meters, length [edgeCount].
  final Float64List adjDist;

  /// Number of toll sections on each edge (`0` = free), length [edgeCount].
  /// Counts accumulate when degree-2 chains are collapsed. Consulted at query
  /// time when a route is asked to avoid tolls and to report its toll count.
  final Uint8List adjToll;

  /// Per-edge intermediate geometry, interleaved `lat, lon` pairs. The points
  /// for edge `e` are `[geomOffset[e], geomOffset[e+1])` measured in *points*
  /// (each point being two consecutive doubles in [geomCoords]). Endpoints are
  /// excluded — they are recovered from [lat]/[lon] of the edge's vertices.
  final Float64List geomCoords;

  /// CSR row pointers into [geomCoords], length `edgeCount + 1`, in points.
  final Int32List geomOffset;

  RoutingGraph({
    required this.lat,
    required this.lon,
    required this.originalId,
    required this.adjOffset,
    required this.adjTarget,
    required this.adjTime,
    required this.adjDist,
    required this.adjToll,
    required this.geomCoords,
    required this.geomOffset,
  });

  int get nodeCount => lat.length;
  int get edgeCount => adjTarget.length;

  /// Number of toll sections on edge [e].
  int tollsOf(int e) => adjToll[e];

  /// Whether edge [e] crosses at least one toll.
  bool isToll(int e) => adjToll[e] != 0;

  /// Coordinate of vertex [v].
  GeoCoordinate coordinateOf(int v) => GeoCoordinate(lat: lat[v], lon: lon[v]);

  /// Index of the first outgoing edge of vertex [v].
  int edgeStart(int v) => adjOffset[v];

  /// One past the index of the last outgoing edge of vertex [v].
  int edgeEnd(int v) => adjOffset[v + 1];

  /// Returns the intermediate geometry of edge [e] as a list of coordinates,
  /// ordered from the edge's source toward its target (endpoints excluded).
  List<GeoCoordinate> geometryOf(int e) {
    final start = geomOffset[e];
    final end = geomOffset[e + 1];
    final out = <GeoCoordinate>[];
    for (var i = start; i < end; i++) {
      out.add(
        GeoCoordinate(lat: geomCoords[i * 2], lon: geomCoords[i * 2 + 1]),
      );
    }
    return out;
  }

  @override
  String toString() => 'RoutingGraph($nodeCount nodes, $edgeCount edges)';
}
