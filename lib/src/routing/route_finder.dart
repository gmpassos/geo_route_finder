import 'dart:typed_data';

import 'package:geo_osm_pbf/geo_osm_pbf.dart';

import '../graph/graph_builder.dart';
import '../graph/graph_compressor.dart';
import '../graph/graph_types.dart';
import '../model/geo_route.dart';
import '../osm/vehicle_profile.dart';
import '../spatial/kd_tree.dart';
import '../spatial/nearest_node_search.dart';
import '../storage/compiled_graph.dart';
import '../storage/geo_storage.dart';
import 'priority_queue.dart';

/// The public routing contract. Implementations differ only in *how* they find
/// the path; the API is identical so callers can swap an [AStarRouter] for a
/// [ContractionHierarchyRouter] without any other change.
abstract interface class RouteFinder {
  /// Computes the fastest route from [start] to [end]. Returns
  /// [GeoRoute.none] when no connecting path exists.
  ///
  /// When [avoidTolls] is `true`, toll roads are strongly penalized so a
  /// toll-free route is preferred; a tolled route is still returned when the
  /// destination cannot be reached otherwise.
  Future<GeoRoute> findRoute(
    GeoCoordinate start,
    GeoCoordinate end, {
    bool avoidTolls = false,
  });

  /// Computes the fastest route and, optionally, a number of *alternative*
  /// routes between [start] and [end].
  ///
  /// The returned list is ordered best-first: element `0` is always the optimal
  /// (fastest) route — identical to what [findRoute] returns — and the
  /// remaining elements are alternatives ordered by increasing distance. An
  /// empty list means no connecting path exists.
  ///
  /// Parameters:
  ///
  /// * [maxRoutes] — the maximum number of routes to return, *including* the
  ///   optimal one. The default of `1` reproduces [findRoute] exactly (no
  ///   alternatives are computed).
  /// * [maxExtraRatio] — an alternative is discarded if its distance exceeds
  ///   `bestDistance * (1 + maxExtraRatio)`. `0.3` allows alternatives up to
  ///   30% longer than the optimal route.
  /// * [maxExtraMeters] — an optional *absolute* cap on the extra distance over
  ///   the optimal route. When set, an alternative must satisfy both this and
  ///   [maxExtraRatio]; the tighter of the two wins.
  /// * [maxSharing] — an alternative is discarded if more than this fraction of
  ///   its length overlaps routes already chosen, keeping alternatives
  ///   genuinely distinct. `0.8` allows up to 80% shared length.
  /// * [avoidTolls] — when `true`, toll roads are strongly penalized so toll-free
  ///   routes are preferred; tolled segments are used only when unavoidable.
  Future<List<GeoRoute>> findRoutes(
    GeoCoordinate start,
    GeoCoordinate end, {
    int maxRoutes = 1,
    double maxExtraRatio = 0.3,
    double? maxExtraMeters,
    double maxSharing = 0.8,
    bool avoidTolls = false,
  });
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

  /// Transport mode to route for. Selects which graph stored under [graphId] is
  /// loaded (storage keys graphs by `(id, profile)`). Defaults to
  /// [VehicleProfile.car].
  final VehicleProfile profile;

  /// Maximum snapping distance; coordinates farther than this from any vertex
  /// fail to route. `null` disables the limit.
  final double? maxSnapMeters;

  GraphRouteFinder({
    required this.storage,
    required this.graphId,
    this.profile = VehicleProfile.car,
    this.maxSnapMeters,
  });

  RoutingGraph? _graph;
  NearestNodeSearch? _search;
  bool _prepared = false;

  int _lastExpandedNodes = 0;

  /// The number of graph vertices expanded (settled) by the most recent
  /// [search]. For the bidirectional Contraction Hierarchies query this counts
  /// both search directions. Useful for measuring how much of the graph a query
  /// had to explore. Zero before any search.
  int get lastExpandedNodes => _lastExpandedNodes;

  /// Subclasses report, at the end of [search], how many vertices they expanded.
  void reportExpandedNodes(int count) => _lastExpandedNodes = count;

  /// The loaded routing graph. Valid only after [ensureLoaded].
  RoutingGraph get graph => _graph!;

  /// The loaded snapping service. Valid only after [ensureLoaded].
  NearestNodeSearch get nearest => _search!;

