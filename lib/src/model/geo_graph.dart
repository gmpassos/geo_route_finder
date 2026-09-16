import 'package:geo_osm_pbf/geo_osm_pbf.dart';

import 'geo_edge.dart';
import 'geo_turn_restriction.dart';

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

  /// Ids of the vertices that are signalised junctions — a set of traffic
  /// lights on the road.
  ///
  /// **A property of nodes, not of edges, and it has to be.** A light delays
  /// whoever arrives at the junction, so the cost belongs to the traversal
  /// that ends there — and a two-way street is *one* [GeoEdge] from which the
  /// builder materialises both directions. Recorded per edge, the reverse
  /// direction would arrive at the far end and either miss its light or
  /// inherit one it never reaches. Recorded here, the builder charges each
  /// directed edge for the junction it actually enters, and both directions
  /// come out right without an adapter having to split the street in two.
  ///
  /// Empty for a source that knows nothing about signals, which costs nothing
  /// and reads as "no lights modelled" rather than "no lights here".
  final Set<int> signalNodeIds;

  /// Movements a vehicle may not make, keyed by OSM node id.
  ///
  /// Carried as ids for the same reason [signalNodeIds] is: this type is what
  /// every adapter converts *into*, and ids are the only identifier an adapter
  /// can be expected to know. Edge indices do not exist yet, and the ones that
  /// will are assigned twice — once by the builder, again by the compressor.
  ///
  /// Empty for a source that models no restrictions, which reads as "none
  /// modelled" rather than "none here" — the same honest distinction the
  /// signal set draws.
  final List<GeoTurnRestriction> turnRestrictions;

  const GeoGraph({
    required this.nodes,
    required this.edges,
    this.signalNodeIds = const {},
    this.turnRestrictions = const [],
  });

  /// An empty graph.
  static const GeoGraph empty = GeoGraph(nodes: [], edges: []);

  int get nodeCount => nodes.length;
  int get edgeCount => edges.length;

  /// How many vertices are signalised junctions.
  int get signalCount => signalNodeIds.length;

  @override
  String toString() =>
      'GeoGraph(${nodes.length} nodes, ${edges.length} edges'
      '${signalNodeIds.isEmpty ? '' : ', ${signalNodeIds.length} signals'})';
}
