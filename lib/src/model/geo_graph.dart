import 'geo_edge.dart';
import 'geo_node.dart';

/// The normalized, data-source-agnostic graph that every adapter converts into
/// and that the routing engine operates on exclusively.
///
/// No routing code depends on OpenStreetMap (or any other vendor) structures —
/// everything flows through this type. A [GeoGraph] is a plain container; the
/// performance-oriented, compiled representation used during search lives in
/// `RoutingGraph` and is produced by the graph builder.
class GeoGraph {
  /// All vertices in the graph.
  final List<GeoNode> nodes;

  /// All directed (or bidirectional, via [GeoEdge.oneWay]) connections.
  final List<GeoEdge> edges;

  const GeoGraph({required this.nodes, required this.edges});

  /// An empty graph.
  static const GeoGraph empty = GeoGraph(nodes: [], edges: []);

  int get nodeCount => nodes.length;
  int get edgeCount => edges.length;

  @override
  String toString() => 'GeoGraph(${nodes.length} nodes, ${edges.length} edges)';
}
