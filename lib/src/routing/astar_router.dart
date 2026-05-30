import 'dart:typed_data';

import '../model/geo_coordinate.dart';
import 'priority_queue.dart';
import 'route_finder.dart';

/// A* shortest-path over travel time, guided toward the destination.
///
/// The heuristic is the straight-line (haversine) distance to the target
/// divided by the fastest edge speed found anywhere in the graph. Dividing by
/// the global maximum speed guarantees the heuristic never overestimates the
/// real remaining travel time, so it is **admissible** and A* returns the
/// provably optimal route — identical in cost to [DijkstraRouter] but expanding
/// far fewer vertices.
///
/// Complexity is `O(E log V)` worst case, but in practice the goal-direction
/// prunes most of the graph. This is the recommended default router.
class AStarRouter extends GraphRouteFinder {
  AStarRouter({
    required super.storage,
    required super.graphId,
    super.maxSnapMeters,
  });

  double _maxSpeedMps = 1.0;

  @override
  Future<void> prepare() async {
    final g = graph;
    var best = 1.0; // floor at 1 m/s so the heuristic stays finite
    for (var e = 0; e < g.edgeCount; e++) {
      final t = g.adjTime[e];
      if (t > 0 && t.isFinite) {
        final speed = g.adjDist[e] / t;
        if (speed > best) best = speed;
      }
    }
    _maxSpeedMps = best;
  }

  double _heuristic(int v, GeoCoordinate target) =>
      haversineMeters(graph.lat[v], graph.lon[v], target.lat, target.lon) /
      _maxSpeedMps;

  @override
  RawPath search(int source, int target) {
    final g = graph;
    final n = g.nodeCount;
    final targetCoord = g.coordinateOf(target);

    final dist = Float64List(n)..fillRange(0, n, double.infinity);
    final parentEdge = Int32List(n)..fillRange(0, n, -1);
    final parentNode = Int32List(n)..fillRange(0, n, -1);
    final closed = Uint8List(n);

    final heap = MinHeap();
    dist[source] = 0;
    heap.push(_heuristic(source, targetCoord), source);

    while (heap.isNotEmpty) {
      final u = heap.pop();
      if (closed[u] == 1) continue;
      closed[u] = 1;
      if (u == target) break; // early exit: optimal once goal is closed
      final du = dist[u];
      for (var e = g.adjOffset[u]; e < g.adjOffset[u + 1]; e++) {
        final w = g.adjTime[e];
        if (w == double.infinity) continue;
        final v = g.adjTarget[e];
        if (closed[v] == 1) continue;
        final nd = du + w;
        if (nd < dist[v]) {
          dist[v] = nd;
          parentEdge[v] = e;
          parentNode[v] = u;
          heap.push(nd + _heuristic(v, targetCoord), v);
        }
      }
    }

    if (dist[target] == double.infinity) return RawPath.none;
    return reconstructForward(
      source,
      target,
      parentEdge,
      parentNode,
      dist[target],
    );
  }
}
