import 'dart:typed_data';

import 'package:geo_osm_pbf/geo_osm_pbf.dart';

import 'graph_types.dart';

/// Statistics describing a single compression pass.
class CompressionStats {
  final int nodesBefore;
  final int nodesAfter;
  final int edgesBefore;
  final int edgesAfter;

  const CompressionStats({
    required this.nodesBefore,
    required this.nodesAfter,
    required this.edgesBefore,
    required this.edgesAfter,
  });

  /// Fraction of vertices removed, in `[0, 1]`.
  double get nodeReduction =>
      nodesBefore == 0 ? 0 : 1 - nodesAfter / nodesBefore;

  /// Fraction of edges removed, in `[0, 1]`.
  double get edgeReduction =>
      edgesBefore == 0 ? 0 : 1 - edgesAfter / edgesBefore;

  @override
  String toString() =>
      'CompressionStats(nodes $nodesBefore -> $nodesAfter '
      '(${(nodeReduction * 100).toStringAsFixed(1)}% removed), '
      'edges $edgesBefore -> $edgesAfter '
      '(${(edgeReduction * 100).toStringAsFixed(1)}% removed))';
}

/// Shrinks a [RoutingGraph] without changing the shortest paths it encodes.
///
/// Two transformations are applied:
///
/// 1. **Island removal.** Connected components smaller than
///    [minComponentNodes] (and, optionally, every component except the largest)
///    are discarded. These are usually digitisation artefacts or unreachable
///    fragments that only waste space.
/// 2. **Chain compression.** Runs of degree-2 "pass-through" vertices (the long
///    interior of a road between two intersections) are collapsed into a single
///    edge whose weight is the sum of the collapsed segments. The removed
///    vertices' coordinates are retained as the edge's geometry, so the returned
///    route still traces the exact road shape.
///
/// Typical OSM extracts shrink by 80–95% in vertex count, which is the dominant
/// factor in both load time and search speed.
class GraphCompressor {
  /// Components with fewer than this many vertices are dropped.
  final int minComponentNodes;

  /// When `true`, every component except the single largest is dropped.
  final bool keepLargestComponentOnly;

  GraphCompressor({
    this.minComponentNodes = 2,
    this.keepLargestComponentOnly = false,
  });

  /// The statistics of the most recent [compress] call, or `null`.
  CompressionStats? get lastStats => _lastStats;
  CompressionStats? _lastStats;

  /// Returns a compressed copy of [g].
  RoutingGraph compress(RoutingGraph g) {
    final n = g.nodeCount;

    // --- Reverse adjacency (CSR) so we can inspect in-edges. ---
    final revOffset = Int32List(n + 1);
    for (var e = 0; e < g.edgeCount; e++) {
      revOffset[g.adjTarget[e] + 1]++;
    }
    for (var i = 0; i < n; i++) {
      revOffset[i + 1] += revOffset[i];
    }
    final revSource = Int32List(g.edgeCount);
    final cursor = Int32List.fromList(revOffset);
    for (var u = 0; u < n; u++) {
      for (var e = g.adjOffset[u]; e < g.adjOffset[u + 1]; e++) {
        final v = g.adjTarget[e];
        revSource[cursor[v]++] = u;
      }
    }

    // --- Connected components via union-find (undirected view). ---
    final parent = Int32List(n);
    for (var i = 0; i < n; i++) {
      parent[i] = i;
    }
    int find(int x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
      }
      return x;
    }

    void union(int a, int b) {
      final ra = find(a);
      final rb = find(b);
      if (ra != rb) parent[ra] = rb;
    }

    for (var u = 0; u < n; u++) {
      for (var e = g.adjOffset[u]; e < g.adjOffset[u + 1]; e++) {
        union(u, g.adjTarget[e]);
      }
    }
    final compSize = <int, int>{};
    for (var i = 0; i < n; i++) {
      final r = find(i);
      compSize[r] = (compSize[r] ?? 0) + 1;
    }
    int largestRoot = -1;
    int largestSize = -1;
    compSize.forEach((root, size) {
      if (size > largestSize) {
        largestSize = size;
        largestRoot = root;
      }
    });

    bool keepVertex(int v) {
      final r = find(v);
      if (keepLargestComponentOnly) return r == largestRoot;
      return (compSize[r] ?? 0) >= minComponentNodes;
    }

