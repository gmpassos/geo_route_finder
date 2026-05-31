import 'dart:typed_data';

import 'priority_queue.dart';
import 'route_finder.dart';

/// Classic Dijkstra shortest-path over travel time.
///
/// Dijkstra explores strictly in order of increasing cost and therefore expands
/// more of the graph than A*, but it requires no heuristic and is a useful
/// correctness baseline (A* must return the same optimal cost). Complexity is
/// `O(E log V)` with the binary heap.
class DijkstraRouter extends GraphRouteFinder {
  DijkstraRouter({
    required super.storage,
    required super.graphId,
    super.profile,
    super.maxSnapMeters,
  });

  @override
  RawPath search(int source, int target) {
    final g = graph;
    final n = g.nodeCount;
    final dist = Float64List(n)..fillRange(0, n, double.infinity);
    final parentEdge = Int32List(n)..fillRange(0, n, -1);
    final parentNode = Int32List(n)..fillRange(0, n, -1);

    final heap = MinHeap();
    dist[source] = 0;
    heap.push(0, source);

    var expanded = 0;
    while (heap.isNotEmpty) {
      final d = heap.peekKey;
      final u = heap.pop();
      if (d > dist[u]) continue; // stale entry
      expanded++;
      if (u == target) break; // early exit
      for (var e = g.adjOffset[u]; e < g.adjOffset[u + 1]; e++) {
        final w = g.adjTime[e];
        if (w == double.infinity) continue;
        final v = g.adjTarget[e];
        final nd = d + w;
        if (nd < dist[v]) {
          dist[v] = nd;
          parentEdge[v] = e;
          parentNode[v] = u;
          heap.push(nd, v);
        }
      }
    }

    reportExpandedNodes(expanded);
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
