import 'dart:typed_data';

import 'package:geo_osm_pbf/geo_osm_pbf.dart';

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

  /// Number of signalised junctions entered by traversing each edge
  /// (`0` = none), length [edgeCount].
  ///
  /// **The delay is already folded into [adjTime]** — this array is what a
  /// route *reports*, not what it costs. Charging it again at query time would
  /// count every light twice.
  ///
  /// Counts accumulate when degree-2 chains are collapsed, exactly as
  /// [adjToll] does: a light at a vertex the compressor removes has to survive
  /// the removal, or a street's worth of junctions vanishes from the answer.
  final Uint8List adjSignal;

  /// Per-edge intermediate geometry, interleaved `lat, lon` pairs. The points
  /// for edge `e` are `[geomOffset[e], geomOffset[e+1])` measured in *points*
  /// (each point being two consecutive doubles in [geomCoords]). Endpoints are
  /// excluded — they are recovered from [lat]/[lon] of the edge's vertices.
  final Float64List geomCoords;

  /// CSR row pointers into [geomCoords], length `edgeCount + 1`, in points.
  final Int32List geomOffset;

  /// For each vertex, the junction it is a restricted copy of, or `-1`.
  ///
  /// **A turn restriction is topology here, not a rule checked during
  /// search.** A junction with a forbidden movement is split: the approach
  /// that may not turn is retargeted to a copy of the junction which simply
  /// has no edge for the forbidden exit. Nothing in Dijkstra, A* or the
  /// contraction hierarchy needs to know — an illegal turn is not expensive,
  /// it is absent — and a CH shortcut cannot bake in a movement the graph
  /// never contained.
  ///
  /// Copies share their parent's coordinate and [originalId], and are kept out
  /// of the spatial index: they are the *same place*, and snapping to one
  /// would start a route already committed to an approach it never made.
  ///
  /// Null when the graph carries no restrictions, which is the common case and
  /// costs nothing.
  final Int32List? splitParent;

  /// For each directed edge, the condition that forbids it, or `0`.
  ///
  /// Non-zero is a 1-based index into [conditions]. A conditional restriction
  /// cannot be topology — one graph has to answer both "restricted now" and
  /// "not restricted now" — so the edge stays and carries a flag instead.
  ///
  /// **One byte per edge is exact only because of the split.** The movement is
  /// already isolated onto a copy of the junction, so "this edge, from this
  /// approach" is fully determined by the edge alone. Without the split this
  /// would have to be keyed by edge *pairs*, and the search would need a state
  /// per incoming edge.
  final Uint8List? adjCond;

  /// Whether each directed edge may only be used to reach something on it.
  ///
  /// A driveway, a parking aisle, a track, a road signed `access=destination`.
  /// One byte per edge, beside [adjToll] and [adjSignal].
  ///
  /// This one could not become topology the way turn restrictions did. A
  /// forbidden turn is forbidden for everyone, always, so removing the edge
  /// states it exactly; whether a driveway may be used depends on where the
  /// route starts and ends, which is not known until someone asks. So the flag
  /// travels with the graph and the search reads it.
  final Uint8List adjAccess;

  /// The highest condition index a byte can carry, reserved to mean "in force
  /// whenever anyone asks".
  ///
  /// [adjCond] is one byte per edge, so a graph cannot distinguish more than
  /// 255 conditions. Past that the index would wrap — silently, since a
  /// wrapped value is still in range: one edge's condition would vanish
  /// (the turn permanently open) and others would be evaluated against **some
  /// other junction's timetable**. Both are wrong answers that no check would
  /// catch.
  ///
  /// So the last slot is a sentinel instead. Everything beyond the cap maps to
  /// it, and it holds an expression no parser can read — which
  /// `ConditionalRestriction` treats as always in force. The overflow
  /// therefore over-restricts, which is the same direction every other
  /// decision here leans.
  static const int conditionOverflowIndex = 255;

  /// The sentinel expression [conditionOverflowIndex] points at.
  static const String overflowCondition = 'restriction:unrepresentable';

  /// The distinct `restriction:conditional` expressions [adjCond] indexes.
  ///
  /// Kept as written, because they are evaluated against the clock a query
  /// supplies rather than resolved at build time.
  final List<String> conditions;

  RoutingGraph({
    required this.lat,
    required this.lon,
    required this.originalId,
    required this.adjOffset,
    required this.adjTarget,
    required this.adjTime,
    required this.adjDist,
    required this.adjToll,
    required this.adjSignal,
    required this.adjAccess,
    required this.geomCoords,
    required this.geomOffset,
    this.splitParent,
    this.adjCond,
    this.conditions = const [],
  });

  /// Whether vertex [v] is a restricted copy rather than a real junction.
  bool isSplitCopy(int v) => (splitParent?[v] ?? -1) >= 0;

  /// The condition forbidding edge [e], or null when it is unconditional.
  String? conditionOf(int e) {
    final index = adjCond?[e] ?? 0;
    if (index == 0) return null;

    if (index > conditions.length) {
      // Not reachable through either producer: the splitter allocates every
      // index it writes, and the deserializer refuses a graph whose edges
      // point past its table. Kept because this runs inside the relaxation
      // loops, where throwing would abandon a whole search over one bad byte.
      // An index with no expression behind it bans the turn outright, which is
      // the reading that cannot hand back an illegal route.
      assert(false, 'edge $e names condition $index of ${conditions.length}');
      return overflowCondition;
    }
    return conditions[index - 1];
  }

  int get nodeCount => lat.length;
  int get edgeCount => adjTarget.length;

  /// Number of toll sections on edge [e].
  int tollsOf(int e) => adjToll[e];

  /// Whether edge [e] crosses at least one toll.
  bool isToll(int e) => adjToll[e] != 0;

  /// Whether edge [e] may only be used to reach something on it.
  ///
  /// True for a driveway, a parking aisle, a track, or a way signed
  /// `access=destination` and its relatives. A search may use a run of these
  /// at the start or the end of a route and nowhere in between.
  bool isAccessOnly(int e) => adjAccess[e] != 0;

  /// Number of signalised junctions entered by traversing edge [e].
  int signalsOf(int e) => adjSignal[e];

  /// Whether traversing edge [e] arrives at a set of lights.
  bool hasSignal(int e) => adjSignal[e] != 0;

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
