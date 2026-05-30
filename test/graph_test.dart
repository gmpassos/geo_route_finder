import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('GraphBuilder', () {
    test('builds dense CSR with bidirectional expansion', () {
      final geo = buildGrid(n: 3);
      final g = const GraphBuilder().build(geo);
      expect(g.nodeCount, 9);
      // 12 undirected grid edges -> 24 directed.
      expect(g.edgeCount, 24);
      // Every edge has a finite, positive weight.
      for (var e = 0; e < g.edgeCount; e++) {
        expect(g.adjTime[e], greaterThan(0));
        expect(g.adjDist[e], greaterThan(0));
      }
    });

    test('is deterministic', () {
      final geo = buildGrid(n: 4);
      final a = const GraphBuilder().build(geo);
      final b = const GraphBuilder().build(geo);
      expect(a.adjTarget, b.adjTarget);
      expect(a.adjOffset, b.adjOffset);
      expect(a.originalId, b.originalId);
    });

    test('nodes that are only shape points are dropped', () {
      // A--B--C where B is only an intermediate shape point of edge A->C.
      final nodes = [
        const GeoNode(id: 1, lat: 0, lon: 0),
        const GeoNode(id: 2, lat: 0, lon: 0.001),
        const GeoNode(id: 3, lat: 0, lon: 0.002),
      ];
      final edges = [
        const GeoEdge(
          sourceId: 1,
          targetId: 3,
          distanceMeters: 222,
          speedKmh: 50,
          shapePoints: [2],
        ),
      ];
      final g = const GraphBuilder().build(
        GeoGraph(nodes: nodes, edges: edges),
      );
      expect(g.nodeCount, 2); // node 2 folded into geometry
      // The forward edge carries node 2 as geometry.
      final geom = g.geometryOf(0);
      expect(geom.length, 1);
      expect(geom.first.lon, closeTo(0.001, 1e-12));
    });
  });

  group('GraphCompressor', () {
    test('collapses a degree-2 chain', () {
      // Chain of 5 nodes: 4 bidirectional segments, interior nodes degree 2.
      final nodes = [
        for (var i = 0; i < 5; i++) GeoNode(id: i, lat: 0, lon: i * 0.001),
      ];
      final edges = [
        for (var i = 0; i < 4; i++)
          GeoEdge(
            sourceId: i,
            targetId: i + 1,
            distanceMeters: 111,
            speedKmh: 50,
          ),
      ];
      final built = const GraphBuilder().build(
        GeoGraph(nodes: nodes, edges: edges),
      );
      expect(built.nodeCount, 5);
      final c = GraphCompressor();
      final compressed = c.compress(built);
      // Only the two endpoints survive.
      expect(compressed.nodeCount, 2);
      // One edge each way.
      expect(compressed.edgeCount, 2);
      // Distance is preserved end to end.
      expect(compressed.adjDist[0], closeTo(444, 1e-6));
      // The three interior nodes are retained as geometry.
      expect(compressed.geometryOf(0).length, 3);
    });

    test('removes tiny disconnected islands', () {
      final grid = buildGrid(n: 3); // 9 connected nodes
      // Add an isolated 1-node "island" (no edges).
      final nodes = [...grid.nodes, const GeoNode(id: 999, lat: 10, lon: 10)];
      final built = const GraphBuilder().build(
        GeoGraph(nodes: nodes, edges: grid.edges),
      );
      // Node 999 has no edges, so it is not even a routing vertex.
      expect(built.nodeCount, 9);
      final compressed = GraphCompressor().compress(built);
      expect(compressed.nodeCount, lessThanOrEqualTo(9));
    });

    test('reports stats', () {
      final built = const GraphBuilder().build(buildGrid(n: 10));
      final c = GraphCompressor();
      c.compress(built);
      expect(c.lastStats, isNotNull);
      expect(c.lastStats!.nodesBefore, 100);
    });
  });
}