    // --- Classify pass-through vertices. ---
    //
    // A junction that has been split for a turn restriction is pinned, along
    // with every copy of it, and both halves of that matter.
    //
    // The parent, because retargeting an approach onto a copy *lowers the
    // junction's in-degree*: a crossroads that was (2,2) can become (1,1) and
    // be contracted away, taking with it the vertex every copy's
    // `splitParent` points at and the place a route would snap to.
    //
    // A copy carrying a condition, because the query-time check reads
    // `adjCond` on an edge leaving it — and a contracted vertex is one a
    // shortcut can span, which would hide the very edge the check is for.
    // A copy with no condition is free to collapse, and usually does: an
    // `only_*` copy has one way in and one way out, so the chain walk merges
    // approach and exit into a single edge that says "arriving this way, you
    // continue that way" — the restriction, at no cost in vertices.
    final pinned = _pinnedVertices(g);

    final contractible = List<bool>.filled(n, false);
    for (var v = 0; v < n; v++) {
      if (!keepVertex(v)) continue;
      if (pinned[v]) continue;
      final outDeg = g.adjOffset[v + 1] - g.adjOffset[v];
      final inDeg = revOffset[v + 1] - revOffset[v];
      if (outDeg == 2 && inDeg == 2) {
        final o0 = g.adjTarget[g.adjOffset[v]];
        final o1 = g.adjTarget[g.adjOffset[v] + 1];
        final i0 = revSource[revOffset[v]];
        final i1 = revSource[revOffset[v] + 1];
        final outSet = {o0, o1};
        final inSet = {i0, i1};
        if (outSet.length == 2 &&
            !outSet.contains(v) &&
            _setEquals(outSet, inSet)) {
          contractible[v] = true;
        }
      } else if (outDeg == 1 && inDeg == 1) {
        final b = g.adjTarget[g.adjOffset[v]];
        final a = revSource[revOffset[v]];
        if (a != b && a != v && b != v) {
          contractible[v] = true;
        }
      }
    }

    // --- Walk chains starting from every anchor (kept, non-contractible). ---
    final merged = <_MergedEdge>[];
    int findOut(int cur, int prev) {
      for (var e = g.adjOffset[cur]; e < g.adjOffset[cur + 1]; e++) {
        if (g.adjTarget[e] != prev) return e;
      }
      return -1;
    }

    for (var a = 0; a < n; a++) {
      if (!keepVertex(a) || contractible[a]) continue;
      for (var e = g.adjOffset[a]; e < g.adjOffset[a + 1]; e++) {
        var prev = a;
        var cur = g.adjTarget[e];
        var dist = g.adjDist[e];
        var time = g.adjTime[e];
        var tolls = g.adjToll[e];
        var signals = g.adjSignal[e];
        final condition = g.conditionOf(e);
        final geom = <GeoCoordinate>[...g.geometryOf(e)];

        while (contractible[cur] && cur != a) {
          geom.add(g.coordinateOf(cur));
          final nextEdge = findOut(cur, prev);
          if (nextEdge < 0) break;
          prev = cur;
          dist += g.adjDist[nextEdge];
          time += g.adjTime[nextEdge];
          tolls += g.adjToll[nextEdge];
          signals += g.adjSignal[nextEdge];
          geom.addAll(g.geometryOf(nextEdge));
          cur = g.adjTarget[nextEdge];
        }

        if (cur == a) continue; // drop self-loops

        // The condition of the chain's *first* edge, and only that one.
        //
        // A vertex with a conditional edge leaving it is pinned above, so it
        // is never contractible, so a chain can never continue *through* one —
        // which means no interior edge of a merge can be conditional, and the
        // first edge is the whole story. The assert states the invariant the
        // pinning creates rather than trusting it silently.
        assert(() {
          var p = a;
          var c = g.adjTarget[e];
          while (contractible[c] && c != a) {
            final next = findOut(c, p);
            if (next < 0) break;
            if ((g.adjCond?[next] ?? 0) != 0) return false;
            p = c;
            c = g.adjTarget[next];
          }
          return true;
        }(), 'a conditional edge was swallowed into the middle of a chain');

        merged.add(
          _MergedEdge(a, cur, dist, time, tolls, signals, geom, condition),
        );
      }
    }

