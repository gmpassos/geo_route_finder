import '../graph/graph_builder.dart';
import '../graph/graph_types.dart';
import '../model/geo_coordinate.dart';
import '../model/geo_route.dart';
import '../spatial/kd_tree.dart';
import '../spatial/nearest_node_search.dart';
import '../storage/compiled_graph.dart';
import '../storage/geo_storage.dart';

/// The public routing contract. Implementations differ only in *how* they find
/// the path; the API is identical so callers can swap an [AStarRouter] for a
/// [ContractionHierarchyRouter] without any other change.
abstract interface class RouteFinder {
  /// Computes the fastest route from [start] to [end]. Returns
  /// [GeoRoute.none] when no connecting path exists.
  Future<GeoRoute> findRoute(GeoCoordinate start, GeoCoordinate end);
}

/// A raw shortest path expressed in graph terms, before it is turned into a
/// user-facing [GeoRoute].
class RawPath {
  /// Vertex sequence `v0 .. vk`.
  final List<int> vertices;

  /// Edge sequence `e0 .. e(k-1)`, where `e(i)` connects `v(i)` to `v(i+1)`.
  final List<int> edges;

  final double distanceMeters;
  final double timeSeconds;

  const RawPath({
    required this.vertices,
    required this.edges,
    required this.distanceMeters,
    required this.timeSeconds,
  });

  static const RawPath none = RawPath(
    vertices: [],
    edges: [],
    distanceMeters: double.infinity,
    timeSeconds: 0,
  );

  bool get found => vertices.isNotEmpty;
}

/// Shared machinery for routers that operate on a [RoutingGraph] loaded from a
/// [GeoStorage].
///
/// Handles, once and lazily on the first query:
///
/// * loading the compiled artifact (fast path) or rebuilding it from a generic
///   [GeoGraph] (fallback path),
/// * snapping coordinates to vertices,
/// * reconstructing the geometry and totals of a [RawPath] into a [GeoRoute].
///
/// Subclasses implement [search] and, optionally, [prepare] (per-graph
/// preprocessing such as building contraction hierarchies).
abstract class GraphRouteFinder implements RouteFinder {
  final GeoStorage storage;
  final String graphId;

  /// Maximum snapping distance; coordinates farther than this from any vertex
  /// fail to route. `null` disables the limit.
  final double? maxSnapMeters;

  GraphRouteFinder({
    required this.storage,
    required this.graphId,
    this.maxSnapMeters,
  });

  RoutingGraph? _graph;
  NearestNodeSearch? _search;
  bool _prepared = false;

  /// The loaded routing graph. Valid only after [ensureLoaded].
  RoutingGraph get graph => _graph!;

  /// The loaded snapping service. Valid only after [ensureLoaded].
  NearestNodeSearch get nearest => _search!;

  /// Loads (and prepares) the graph if it has not been loaded yet. Safe to call
  /// repeatedly; the work happens once.
  Future<void> ensureLoaded() async {
    if (_prepared) return;

    final st = storage;
    if (st is CompiledGraphStorage && await st.exists(graphId)) {
      final compiled = await st.loadCompiled(graphId);
      if (compiled == null) {
        throw StateError('No graph stored under id "$graphId".');
      }
      _graph = compiled.graph;
      _search = NearestNodeSearch(compiled.graph, compiled.tree);
    } else {
      final geo = await st.loadGraph(graphId);
      if (geo == null) {
        throw StateError('No graph stored under id "$graphId".');
      }
      final built = const GraphBuilder().build(geo);
      _graph = built;
      _search = NearestNodeSearch(built, KdTree.build(built));
    }

    await prepare();
    _prepared = true;
  }

  /// Hook for subclasses to run per-graph preprocessing after the graph is
  /// loaded. Default: no-op.
  Future<void> prepare() async {}

  /// Core shortest-path computation between two vertices. Implemented by each
  /// algorithm. Must return [RawPath.none] when unreachable.
  RawPath search(int source, int target);

  @override
  Future<GeoRoute> findRoute(GeoCoordinate start, GeoCoordinate end) async {
    await ensureLoaded();

    final s = nearest.snap(start, maxSnapMeters: maxSnapMeters);
    final t = nearest.snap(end, maxSnapMeters: maxSnapMeters);
    if (!s.found || !t.found) return GeoRoute.none;

    if (s.node == t.node) {
      final c = graph.coordinateOf(s.node);
      return GeoRoute(
        distanceMeters: 0,
        duration: Duration.zero,
        geometry: [c, c],
      );
    }

    final path = search(s.node, t.node);
    if (!path.found) return GeoRoute.none;

    return buildRoute(path);
  }

  /// Turns a [RawPath] into a [GeoRoute] by stitching together vertex
  /// coordinates and the intermediate geometry of each traversed edge.
  GeoRoute buildRoute(RawPath path) {
    final geometry = <GeoCoordinate>[];
    final g = graph;
    geometry.add(g.coordinateOf(path.vertices.first));
    for (var i = 0; i < path.edges.length; i++) {
      geometry.addAll(g.geometryOf(path.edges[i]));
      geometry.add(g.coordinateOf(path.vertices[i + 1]));
    }
    return GeoRoute(
      distanceMeters: path.distanceMeters,
      duration: Duration(microseconds: (path.timeSeconds * 1e6).round()),
      geometry: geometry,
    );
  }

  /// Helper for subclasses: rebuilds a [RawPath] from predecessor arrays
  /// produced by a forward search. [parentEdge]/[parentNode] record, for each
  /// settled vertex, the edge and vertex it was reached from. [timeSeconds] is
  /// the total cost at [target].
  RawPath reconstructForward(
    int source,
    int target,
    List<int> parentEdge,
    List<int> parentNode,
    double timeSeconds,
  ) {
    final g = graph;
    final revEdges = <int>[];
    final revVerts = <int>[target];
    var cur = target;
    var distance = 0.0;
    while (cur != source) {
      final e = parentEdge[cur];
      if (e < 0) return RawPath.none;
      revEdges.add(e);
      distance += g.adjDist[e];
      cur = parentNode[cur];
      revVerts.add(cur);
    }
    return RawPath(
      vertices: revVerts.reversed.toList(),
      edges: revEdges.reversed.toList(),
      distanceMeters: distance,
      timeSeconds: timeSeconds,
    );
  }

  /// Helper for subclasses: finds the edge index from [u] to [v] with the
  /// smallest travel time (handles parallel edges). Returns -1 if none.
  int bestEdgeBetween(int u, int v) {
    final g = graph;
    var best = -1;
    var bestTime = double.infinity;
    for (var e = g.adjOffset[u]; e < g.adjOffset[u + 1]; e++) {
      if (g.adjTarget[e] == v && g.adjTime[e] < bestTime) {
        bestTime = g.adjTime[e];
        best = e;
      }
    }
    return best;
  }
}
