import 'package:geo_route_finder/geo_route_finder.dart';

/// Builds an `n x n` grid graph of bidirectional [speedKmh] roads spaced
/// [step] degrees apart, anchored near São Paulo. Shared across routing,
/// spatial and serialization tests.
GeoGraph buildGrid({
  int n = 12,
  double step = 0.01,
  double speedKmh = 50,
  double originLat = -23.5,
  double originLon = -46.7,
}) {
  final nodes = <GeoNode>[];
  final edges = <GeoEdge>[];
  int id(int r, int c) => r * n + c;
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      nodes.add(
        GeoNode(
          id: id(r, c),
          lat: originLat + r * step,
          lon: originLon + c * step,
        ),
      );
    }
  }
  GeoEdge road(int a, int b) => GeoEdge(
    sourceId: a,
    targetId: b,
    distanceMeters: nodes[a].coordinate.distanceTo(nodes[b].coordinate),
    speedKmh: speedKmh,
  );
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if (c + 1 < n) edges.add(road(id(r, c), id(r, c + 1)));
      if (r + 1 < n) edges.add(road(id(r, c), id(r + 1, c)));
    }
  }
  return GeoGraph(nodes: nodes, edges: edges);
}

/// An in-memory [GeoStorage] (generic-graph only) used to exercise the
/// non-compiled fallback path in routers.
class MemoryStorage implements GeoStorage {
  final Map<String, GeoGraph> _store = {};

  @override
  Future<void> saveGraph(String id, GeoGraph graph) async => _store[id] = graph;

  @override
  Future<GeoGraph?> loadGraph(String id) async => _store[id];

  @override
  Future<bool> exists(String id) async => _store.containsKey(id);

  @override
  Future<void> delete(String id) async => _store.remove(id);
}
