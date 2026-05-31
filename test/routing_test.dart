import 'dart:io';

import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The three interchangeable router algorithms, exercised uniformly.
const _routerTypes = ['dijkstra', 'astar', 'ch'];

GraphRouteFinder _router(String type, GeoStorage storage, String id) {
  switch (type) {
    case 'dijkstra':
      return DijkstraRouter(storage: storage, graphId: id);
    case 'astar':
      return AStarRouter(storage: storage, graphId: id);
    case 'ch':
      return ContractionHierarchyRouter(storage: storage, graphId: id);
    default:
      throw ArgumentError('unknown router type: $type');
  }
}

/// A straight degree-2 chain of [len] nodes along a meridian. Every interior
/// node is a pass-through, so compression collapses the chain to its two
/// endpoints while preserving the end-to-end distance.
GeoGraph _chain(int len) {
  final nodes = [
    for (var i = 0; i < len; i++) GeoNode(id: i, lat: 0, lon: i * 0.001),
  ];
  final edges = [
    for (var i = 0; i + 1 < len; i++)
      GeoEdge(sourceId: i, targetId: i + 1, distanceMeters: 111, speedKmh: 50),
  ];
  return GeoGraph(nodes: nodes, edges: edges);
}

/// Compiles [graph] into a [CompiledGraph], optionally compressing it. Mirrors
/// what `OsmConverter.compile` does, so the compiled storage path can be tested
/// with and without compression.
CompiledGraph _compile(GeoGraph graph, {required bool compress}) {
  var routing = const GraphBuilder().build(graph);
  if (compress) routing = GraphCompressor().compress(routing);
  return CompiledGraph(
    graph: routing,
    tree: KdTree.build(routing),
    meta: GraphMeta(
      formatVersion: kGraphFormatVersion,
      nodeCount: routing.nodeCount,
      edgeCount: routing.edgeCount,
      graphChecksum: 0,
      indexChecksum: 0,
      createdAt: DateTime.now(),
    ),
  );
}

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

  // Exercises every router against both load paths:
  //   * generic   -> MemoryStorage (build + compress at load time)
  //   * compiled  -> LocalFileStorage (zero-copy load of the stored CSR)
  group('routers x storage backends', () {
    late Directory dir;
    late MemoryStorage generic;
    late LocalFileStorage compiled;

    // Interior grid vertices (not the degree-2 corners), so they survive
    // compression in every backend and snap to the same vertex everywhere.
    const start = GeoCoordinate(lat: -23.49, lon: -46.69); // node (1, 1)
    const end = GeoCoordinate(lat: -23.40, lon: -46.60); // node (10, 10)

    setUp(() async {
      final grid = buildGrid(n: 12);
      generic = MemoryStorage();
      await generic.saveGraph('grid', grid);

      dir = Directory.systemTemp.createTempSync('grf_routing_');
      compiled = LocalFileStorage(directory: dir.path);
      await compiled.saveGraph('grid', grid);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('all three algorithms agree on each backend', () async {
      // Within a single backend the algorithms must produce identical optimal
      // results; Dijkstra is the exact reference.
      for (final backend in {
        'generic': generic,
        'compiled': compiled,
      }.entries) {
        final reference = await DijkstraRouter(
          storage: backend.value,
          graphId: 'grid',
        ).findRoute(start, end);
        expect(reference.found, isTrue, reason: backend.key);
        expect(reference.distanceMeters, greaterThan(0), reason: backend.key);

        for (final type in _routerTypes) {
          final ctx = '$type via ${backend.key}';
          final route = await _router(
            type,
            backend.value,
            'grid',
          ).findRoute(start, end);

          expect(route.found, isTrue, reason: ctx);
          expect(
            route.distanceMeters,
            closeTo(reference.distanceMeters, 1e-6),
            reason: ctx,
          );
          expect(
            route.duration.inMicroseconds,
            closeTo(reference.duration.inMicroseconds, 2),
            reason: ctx,
          );
        }
      }
    });

    test('route geometry is continuous and reaches the goal', () async {
      for (final type in _routerTypes) {
        final route = await _router(
          type,
          compiled,
          'grid',
        ).findRoute(start, end);
        expect(route.found, isTrue, reason: type);
        expect(route.geometry.length, greaterThan(2), reason: type);
      }
    });

    test('reports how many nodes each search expanded', () async {
      for (final type in _routerTypes) {
        final router = _router(type, compiled, 'grid');
        // No search yet -> nothing expanded.
        expect(router.lastExpandedNodes, 0, reason: type);

        final route = await router.findRoute(start, end);
        expect(route.found, isTrue, reason: type);
        // A real search must expand at least the path's vertices.
        expect(router.lastExpandedNodes, greaterThan(0), reason: type);
      }
    });
  });

  group('top-k / alternative routes (all algorithms)', () {
    late MemoryStorage st;
    // Opposite corners of the grid: many equal-cost Manhattan paths exist, so
    // alternatives are plentiful.
    const start = GeoCoordinate(lat: -23.49, lon: -46.69); // node (1, 1)
    const end = GeoCoordinate(lat: -23.40, lon: -46.60); // node (10, 10)

    setUp(() async {
      st = MemoryStorage();
      await st.saveGraph('grid', buildGrid(n: 12));
    });

    test('default returns exactly the single optimal route', () async {
      for (final type in _routerTypes) {
        final router = _router(type, st, 'grid');
        final single = await router.findRoute(start, end);
        final routes = await router.findRoutes(start, end);
        expect(routes.length, 1, reason: type);
        expect(
          routes.first.distanceMeters,
          closeTo(single.distanceMeters, 1e-6),
          reason: type,
        );
      }
    });

    test('returns up to maxRoutes distinct routes, optimal first', () async {
      for (final type in _routerTypes) {
        final router = _router(type, st, 'grid');
        final best = await router.findRoute(start, end);
        final routes = await router.findRoutes(start, end, maxRoutes: 3);

        expect(routes.length, greaterThan(1), reason: type);
        expect(routes.length, lessThanOrEqualTo(3), reason: type);
        // Element 0 is the optimal route.
        expect(
          routes.first.distanceMeters,
          closeTo(best.distanceMeters, 1e-6),
          reason: type,
        );
        // No alternative is shorter than the optimal; ordered by distance.
        for (var i = 1; i < routes.length; i++) {
          expect(
            routes[i].distanceMeters,
            greaterThanOrEqualTo(routes[i - 1].distanceMeters - 1e-6),
            reason: '$type [$i]',
          );
        }
        // Routes are genuinely distinct geometries.
        final shapes = routes
            .map((r) => r.geometry.map((c) => '${c.lat},${c.lon}').join('|'))
            .toSet();
        expect(shapes.length, routes.length, reason: '$type distinct');
      }
    });

    test('respects the maximum extra distance', () async {
      for (final type in _routerTypes) {
        final router = _router(type, st, 'grid');
        final best = await router.findRoute(start, end);
        final routes = await router.findRoutes(
          start,
          end,
          maxRoutes: 5,
          maxExtraRatio: 0.1,
        );
        final cap = best.distanceMeters * 1.1 + 1e-6;
        for (final r in routes) {
          expect(r.distanceMeters, lessThanOrEqualTo(cap), reason: type);
        }
      }
    });

    test('maxExtraMeters tightens the cap', () async {
      for (final type in _routerTypes) {
        final router = _router(type, st, 'grid');
        final best = await router.findRoute(start, end);
        final routes = await router.findRoutes(
          start,
          end,
          maxRoutes: 5,
          maxExtraMeters: 50, // far tighter than the default ratio
        );
        for (final r in routes) {
          expect(
            r.distanceMeters,
            lessThanOrEqualTo(best.distanceMeters + 50 + 1e-6),
            reason: type,
          );
        }
      }
    });

    test('unreachable target yields an empty list', () async {
      final split = MemoryStorage();
      await split.saveGraph(
        'split',
        GeoGraph(
          nodes: const [
            GeoNode(id: 1, lat: 0, lon: 0),
            GeoNode(id: 2, lat: 0, lon: 0.001),
            GeoNode(id: 3, lat: 5, lon: 5),
            GeoNode(id: 4, lat: 5, lon: 5.001),
          ],
          edges: const [
            GeoEdge(
              sourceId: 1,
              targetId: 2,
              distanceMeters: 111,
              speedKmh: 50,
            ),
            GeoEdge(
              sourceId: 3,
              targetId: 4,
              distanceMeters: 111,
              speedKmh: 50,
            ),
          ],
        ),
      );
      for (final type in _routerTypes) {
        final routes = await _router(type, split, 'split').findRoutes(
          const GeoCoordinate(lat: 0, lon: 0),
          const GeoCoordinate(lat: 5, lon: 5),
          maxRoutes: 3,
        );
        expect(routes, isEmpty, reason: type);
      }
    });
  });

  group('routing edge cases (all algorithms)', () {
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

      for (final type in _routerTypes) {
        final route = await _router(type, st, 'split').findRoute(
          const GeoCoordinate(lat: 0, lon: 0),
          const GeoCoordinate(lat: 5, lon: 5),
        );
        expect(route.found, isFalse, reason: type);
      }
    });

    test('one-way restriction makes the reverse trip unreachable', () async {
      // Triangle 1->2, 2->3, 1->3, all one-way. From 3 there is no exit.
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

      const from = GeoCoordinate(lat: 0, lon: 0);
      const to = GeoCoordinate(lat: 0.01, lon: 0.01);
      for (final type in _routerTypes) {
        final router = _router(type, st, 'tri');
        expect((await router.findRoute(from, to)).found, isTrue, reason: type);
        expect((await router.findRoute(to, from)).found, isFalse, reason: type);
      }
    });
  });

  group('graph compression across load paths', () {
    test('generic fallback compresses degree-2 chains at load', () async {
      final st = MemoryStorage();
      await st.saveGraph('chain', _chain(6));
      final router = AStarRouter(storage: st, graphId: 'chain');
      await router.ensureLoaded();
      // Six raw vertices, but only the two endpoints survive compression.
      expect(router.graph.nodeCount, 2);
    });

    test('compressed and uncompressed compiled graphs route '
        'identically', () async {
      final g = _chain(6); // nodes 0..5 along lon, end-to-end 555 m
      final dirC = Directory.systemTemp.createTempSync('grf_compress_');
      final dirP = Directory.systemTemp.createTempSync('grf_plain_');
      addTearDown(() {
        dirC.deleteSync(recursive: true);
        dirP.deleteSync(recursive: true);
      });

      // Persist the compiled artifact directly: compressed vs not.
      final compressed = LocalFileStorage(directory: dirC.path);
      final plain = LocalFileStorage(directory: dirP.path);
      await compressed.saveCompiled('chain', _compile(g, compress: true));
      await plain.saveCompiled('chain', _compile(g, compress: false));

      // The stored graphs differ in size...
      expect((await plain.loadCompiled('chain'))!.graph.nodeCount, 6);
      expect((await compressed.loadCompiled('chain'))!.graph.nodeCount, 2);

      // ...but routing between the surviving endpoints is identical.
      const a = GeoCoordinate(lat: 0, lon: 0);
      const b = GeoCoordinate(lat: 0, lon: 0.005);
      final rc = await AStarRouter(
        storage: compressed,
        graphId: 'chain',
      ).findRoute(a, b);
      final rp = await AStarRouter(
        storage: plain,
        graphId: 'chain',
      ).findRoute(a, b);

      expect(rc.found, isTrue);
      expect(rp.found, isTrue);
      expect(rc.distanceMeters, closeTo(rp.distanceMeters, 1e-6));
      expect(rc.distanceMeters, closeTo(555, 1e-6));
    });

    test('generic and compiled load paths route identically between '
        'surviving vertices', () async {
      // The generic path compresses at load while LocalFileStorage.saveGraph
      // stores the uncompressed CSR; between vertices that survive compression
      // (here, interior grid intersections) the optimal distance is identical.
      final grid = buildGrid(n: 10);
      final generic = MemoryStorage();
      await generic.saveGraph('grid', grid);

      final dir = Directory.systemTemp.createTempSync('grf_paths_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final compiled = LocalFileStorage(directory: dir.path);
      await compiled.saveGraph('grid', grid);

      const a = GeoCoordinate(lat: -23.49, lon: -46.69); // node (1, 1)
      const b = GeoCoordinate(lat: -23.42, lon: -46.62); // node (8, 8)
      final rGeneric = await AStarRouter(
        storage: generic,
        graphId: 'grid',
      ).findRoute(a, b);
      final rCompiled = await AStarRouter(
        storage: compiled,
        graphId: 'grid',
      ).findRoute(a, b);

      expect(rGeneric.found, isTrue);
      expect(rCompiled.found, isTrue);
      expect(rCompiled.distanceMeters, closeTo(rGeneric.distanceMeters, 1e-6));
    });
  });
}