    final result = _assemble(g, merged, keepVertex);
    _lastStats = CompressionStats(
      nodesBefore: n,
      nodesAfter: result.nodeCount,
      edgesBefore: g.edgeCount,
      edgesAfter: result.edgeCount,
    );
    return result;
  }

  RoutingGraph _assemble(
    RoutingGraph g,
    List<_MergedEdge> merged,
    bool Function(int) keepVertex,
  ) {
    // Surviving vertices are those that are an endpoint of a merged edge.
    final keptOld = <int>{};
    for (final m in merged) {
      keptOld.add(m.source);
      keptOld.add(m.target);
    }
    final sorted = keptOld.toList()
      // Tie-broken on the old index, and not optionally. Split copies share
      // their parent's `originalId`, and `List.sort` is **not stable** in
      // Dart — so without this the renumbering of an equal-id run is
      // arbitrary, and two compilations of the same input can produce
      // different bytes. That would break the package's byte-identical-output
      // guarantee and every checksum built on it.
      //
      // It also earns something: the splitter appends copies after their
      // parent, so the lowest old index in a run is always the real junction.
      ..sort((a, b) {
        final byId = g.originalId[a].compareTo(g.originalId[b]);
        return byId != 0 ? byId : a.compareTo(b);
      });
    final remap = <int, int>{};
    for (var i = 0; i < sorted.length; i++) {
      remap[sorted[i]] = i;
    }
    final n = sorted.length;

    final lat = Float64List(n);
    final lon = Float64List(n);
    final originalId = Int64List(n);
    for (var i = 0; i < n; i++) {
      final old = sorted[i];
      lat[i] = g.lat[old];
      lon[i] = g.lon[old];
      originalId[i] = g.originalId[old];
    }

    // Remapped through the renumbering, and it can only be done here because
    // `remap` exists only here. Parents are pinned above, so every copy that
    // survives has a parent that survives with it — a `splitParent` pointing
    // at a vertex the compressor removed would be worse than none at all.
    final oldSplitParent = g.splitParent;
    Int32List? splitParent;
    if (oldSplitParent != null) {
      splitParent = Int32List(n)..fillRange(0, n, -1);
      for (var i = 0; i < n; i++) {
        final parent = oldSplitParent[sorted[i]];
        if (parent >= 0) splitParent[i] = remap[parent] ?? -1;
      }
    }

    for (final m in merged) {
      m.newSource = remap[m.source]!;
      m.newTarget = remap[m.target]!;
    }
    merged.sort((a, b) {
      if (a.newSource != b.newSource) return a.newSource - b.newSource;
      if (a.newTarget != b.newTarget) return a.newTarget - b.newTarget;
      return a.dist.compareTo(b.dist);
    });

    final em = merged.length;
    final adjOffset = Int32List(n + 1);
    for (final m in merged) {
      adjOffset[m.newSource + 1]++;
    }
    for (var i = 0; i < n; i++) {
      adjOffset[i + 1] += adjOffset[i];
    }

    final adjTarget = Int32List(em);
    final adjTime = Float64List(em);
    final adjDist = Float64List(em);
    final adjToll = Uint8List(em);
    final adjSignal = Uint8List(em);
    final adjCond = Uint8List(em);
    final conditions = <String>[];
    final geomOffset = Int32List(em + 1);
    final geomBuilder = <double>[];
    for (var i = 0; i < em; i++) {
      final m = merged[i];

      final condition = m.condition;
      if (condition != null) {
        // Saturating at the byte's ceiling, for the same reason the splitter
        // does: past 255 the index wraps into a *valid-looking* value, so an
        // edge silently inherits another junction's timetable. The overflow
        // slot is an expression no parser can read, and is therefore always in
        // force.
        final at = conditions.indexOf(condition);
        if (at >= 0) {
          adjCond[i] = at + 1;
        } else if (conditions.length + 1 >=
            RoutingGraph.conditionOverflowIndex) {
          while (conditions.length < RoutingGraph.conditionOverflowIndex) {
            conditions.add(RoutingGraph.overflowCondition);
          }
          adjCond[i] = RoutingGraph.conditionOverflowIndex;
        } else {
          conditions.add(condition);
          adjCond[i] = conditions.length;
        }
      }

      adjTarget[i] = m.newTarget;
      adjTime[i] = m.time;
      adjDist[i] = m.dist;
      adjToll[i] = m.tolls;
      // Saturating: the array is a byte, and a chain with more than 255 lights
      // on it is a number nobody reads for precision anyway. The *delay* is
      // unaffected, because it lives in `time`.
      adjSignal[i] = m.signals > 255 ? 255 : m.signals;
      geomOffset[i] = geomBuilder.length ~/ 2;
      for (final c in m.geometry) {
        geomBuilder.add(c.lat);
        geomBuilder.add(c.lon);
      }
    }
    geomOffset[em] = geomBuilder.length ~/ 2;

    return RoutingGraph(
      lat: lat,
      lon: lon,
      originalId: originalId,
      adjOffset: adjOffset,
      adjTarget: adjTarget,
      adjTime: adjTime,
      adjDist: adjDist,
      adjToll: adjToll,
      adjSignal: adjSignal,
      geomCoords: Float64List.fromList(geomBuilder),
      geomOffset: geomOffset,
      splitParent: splitParent,
      adjCond: conditions.isEmpty ? null : adjCond,
      conditions: conditions,
    );
  }

  /// Vertices the chain compressor must not contract.
  ///
  /// Derived rather than stored, in O(n + m), because both reasons are already
  /// visible in the graph — see the call site for why each one matters.
  static List<bool> _pinnedVertices(RoutingGraph g) {
    final pinned = List<bool>.filled(g.nodeCount, false);

    final splitParent = g.splitParent;
    final adjCond = g.adjCond;

    // Any vertex with a conditional edge leaving it, split copy or not.
    //
    // **Scanned independently of `splitParent`, and that matters.** The two
    // fields are independent optionals: `RoutingGraph` is exported, and the
    // deserializer reads the two header flags separately with no cross-check,
    // so a graph with conditions and no split parents is a shape the types and
    // the format both permit. Returning early when `splitParent` was null left
    // *nothing* pinned for such a graph, and a conditional edge was then free
    // to be swallowed into a chain interior — where the merge keeps only the
    // first edge's condition and the restriction is silently lost.
    //
    // The query-time check reads `adjCond` on an edge leaving this vertex, and
    // a contracted vertex is one a merge can span, so the vertex has to stay.
    if (adjCond != null) {
      for (var v = 0; v < g.nodeCount; v++) {
        for (var e = g.adjOffset[v]; e < g.adjOffset[v + 1]; e++) {
          if (adjCond[e] != 0) {
            pinned[v] = true;
            break;
          }
        }
      }
    }

    if (splitParent == null) return pinned;

    // And every junction that has been split: retargeting an approach onto a
    // copy lowers the junction's in-degree, so a crossroads that drops to
    // degree 2 would otherwise be contracted out from under every copy that
    // points at it.
    for (var v = 0; v < g.nodeCount; v++) {
      final parent = splitParent[v];
      if (parent >= 0) pinned[parent] = true;
    }

    return pinned;
  }

  static bool _setEquals(Set<int> a, Set<int> b) {
    if (a.length != b.length) return false;
    for (final x in a) {
      if (!b.contains(x)) return false;
    }
    return true;
  }
}

class _MergedEdge {
  final int source;
  final int target;
  final double dist;
  final double time;
  final int tolls;

  /// Signalised junctions swallowed by the merge.
  ///
  /// A light on a degree-2 vertex — a signalised pedestrian crossing mid-block
  /// is the common case — loses its vertex here, and the count has to come
  /// with it or a street full of crossings compresses into a street with none.
  ///
  /// Its *delay* needs no special handling: that is already part of [time],
  /// which is summed along the chain like any other seconds.
  final int signals;

  final List<GeoCoordinate> geometry;

  /// The condition forbidding this movement, or null.
  ///
  /// Taken from the chain's first edge, which is the only one that can carry
  /// one — a vertex with a conditional edge leaving it is pinned, so a chain
  /// never passes through it.
  final String? condition;

  int newSource = 0;
  int newTarget = 0;
  _MergedEdge(
    this.source,
    this.target,
    this.dist,
    this.time,
    this.tolls,
    this.signals,
    this.geometry,
    this.condition,
  );
}
