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
    final contractible = List<bool>.filled(n, false);
    for (var v = 0; v < n; v++) {
      if (!keepVertex(v)) continue;
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
        final geom = <GeoCoordinate>[...g.geometryOf(e)];

        while (contractible[cur] && cur != a) {
          geom.add(g.coordinateOf(cur));
          final nextEdge = findOut(cur, prev);
          if (nextEdge < 0) break;
          prev = cur;
          dist += g.adjDist[nextEdge];
          time += g.adjTime[nextEdge];
          tolls += g.adjToll[nextEdge];
          geom.addAll(g.geometryOf(nextEdge));
          cur = g.adjTarget[nextEdge];
        }

        if (cur == a) continue; // drop self-loops
        merged.add(_MergedEdge(a, cur, dist, time, tolls, geom));
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
      ..sort((a, b) => g.originalId[a].compareTo(g.originalId[b]));
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
    final geomOffset = Int32List(em + 1);
    final geomBuilder = <double>[];
    for (var i = 0; i < em; i++) {
      final m = merged[i];
      adjTarget[i] = m.newTarget;
      adjTime[i] = m.time;
      adjDist[i] = m.dist;
      adjToll[i] = m.tolls;
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
      geomCoords: Float64List.fromList(geomBuilder),
      geomOffset: geomOffset,
    );
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
  final List<GeoCoordinate> geometry;
  int newSource = 0;
  int newTarget = 0;
  _MergedEdge(
    this.source,
    this.target,
    this.dist,
    this.time,
    this.tolls,
    this.geometry,
  );
}
