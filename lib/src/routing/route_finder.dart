import 'dart:typed_data';

import 'package:geo_osm_pbf/geo_osm_pbf.dart';

import '../graph/graph_builder.dart';
import '../graph/graph_compressor.dart';
import '../graph/graph_types.dart';
import '../graph/turn_restriction_splitter.dart';
import '../model/geo_route.dart';
import '../osm/conditional_restriction.dart';
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
  /// When [at] is given, conditional turn restrictions are evaluated against
  /// it — so a turn barred only on weekday mornings is open on a Sunday. With
  /// no clock every condition applies, which is the safe reading rather than
  /// the convenient one.
  Future<GeoRoute> findRoute(
    GeoCoordinate start,
    GeoCoordinate end, {
    bool avoidTolls = false,
    DateTime? at,
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
  /// * [at] — the moment the journey begins, used to decide which conditional
  ///   turn restrictions are in force. Omit it and every condition applies.
  Future<List<GeoRoute>> findRoutes(
    GeoCoordinate start,
    GeoCoordinate end, {
    int maxRoutes = 1,
    double maxExtraRatio = 0.3,
    double? maxExtraMeters,
    double maxSharing = 0.8,
    bool avoidTolls = false,
    DateTime? at,
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
      //
      // The split happens here too, in the same order as the compiled path:
      // build, split, compress. Leaving it out would quietly drop every
      // restriction the source carried and produce routes that look fine and
      // are illegal to follow — exactly what this exists to prevent.
      final built = GraphCompressor().compress(
        const TurnRestrictionSplitter().split(
          const GraphBuilder().build(geo),
          geo.turnRestrictions,
        ),
      );
      _graph = built;
      _search = NearestNodeSearch(built, KdTree.build(built));
    }

    _buildAliases();
    _buildAccessIndex();

    await prepare();
    _prepared = true;
  }

  /// For each vertex, the others that stand for the same place.
  ///
  /// Two kinds, because one real place can be more than one vertex:
  ///
  /// * **split copies**, from a turn restriction — a junction as approached
  ///   from the restricted arm;
  /// * **barrier twins**, from a gate or a bollard — the way was severed
  ///   there, so the two sides of it are separate vertices at one coordinate.
  ///
  /// Absent for every vertex that is neither, so the cost is paid only where
  /// it is owed. Without the second kind, snapping a destination to a severed
  /// gate picks a side arbitrarily, and a route from the other side reports no
  /// route at all — a condominium entrance being the common case.
  Map<int, List<int>> _aliases = const {};

  void _buildAliases() {
    final g = _graph!;
    final byParent = <int, List<int>>{};

    final splitParent = g.splitParent;
    if (splitParent != null) {
      for (var v = 0; v < g.nodeCount; v++) {
        final parent = splitParent[v];
        if (parent >= 0) byParent.putIfAbsent(parent, () => []).add(v);
      }
    }

    // Vertices sharing an exact coordinate.
    //
    // Only barrier twins can: the converter copies the gate's position
    // verbatim. A split copy also sits on its parent, but that pair is already
    // in the map above, so the two sources agree rather than fight. Grouped on
    // the raw pair rather than by distance, which would be a spatial query
    // over the whole graph to answer a question about a handful of vertices.
    final byPlace = <String, List<int>>{};
    for (var v = 0; v < g.nodeCount; v++) {
      byPlace.putIfAbsent('${g.lat[v]},${g.lon[v]}', () => []).add(v);
    }

    for (final together in byPlace.values) {
      if (together.length < 2) continue;
      for (final v in together) {
        final list = byParent.putIfAbsent(v, () => []);
        for (final w in together) {
          if (w != v && !list.contains(w)) list.add(w);
        }
      }
    }

    _aliases = byParent;
  }

  /// Whether edge [e] is closed to a rider reaching it [secondsSoFar] into a
  /// journey that began at [at].
  ///
  /// With no clock, every condition applies: a turn forbidden *sometimes* is
  /// treated as forbidden. The permissive default would route a rider through
  /// a junction they may be barred from at exactly the hour the restriction
  /// exists for, on the strength of nobody having supplied a time.
  ///
  /// With a clock, the condition is evaluated at **the moment the rider
  /// arrives**, `at + secondsSoFar`, not at departure. A restriction that ends
  /// at nine does not bind a rider who reaches the junction at five past.
  ///
  /// This is sound for Dijkstra without making the weights time-dependent:
  /// `dist[u]` is final when `u` settles, so the predicate is asked once per
  /// edge at a fixed instant, and those instants only increase along the
  /// settle order.
  ///
  /// **Waiting is not modelled**, and that is a statement about the answer
  /// rather than the algorithm. A turn barred until half past nine is treated
  /// as barred for this query, and a longer path that would arrive after it
  /// opens is never preferred on those grounds. That is the behaviour a rider
  /// wants — nobody wants to be advised to idle at a junction for an hour —
  /// but it is not the true time-dependent optimum, and it should not be
  /// described as one.
  bool isBlocked(int e, double secondsSoFar, DateTime? at) {
    final adjCond = graph.adjCond;
    if (adjCond == null) return false;

    final index = adjCond[e];
    if (index == 0) return false;

    if (at == null) return true;

    return ConditionalRestriction.appliesAt(
      graph.conditions[index - 1],
      at.add(Duration(seconds: secondsSoFar.round())),
    );
  }

  /// Every vertex that *is* [target], as far as a route is concerned.
  ///
  /// **Without this, a route whose destination is a restricted junction
  /// breaks.** Snapping returns the real vertex, but a path arriving through a
  /// restricted approach lands on that approach's copy instead — and under an
  /// `only_*` restriction the real vertex can be left with no incoming edge at
  /// all: somewhere a rider may leave and never reach.
  ///
  /// The copies sit at the identical coordinate, so the route that comes back
  /// is indistinguishable to a caller. Adding zero-cost edges from copy to
  /// parent would be the tempting fix and is badly wrong — it re-admits every
  /// forbidden turn by routing through the junction's inside.
  List<int> _targetsFor(int target) {
    final aliases = _aliases[target];
    return aliases == null ? [target] : [target, ...aliases];
  }

  /// Predecessors along access-only edges, for vertices that have any.
  ///
  /// The reverse of the access-only subgraph and nothing else. A full reverse
  /// CSR would answer the same question and cost a second copy of every edge
  /// in the city; driveways and parking aisles are a small fraction of one.
  Map<int, List<int>> _accessOnlyIn = const {};

  /// Vertices every one of whose edges may only be used to reach something.
  ///
  /// The inside of a car park, a driveway, the length of a track. A street
  /// junction with a driveway hanging off it is *not* one: it has public
  /// edges, so it is where the private area ends.
  ///
  /// This is what makes the rule "reach the endpoints" rather than "a run at
  /// each end". See [_computeAccessZones].
  List<bool> _private = const [];

  void _buildAccessIndex() {
    final g = _graph!;
    final incoming = <int, List<int>>{};

    for (var u = 0; u < g.nodeCount; u++) {
      for (var e = g.adjOffset[u]; e < g.adjOffset[u + 1]; e++) {
        if (!g.isAccessOnly(e)) continue;
        incoming.putIfAbsent(g.adjTarget[e], () => []).add(u);
      }
    }

    final private = List<bool>.filled(g.nodeCount, false);
    for (var v = 0; v < g.nodeCount; v++) {
      final start = g.adjOffset[v];
      final end = g.adjOffset[v + 1];
      if (start == end) continue;

      var all = true;
      for (var e = start; e < end; e++) {
        if (!g.isAccessOnly(e)) {
          all = false;
          break;
        }
      }
      private[v] = all;
    }

    _accessOnlyIn = incoming;
    _private = private;
    _hasAccessOnly = incoming.isNotEmpty;
  }

  /// Whether this graph has any access-only edges at all.
  bool get hasAccessOnlyEdges => _hasAccessOnly;
  bool _hasAccessOnly = false;

  /// Whether every edge leaving [v] may only be used to reach something on it.
  ///
  /// True inside a car park, along a driveway, on a track. False at the
  /// junction where any of those meets a public road, which is exactly where
  /// the private area ends.
  ///
  /// For subclasses that have to treat the private ends of a route separately
  /// from its middle — see `ContractionHierarchyRouter`, whose hierarchy is
  /// built over the public network alone.
  bool isInsidePrivateArea(int v) => _hasAccessOnly && _private[v];

  /// Vertices with an access-only edge leading into [v].
  ///
  /// The reverse of the access-only subgraph, for walking a private area
  /// backwards from a destination inside it.
  Iterable<int> accessOnlyInto(int v) => _accessOnlyIn[v] ?? const <int>[];

  /// The cheapest access-only edge from [u] to [v], or -1.
  ///
  /// Distinct from [bestEdgeBetween], which would happily return a public
  /// edge running between the same pair — fine for a route, wrong for
  /// measuring a walk that is meant to stay inside a private area.
  int accessOnlyEdgeBetween(int u, int v) {
    final g = graph;
    var best = -1;
    var bestTime = double.infinity;
    for (var e = g.adjOffset[u]; e < g.adjOffset[u + 1]; e++) {
      if (g.adjTarget[e] != v || !g.isAccessOnly(e)) continue;
      if (g.adjTime[e] < bestTime) {
        bestTime = g.adjTime[e];
        best = e;
      }
    }
    return best;
  }

  /// Vertices from which this query may still *leave* along an access-only
  /// edge — the run at the start of the route.
  Set<int> _leavingZone = const {};

  /// Vertices into which this query may *enter* along an access-only edge —
  /// the run at the end of the route.
  Set<int> _enteringZone = const {};

  /// Works out which access-only edges this particular query may use.
  ///
  /// An access-only way exists to reach something on it, which is not a
  /// property of the edge — it depends on where the rider is going. So it is
  /// resolved per query, into the two vertex sets that bound it:
  ///
  /// * the private area the rider is **starting inside**, which they may drive
  ///   out of;
  /// * the private area the destination is **inside**, which they may drive
  ///   into.
  ///
  /// Both are empty when the endpoint in question sits on a public road, and
  /// that emptiness is the whole rule. "A run of access-only edges at each
  /// end" sounds equivalent and is not: a route starting on a street beside a
  /// car park could open with a run straight across it and still satisfy the
  /// wording, which is the exact shortcut this exists to stop. A rider on a
  /// public street has no business in the car park unless they are going
  /// there, and if they were, the destination would be inside it.
  ///
  /// The walk stops at the edge of the private area — a junction with public
  /// roads on it is where the car park ends — so both sets are a driveway or a
  /// car park's worth of vertices. A graph with no access-only edges skips the
  /// work entirely.
  void _computeAccessZones(Iterable<int> sources, Iterable<int> targets) {
    if (!_hasAccessOnly) {
      _leavingZone = const {};
      _enteringZone = const {};
      return;
    }

    final g = _graph!;

    // Out of the private area the rider is standing in, if they are in one.
    final leaving = <int>{};
    final stack = <int>[];
    for (final s in sources) {
      if (_private[s] && leaving.add(s)) stack.add(s);
    }
    while (stack.isNotEmpty) {
      final u = stack.removeLast();
      for (var e = g.adjOffset[u]; e < g.adjOffset[u + 1]; e++) {
        if (!g.isAccessOnly(e)) continue;
        final v = g.adjTarget[e];
        // Only keep walking while still inside. The first public junction is
        // where the private area ends and the road network begins.
        if (_private[v] && leaving.add(v)) stack.add(v);
      }
    }

    // Into the private area the destination is in, if it is in one.
    final entering = <int>{};
    stack.clear();
    for (final t in targets) {
      if (_private[t] && entering.add(t)) stack.add(t);
    }
    while (stack.isNotEmpty) {
      final v = stack.removeLast();
      for (final u in _accessOnlyIn[v] ?? const <int>[]) {
        if (_private[u] && entering.add(u)) stack.add(u);
      }
    }

    _leavingZone = leaving;
    _enteringZone = entering;
  }

  /// Whether edge [e], leaving [u], is one this query may not use because it
  /// may only be used to reach something on it.
  ///
  /// Called beside [isBlocked] in every relaxation loop. Cheap twice over: a
  /// graph with no access-only edges answers on the first test, and one with
  /// them only pays on the edges that carry the flag.
  bool isAccessBlocked(int u, int e) {
    if (!_hasAccessOnly) return false;
    final g = graph;
    if (!g.isAccessOnly(e)) return false;
    return !_leavingZone.contains(u) && !_enteringZone.contains(g.adjTarget[e]);
  }

  /// The cheapest path to [target] or any vertex standing in for it.
  RawPath _searchToAny(int source, int target, DateTime? at) {
    final targets = _targetsFor(target);
    // Over every alias at once: they are the same place, so a driveway that
    // reaches one reaches the destination.
    _computeAccessZones(_targetsFor(source), targets);

    if (targets.length == 1) return search(source, targets.single, at: at);

    RawPath? best;
    for (final t in targets) {
      final path = search(source, t, at: at);
      if (!path.found) continue;
      // By **time**, because that is what the search minimised and what
      // `findRoute` promises. Choosing the shortest arrival instead can return
      // a route several times slower than one the search already found, and
      // only ever at a split junction — so it would be invisible everywhere
      // except the case this loop exists for.
      if (best == null || path.timeSeconds < best.timeSeconds) {
        best = path;
      }
    }
    return best ?? RawPath.none;
  }

  /// Hook for subclasses to run per-graph preprocessing after the graph is
  /// loaded. Default: no-op.
  Future<void> prepare() async {}

  /// Core shortest-path computation between two vertices. Implemented by each
  /// algorithm. Must return [RawPath.none] when unreachable.
  ///
  /// [at] is the moment the journey starts, or null. Passed explicitly rather
  /// than held on the router, because a field would be shared state on an
  /// object two concurrent queries can reach.
  RawPath search(int source, int target, {DateTime? at});

  @override
  Future<GeoRoute> findRoute(
    GeoCoordinate start,
    GeoCoordinate end, {
    bool avoidTolls = false,
    DateTime? at,
  }) async {
    final routes = await findRoutes(start, end, avoidTolls: avoidTolls, at: at);
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
    DateTime? at,
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
        ? _penalizedSearchToAny(s.node, t.node, basePenalty, at)
        : _searchToAny(s.node, t.node, at);
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
      at: at,
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
    DateTime? at,
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
      final cand = _penalizedSearchToAny(source, target, penalty, at);
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
  /// [_penalizedSearch] over every vertex standing in for [target].
  ///
  /// The alias loop belongs on this path too. `avoidTolls` bypasses `search`
  /// entirely, and so does every alternative route — so patching only the
  /// plain path would leave both unable to reach a restricted junction.
  /// A plain Dijkstra over the loaded graph, ignoring any preprocessing.
  ///
  /// For a router whose preprocessing cannot answer a particular question.
  /// `ContractionHierarchyRouter` uses it for a clocked query: its hierarchy
  /// is built with conditional edges removed — correct for the unclocked case,
  /// where every condition applies — so it has no way to *re-admit* an edge a
  /// clock says is open. `avoidTolls` already takes the same way out, for the
  /// same reason: baked shortcuts cannot be re-weighted.
  RawPath searchOverGraph(int source, int target, DateTime? at) =>
      _penalizedSearch(
        source,
        target,
        Float64List(graph.edgeCount)..fillRange(0, graph.edgeCount, 1.0),
        at,
      );

  RawPath _penalizedSearchToAny(
    int source,
    int target,
    Float64List penalty,
    DateTime? at,
  ) {
    final targets = _targetsFor(target);
    _computeAccessZones(_targetsFor(source), targets);

    if (targets.length == 1) {
      return _penalizedSearch(source, targets.single, penalty, at);
    }

    RawPath? best;
    var bestCost = double.infinity;

    for (final t in targets) {
      final path = _penalizedSearch(source, t, penalty, at);
      if (!path.found) continue;

      // Compared on the **penalized** cost, which is what this search
      // minimised. Comparing on distance — or even on real time — throws away
      // the 1e6 the toll penalty just spent saying "not this way", so a
      // shorter tolled arrival would beat a longer toll-free one and
      // `avoidTolls: true` would be defeated at the last step.
      var cost = 0.0;
      for (final e in path.edges) {
        cost += graph.adjTime[e] * penalty[e];
      }

      if (cost < bestCost) {
        bestCost = cost;
        best = path;
      }
    }
    return best ?? RawPath.none;
  }

  RawPath _penalizedSearch(
    int source,
    int target,
    Float64List penalty,
    DateTime? at,
  ) {
    final g = graph;
    final n = g.nodeCount;
    final dist = Float64List(n)..fillRange(0, n, double.infinity);
    final parentEdge = Int32List(n)..fillRange(0, n, -1);
    final parentNode = Int32List(n)..fillRange(0, n, -1);

    // Real seconds, tracked alongside the penalized cost.
    //
    // `dist` here is *penalized*, not time — a toll edge is weighted by a
    // factor large enough to steer around it — so feeding it to a clock would
    // be wrong by orders of magnitude. Kept separate so the condition check is
    // asked about the time the rider actually arrives.
    final realTime = Float64List(n)..fillRange(0, n, double.infinity);

    final heap = MinHeap();
    dist[source] = 0;
    realTime[source] = 0;
    heap.push(0, source);

    while (heap.isNotEmpty) {
      final d = heap.peekKey;
      final u = heap.pop();
      if (d > dist[u]) continue; // stale entry
      if (u == target) break; // early exit
      for (var e = g.adjOffset[u]; e < g.adjOffset[u + 1]; e++) {
        final w = g.adjTime[e];
        if (w == double.infinity) continue;
        if (isBlocked(e, realTime[u], at)) continue;
        if (isAccessBlocked(u, e)) continue;
        final v = g.adjTarget[e];
        final nd = d + w * penalty[e];
        if (nd < dist[v]) {
          dist[v] = nd;
          realTime[v] = realTime[u] + w;
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
    var signalCount = 0;
    for (var i = 0; i < path.edges.length; i++) {
      final e = path.edges[i];
      tollCount += g.adjToll[e];
      signalCount += g.adjSignal[e];
      geometry.addAll(g.geometryOf(e));
      geometry.add(g.coordinateOf(path.vertices[i + 1]));
    }
    return GeoRoute(
      distanceMeters: path.distanceMeters,
      // Already includes the waiting at the junctions counted above: the delay
      // is part of each edge's weight, so the search minimised it and
      // `timeSeconds` carries it without anything being added here.
      duration: Duration(microseconds: (path.timeSeconds * 1e6).round()),
      geometry: geometry,
      tollCount: tollCount,
      signalCount: signalCount,
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
