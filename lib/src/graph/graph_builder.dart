import 'dart:typed_data';

import '../model/geo_graph.dart';
import 'graph_types.dart';

/// Compiles a generic [GeoGraph] into the search-optimized [RoutingGraph].
///
/// The build is **deterministic**: given identical input it always produces
/// byte-identical output. Vertices are assigned dense indices in ascending
/// order of their original id, and edges are emitted in a stable order. This is
/// essential so that serialized graphs are reproducible and cacheable.
///
/// Only nodes that are an endpoint of at least one edge become routing
/// vertices; nodes that appear solely as intermediate shape points are resolved
/// to coordinates and folded into edge geometry. This alone removes the bulk of
/// OSM's vertices (most OSM nodes only describe road curvature).
///
/// The implementation works on flat, primitive arrays (no per-node or per-edge
/// object allocation) and sorts an index permutation rather than a list of edge
/// objects, so building a regional graph stays fast and produces little GC
/// pressure.
class GraphBuilder {
  const GraphBuilder();

  /// Builds a [RoutingGraph] from [graph].
  RoutingGraph build(GeoGraph graph) {
    final inNodes = graph.nodes;
    final inEdges = graph.edges;

    // 1. Index node coordinates by original id, into parallel primitive arrays
    //    (avoids allocating one coordinate object per node).
    final slotOf = <int, int>{};
    final nLat = Float64List(inNodes.length);
    final nLon = Float64List(inNodes.length);
    for (var i = 0; i < inNodes.length; i++) {
      final node = inNodes[i];
      slotOf[node.id] = i;
      nLat[i] = node.lat;
      nLon[i] = node.lon;
    }

    // 2. Collect the set of endpoint ids (the actual routing vertices) and
    //    assign dense indices in ascending id order for determinism.
    final endpointIds = <int>{};
    for (final e in inEdges) {
      if (slotOf.containsKey(e.sourceId) && slotOf.containsKey(e.targetId)) {
        endpointIds.add(e.sourceId);
        endpointIds.add(e.targetId);
      }
    }
    final sortedIds = endpointIds.toList()..sort();
    final indexOf = <int, int>{};
    for (var i = 0; i < sortedIds.length; i++) {
      indexOf[sortedIds[i]] = i;
    }
    final n = sortedIds.length;

    final lat = Float64List(n);
    final lon = Float64List(n);
    final originalId = Int64List(n);
    for (var i = 0; i < n; i++) {
      final id = sortedIds[i];
      final slot = slotOf[id]!;
      lat[i] = nLat[slot];
      lon[i] = nLon[slot];
      originalId[i] = id;
    }

    // 3. Count valid directed edges (each GeoEdge becomes one or two), and the
    //    resolvable shape-point count per GeoEdge, so the edge arrays can be
    //    allocated exactly once.
    final geomCount = Int32List(inEdges.length);
    var m = 0;
    for (var ei = 0; ei < inEdges.length; ei++) {
      final e = inEdges[ei];
      if (!indexOf.containsKey(e.sourceId) ||
          !indexOf.containsKey(e.targetId)) {
        continue; // dangling endpoint
      }
      var c = 0;
      for (final id in e.shapePoints) {
        if (slotOf.containsKey(id)) c++;
      }
      geomCount[ei] = c;
      m += e.oneWay ? 1 : 2;
    }

    // 4. Materialize directed edges into flat arrays. [edgeRef] records the
    //    originating GeoEdge and [reversed] whether it is the back direction,
    //    so geometry can be resolved later in sorted order without storing it
    //    twice.
    final src = Int32List(m);
    final tgt = Int32List(m);
    final dist = Float64List(m);
    final time = Float64List(m);
    final edgeRef = Int32List(m);
    final reversed = Uint8List(m);
    var k = 0;
    for (var ei = 0; ei < inEdges.length; ei++) {
      final e = inEdges[ei];
      final s = indexOf[e.sourceId];
      final t = indexOf[e.targetId];
      if (s == null || t == null) continue;
      src[k] = s;
      tgt[k] = t;
      dist[k] = e.distanceMeters;
      time[k] = e.travelTimeSeconds;
      edgeRef[k] = ei;
      reversed[k] = 0;
      k++;
      if (!e.oneWay) {
        src[k] = t;
        tgt[k] = s;
        dist[k] = e.distanceMeters;
        time[k] = e.travelTimeSeconds;
        edgeRef[k] = ei;
        reversed[k] = 1;
        k++;
      }
    }

    // 5. Build CSR offsets from per-source out-degree.
    final adjOffset = Int32List(n + 1);
    for (var i = 0; i < m; i++) {
      adjOffset[src[i] + 1]++;
    }
    for (var i = 0; i < n; i++) {
      adjOffset[i + 1] += adjOffset[i];
    }

    // 6. Stable ordering so the CSR layout is deterministic: by source, then
    //    target, then distance. Rather than a global comparator sort over all
    //    m edges (a closure invoked O(m log m) times — the dominant cost when
    //    building a regional graph), place edges into their source's CSR range
    //    by counting sort (O(m)), then insertion-sort each range by
    //    (target, distance). Road-graph out-degrees are tiny, so the per-range
    //    sorts are effectively linear overall.
    final perm = Int32List(m);
    final cursor = Int32List.fromList(adjOffset);
    for (var i = 0; i < m; i++) {
      perm[cursor[src[i]]++] = i;
    }
    for (var u = 0; u < n; u++) {
      final lo = adjOffset[u];
      final hi = adjOffset[u + 1];
      for (var i = lo + 1; i < hi; i++) {
        final cur = perm[i];
        final ct = tgt[cur];
        final cd = dist[cur];
        var j = i - 1;
        while (j >= lo) {
          final p = perm[j];
          final pt = tgt[p];
          if (pt < ct || (pt == ct && dist[p] <= cd)) break;
          perm[j + 1] = p;
          j--;
        }
        perm[j + 1] = cur;
      }
    }

    // 7. Total geometry points, to size the coordinate buffer exactly.
    var totalPoints = 0;
    for (var i = 0; i < m; i++) {
      totalPoints += geomCount[edgeRef[i]];
    }

    final adjTarget = Int32List(m);
    final adjTime = Float64List(m);
    final adjDist = Float64List(m);
    final geomOffset = Int32List(m + 1);
    final geomCoords = Float64List(totalPoints * 2);

    // 8. Emit edges and geometry in sorted (perm) order.
    var point = 0;
    for (var i = 0; i < m; i++) {
      final d = perm[i];
      adjTarget[i] = tgt[d];
      adjTime[i] = time[d];
      adjDist[i] = dist[d];
      geomOffset[i] = point;

      final shape = inEdges[edgeRef[d]].shapePoints;
      if (shape.isNotEmpty) {
        if (reversed[d] == 0) {
          for (final id in shape) {
            final slot = slotOf[id];
            if (slot != null) {
              geomCoords[point * 2] = nLat[slot];
              geomCoords[point * 2 + 1] = nLon[slot];
              point++;
            }
          }
        } else {
          for (var j = shape.length - 1; j >= 0; j--) {
            final slot = slotOf[shape[j]];
            if (slot != null) {
              geomCoords[point * 2] = nLat[slot];
              geomCoords[point * 2 + 1] = nLon[slot];
              point++;
            }
          }
        }
      }
    }
    geomOffset[m] = point;

    return RoutingGraph(
      lat: lat,
      lon: lon,
      originalId: originalId,
      adjOffset: adjOffset,
      adjTarget: adjTarget,
      adjTime: adjTime,
      adjDist: adjDist,
      geomCoords: geomCoords,
      geomOffset: geomOffset,
    );
  }
}