  /// Loads (and prepares) the graph if it has not been loaded yet. Safe to call
  /// repeatedly; the work happens once.
  Future<void> ensureLoaded() async {
    if (_prepared) return;

    final st = storage;
    if (st is CompiledGraphStorage &&
        await st.exists(graphId, profile: profile)) {
      final compiled = await st.loadCompiled(graphId, profile: profile);
      if (compiled == null) {
        throw StateError(
          'No graph stored under id "$graphId" for profile "${profile.name}".',
        );
      }
      _graph = compiled.graph;
      _search = NearestNodeSearch(compiled.graph, compiled.tree);
    } else {
      final geo = await st.loadGraph(graphId, profile: profile);
      if (geo == null) {
        throw StateError(
          'No graph stored under id "$graphId" for profile "${profile.name}".',
        );
      }
      // Compress degree-2 chains before indexing and routing, mirroring the
      // compiled path (OsmConverter.compile). Without this the KD-tree and the
      // search run over the full uncompressed vertex set (one vertex per source
      // node, ~10x larger), which dominates the cost of loading a graph from a
      // generic GeoStorage.
      final built = GraphCompressor().compress(const GraphBuilder().build(geo));
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
  Future<GeoRoute> findRoute(
    GeoCoordinate start,
    GeoCoordinate end, {
    bool avoidTolls = false,
  }) async {
    final routes = await findRoutes(start, end, avoidTolls: avoidTolls);
    return routes.isEmpty ? GeoRoute.none : routes.first;
  }

  @override
  Future<List<GeoRoute>> findRoutes(
    GeoCoordinate start,
    GeoCoordinate end, {
    int maxRoutes = 1,
    double maxExtraRatio = 0.3,
    double? maxExtraMeters,
    double maxSharing = 0.8,
    bool avoidTolls = false,
  }) async {
    await ensureLoaded();

    final s = nearest.snap(start, maxSnapMeters: maxSnapMeters);
    final t = nearest.snap(end, maxSnapMeters: maxSnapMeters);
    if (!s.found || !t.found) return const [];

    if (s.node == t.node) {
      final c = graph.coordinateOf(s.node);
      return [
        GeoRoute(distanceMeters: 0, duration: Duration.zero, geometry: [c, c]),
      ];
    }

    // When avoiding tolls, route over a Dijkstra whose weights heavily penalize
    // toll edges (uniform across every router, including CH whose baked
    // shortcuts cannot be re-weighted). Otherwise use the router's own search().
    final basePenalty = avoidTolls ? _tollPenalty() : null;
    final best = basePenalty != null
        ? _penalizedSearch(s.node, t.node, basePenalty)
        : search(s.node, t.node);
    if (!best.found) return const [];

    if (maxRoutes <= 1) return [buildRoute(best)];

    final paths = _findAlternatives(
      s.node,
      t.node,
      best,
      maxRoutes: maxRoutes,
      maxExtraRatio: maxExtraRatio,
      maxExtraMeters: maxExtraMeters,
      maxSharing: maxSharing,
      basePenalty: basePenalty,
    );
    return paths.map(buildRoute).toList();
  }

  /// Multiplier applied to a toll edge's travel time when [findRoutes] is asked
  /// to avoid tolls. Large but finite, so a tolled segment is taken only when no
  /// toll-free path exists (hard-avoid with fallback).
  static const double _tollPenaltyFactor = 1e6;

  /// Builds a per-edge penalty array seeded to [_tollPenaltyFactor] on toll
  /// edges and `1.0` elsewhere.
  Float64List _tollPenalty() {
    final g = graph;
    final p = Float64List(g.edgeCount)..fillRange(0, g.edgeCount, 1.0);
    for (var e = 0; e < g.edgeCount; e++) {
      if (g.adjToll[e] != 0) p[e] = _tollPenaltyFactor;
    }
    return p;
  }

  /// Penalty multiplier applied to the edges of an accepted (or too-similar)
  /// route before the next alternative search, steering it onto other roads.
  static const double _penaltyFactor = 1.6;

  /// Iterative penalty search for alternative routes.
  ///
  /// Starting from the optimal [best] path, each round penalizes the edges of
  /// the routes found so far and re-runs a Dijkstra over the penalized weights.
  /// Candidates that exceed the distance cap end the search; candidates that
  /// overlap the chosen routes too much are skipped (after penalizing them
  /// harder); the rest are accepted until [maxRoutes] is reached.
  List<RawPath> _findAlternatives(
    int source,
    int target,
    RawPath best, {
    required int maxRoutes,
    required double maxExtraRatio,
    required double? maxExtraMeters,
    required double maxSharing,
    Float64List? basePenalty,
  }) {
    final g = graph;
    final accepted = <RawPath>[best];
    final usedEdges = <int>{...best.edges};

    // Start from the toll-avoidance seed when present, so alternatives also
    // steer clear of toll roads; otherwise from a neutral all-ones array.
    final penalty = basePenalty != null
        ? Float64List.fromList(basePenalty)
        : (Float64List(g.edgeCount)..fillRange(0, g.edgeCount, 1.0));
    _penalize(penalty, best.edges);

    var maxDist = best.distanceMeters * (1 + maxExtraRatio);
    if (maxExtraMeters != null) {
      final absCap = best.distanceMeters + maxExtraMeters;
      if (absCap < maxDist) maxDist = absCap;
    }

    final maxAttempts = maxRoutes * 8 + 8;
    var attempts = 0;
    while (accepted.length < maxRoutes && attempts < maxAttempts) {
      attempts++;
      final cand = _penalizedSearch(source, target, penalty);
      if (!cand.found) break;
      if (cand.distanceMeters > maxDist) break;

      var shared = 0.0;
      for (final e in cand.edges) {
        if (usedEdges.contains(e)) shared += g.adjDist[e];
      }
      final sharing = cand.distanceMeters > 0
          ? shared / cand.distanceMeters
          : 1;
      _penalize(penalty, cand.edges);
      if (sharing > maxSharing) continue; // too similar: penalize, try again

      accepted.add(cand);
      usedEdges.addAll(cand.edges);
    }

    // Optimal route stays first; alternatives ordered by increasing distance.
    final alternatives = accepted.sublist(1)
      ..sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    return [accepted.first, ...alternatives];
  }

  void _penalize(Float64List penalty, List<int> edges) {
    for (final e in edges) {
      penalty[e] *= _penaltyFactor;
    }
  }

  /// Dijkstra over `adjTime[e] * penalty[e]`, used to discover alternative
  /// routes. The returned [RawPath] reports the *real* (unpenalized) distance
  /// and time of the discovered path. Runs on the original routing graph, so it
  /// works uniformly for every router (it is the alternatives fallback for the
  /// Contraction-Hierarchies router, whose shortcuts cannot be re-penalized).
  RawPath _penalizedSearch(int source, int target, Float64List penalty) {
    final g = graph;
    final n = g.nodeCount;
    final dist = Float64List(n)..fillRange(0, n, double.infinity);
    final parentEdge = Int32List(n)..fillRange(0, n, -1);
    final parentNode = Int32List(n)..fillRange(0, n, -1);

    final heap = MinHeap();
    dist[source] = 0;
    heap.push(0, source);

    while (heap.isNotEmpty) {
      final d = heap.peekKey;
      final u = heap.pop();
      if (d > dist[u]) continue; // stale entry
      if (u == target) break; // early exit
      for (var e = g.adjOffset[u]; e < g.adjOffset[u + 1]; e++) {
        final w = g.adjTime[e];
        if (w == double.infinity) continue;
        final v = g.adjTarget[e];
        final nd = d + w * penalty[e];
        if (nd < dist[v]) {
          dist[v] = nd;
          parentEdge[v] = e;
          parentNode[v] = u;
          heap.push(nd, v);
        }
      }
    }

    if (dist[target] == double.infinity) return RawPath.none;

    final revEdges = <int>[];
    final revVerts = <int>[target];
    var cur = target;
    var distance = 0.0;
    var time = 0.0;
    while (cur != source) {
      final e = parentEdge[cur];
      if (e < 0) return RawPath.none;
      revEdges.add(e);
      distance += g.adjDist[e];
      time += g.adjTime[e];
      cur = parentNode[cur];
      revVerts.add(cur);
    }
    return RawPath(
      vertices: revVerts.reversed.toList(),
      edges: revEdges.reversed.toList(),
      distanceMeters: distance,
      timeSeconds: time,
    );
  }

  /// Turns a [RawPath] into a [GeoRoute] by stitching together vertex
  /// coordinates and the intermediate geometry of each traversed edge.
  GeoRoute buildRoute(RawPath path) {
    final geometry = <GeoCoordinate>[];
    final g = graph;
    geometry.add(g.coordinateOf(path.vertices.first));
    var tollCount = 0;
    for (var i = 0; i < path.edges.length; i++) {
      final e = path.edges[i];
      tollCount += g.adjToll[e];
      geometry.addAll(g.geometryOf(e));
      geometry.add(g.coordinateOf(path.vertices[i + 1]));
    }
    return GeoRoute(
      distanceMeters: path.distanceMeters,
      duration: Duration(microseconds: (path.timeSeconds * 1e6).round()),
      geometry: geometry,
      tollCount: tollCount,
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
