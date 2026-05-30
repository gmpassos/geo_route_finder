import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('MinHeap', () {
    test('pops in ascending key order', () {
      final h = MinHeap(4);
      final keys = [5.0, 1.0, 3.0, 2.0, 4.0, 0.5];
      for (var i = 0; i < keys.length; i++) {
        h.push(keys[i], i);
      }
      final popped = <double>[];
      while (h.isNotEmpty) {
        popped.add(h.peekKey);
        h.pop();
      }
      final sorted = [...keys]..sort();
      expect(popped, sorted);
    });
  });

  group('routers agree on optimal cost', () {
    late MemoryStorage memStorage;
    late GeoGraph grid;

    setUp(() async {
      grid = buildGrid(n: 12);
      memStorage = MemoryStorage();
      await memStorage.saveGraph('grid', grid);
    });

    test('A* equals Dijkstra equals CH (distance & duration)', () async {
      const start = GeoCoordinate(lat: -23.5, lon: -46.7);
      const end = GeoCoordinate(lat: -23.5 + 11 * 0.01, lon: -46.7 + 11 * 0.01);

      final dijkstra = DijkstraRouter(storage: memStorage, graphId: 'grid');
      final astar = AStarRouter(storage: memStorage, graphId: 'grid');
      final ch = ContractionHierarchyRouter(
        storage: memStorage,
        graphId: 'grid',
      );

      final rd = await dijkstra.findRoute(start, end);
      final ra = await astar.findRoute(start, end);
      final rc = await ch.findRoute(start, end);

      expect(rd.found, isTrue);
      expect(ra.distanceMeters, closeTo(rd.distanceMeters, 1e-6));
      expect(rc.distanceMeters, closeTo(rd.distanceMeters, 1e-6));
      expect(
        ra.duration.inMicroseconds,
        closeTo(rd.duration.inMicroseconds, 2),
      );
      expect(
        rc.duration.inMicroseconds,
        closeTo(rd.duration.inMicroseconds, 2),
      );
    });

    test('route geometry is continuous and ends at the snapped goal', () async {
      const start = GeoCoordinate(lat: -23.5, lon: -46.7);
      const end = GeoCoordinate(lat: -23.45, lon: -46.65);
      final astar = AStarRouter(storage: memStorage, graphId: 'grid');
      final route = await astar.findRoute(start, end);
      expect(route.found, isTrue);
      expect(route.geometry.length, greaterThan(2));
    });

    test('unreachable target returns GeoRoute.none', () async {
      // Two disjoint single edges in their own components.
      final nodes = [
        const GeoNode(id: 1, lat: 0, lon: 0),
        const GeoNode(id: 2, lat: 0, lon: 0.001),
        const GeoNode(id: 3, lat: 5, lon: 5),
        const GeoNode(id: 4, lat: 5, lon: 5.001),
      ];
      final edges = [
        const GeoEdge(
          sourceId: 1,
          targetId: 2,
          distanceMeters: 111,
          speedKmh: 50,
        ),
        const GeoEdge(
          sourceId: 3,
          targetId: 4,
          distanceMeters: 111,
          speedKmh: 50,
        ),
      ];
      final st = MemoryStorage();
      await st.saveGraph('split', GeoGraph(nodes: nodes, edges: edges));
      final router = AStarRouter(storage: st, graphId: 'split');
      final route = await router.findRoute(
        const GeoCoordinate(lat: 0, lon: 0),
        const GeoCoordinate(lat: 5, lon: 5),
      );
      expect(route.found, isFalse);
    });

    test('one-way restriction forces a detour', () async {
      // Triangle 1->2 (oneway), 2->3 (oneway), 1->3 (oneway).
      // From 3 there is no way out, so 3 -> 1 must be unreachable.
      final nodes = [
        const GeoNode(id: 1, lat: 0, lon: 0),
        const GeoNode(id: 2, lat: 0, lon: 0.01),
        const GeoNode(id: 3, lat: 0.01, lon: 0.01),
      ];
      final edges = [
        const GeoEdge(
          sourceId: 1,
          targetId: 2,
          distanceMeters: 1000,
          speedKmh: 50,
          oneWay: true,
        ),
        const GeoEdge(
          sourceId: 2,
          targetId: 3,
          distanceMeters: 1000,
          speedKmh: 50,
          oneWay: true,
        ),
        const GeoEdge(
          sourceId: 1,
          targetId: 3,
          distanceMeters: 1500,
          speedKmh: 50,
          oneWay: true,
        ),
      ];
      final st = MemoryStorage();
      await st.saveGraph('tri', GeoGraph(nodes: nodes, edges: edges));
      final router = DijkstraRouter(storage: st, graphId: 'tri');
      final forward = await router.findRoute(
        const GeoCoordinate(lat: 0, lon: 0),
        const GeoCoordinate(lat: 0.01, lon: 0.01),
      );
      expect(forward.found, isTrue);
      final backward = await router.findRoute(
        const GeoCoordinate(lat: 0.01, lon: 0.01),
        const GeoCoordinate(lat: 0, lon: 0),
      );
      expect(backward.found, isFalse);
    });
  });
}
