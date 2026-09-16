import 'dart:typed_data';

import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Carrying "reach it, never cross it" from the tags to the graph.
///
/// The flag has to survive three stages that each rewrite the edge array —
/// the builder, the compressor and the serializer — and it is invisible if it
/// does not: a graph whose driveways lost the flag routes perfectly well and
/// cuts through car parks, which is what it did before any of this.

void main() {
  /// A public street 1-2-3, with a driveway hanging off node 2 to node 4.
  ///
  ///     1 ——— 2 ——— 3      street
  ///           |
  ///           4            driveway
  GeoGraph street({bool driveway = true}) {
    const nodes = [
      GeoNode(id: 1, lat: -23.500, lon: -46.700),
      GeoNode(id: 2, lat: -23.500, lon: -46.690),
      GeoNode(id: 3, lat: -23.500, lon: -46.680),
      GeoNode(id: 4, lat: -23.510, lon: -46.690),
    ];

    return GeoGraph(
      nodes: nodes,
      edges: [
        const GeoEdge(
          sourceId: 1,
          targetId: 2,
          distanceMeters: 500,
          speedKmh: 36,
        ),
        const GeoEdge(
          sourceId: 2,
          targetId: 3,
          distanceMeters: 500,
          speedKmh: 36,
        ),
        GeoEdge(
          sourceId: 2,
          targetId: 4,
          distanceMeters: 500,
          speedKmh: 36,
          accessOnly: driveway,
        ),
      ],
    );
  }

  /// The flagged edges of [g], named by the OSM ids they run between.
  Set<String> flagged(RoutingGraph g) => {
    for (var v = 0; v < g.nodeCount; v++)
      for (var e = g.adjOffset[v]; e < g.adjOffset[v + 1]; e++)
        if (g.isAccessOnly(e))
          '${g.originalId[v]}->${g.originalId[g.adjTarget[e]]}',
  };

  group('from the model to the graph', () {
    test('the flag reaches both directions of the edge', () {
      // A driveway is a driveway whichever end you enter it from, so the
      // builder has to mark the back direction too — it is a separate row in
      // every per-edge array.
      final g = const GraphBuilder().build(street());

      expect(flagged(g), equals({'2->4', '4->2'}));
    });

    test('a graph without one flags nothing', () {
      final g = const GraphBuilder().build(street(driveway: false));

      expect(flagged(g), isEmpty);
      expect(g.adjAccess, hasLength(g.edgeCount));
    });
  });

  group('through the compressor', () {
    test('a chain takes the strictest reading, not the first edge', () {
      // Node 4 is degree 2 here, so 2-4-5 merges into one edge. The first step
      // is public and the second is the driveway; taking the first edge's flag
      // — which is what `condition` does — would launder the driveway behind
      // the public segment and hand back a through-route.
      final geo = GeoGraph(
        nodes: const [
          GeoNode(id: 1, lat: -23.500, lon: -46.700),
          GeoNode(id: 2, lat: -23.500, lon: -46.690),
          GeoNode(id: 3, lat: -23.500, lon: -46.680),
          GeoNode(id: 4, lat: -23.510, lon: -46.690),
          GeoNode(id: 5, lat: -23.520, lon: -46.690),
        ],
        edges: const [
          GeoEdge(sourceId: 1, targetId: 2, distanceMeters: 500, speedKmh: 36),
          GeoEdge(sourceId: 2, targetId: 3, distanceMeters: 500, speedKmh: 36),
          // Public first step...
          GeoEdge(sourceId: 2, targetId: 4, distanceMeters: 500, speedKmh: 36),
          // ...driveway second.
          GeoEdge(
            sourceId: 4,
            targetId: 5,
            distanceMeters: 500,
            speedKmh: 36,
            accessOnly: true,
          ),
        ],
      );

      final g = GraphCompressor().compress(const GraphBuilder().build(geo));

      expect(
        flagged(g),
        equals({'2->5', '5->2'}),
        reason:
            'the merged edge is the only way between 2 and 5, and part of '
            'it may only be used to reach something',
      );
    });

    test('an untouched public chain stays unflagged', () {
      final g = GraphCompressor().compress(
        const GraphBuilder().build(street(driveway: false)),
      );

      expect(flagged(g), isEmpty);
    });
  });

  group('what a route may do with one', () {
    /// A long public street, and a car park that cuts the corner.
    ///
    ///     11        12
    ///      |         |
    ///      1 ——— 5 ——— 2     public, 500 + 500 m
    ///       \         /
    ///        6 — 7 — 8 — 9   car park, 5 x 50 m
    ///            |
    ///            13
    ///
    /// Every edge of the car park — including its two entrances — is an
    /// aisle, which is how one is tagged: `service=parking_aisle` runs in from
    /// the street, round the bays, and back out.
    ///
    /// Nodes 11, 12 and 13 are stubs, and they earn their place: without them
    /// every vertex here is degree 2, the chain compressor swallows the whole
    /// ring into a self-loop and drops it, and nothing is routable at all.
    /// Node 13's stub is an aisle rather than a street, so that node 7 stays
    /// *inside* the car park — a public edge there would put it on the road
    /// network and change the answer.
    GeoGraph carPark() {
      const nodes = [
        GeoNode(id: 1, lat: -23.5000, lon: -46.7000),
        GeoNode(id: 5, lat: -23.5000, lon: -46.6950),
        GeoNode(id: 2, lat: -23.5000, lon: -46.6900),
        GeoNode(id: 6, lat: -23.5010, lon: -46.6990),
        GeoNode(id: 7, lat: -23.5010, lon: -46.6970),
        GeoNode(id: 8, lat: -23.5010, lon: -46.6950),
        GeoNode(id: 9, lat: -23.5010, lon: -46.6910),
        GeoNode(id: 11, lat: -23.4990, lon: -46.7000),
        GeoNode(id: 12, lat: -23.4990, lon: -46.6900),
        GeoNode(id: 13, lat: -23.5020, lon: -46.6970),
      ];

      GeoEdge aisle(int a, int b) => GeoEdge(
        sourceId: a,
        targetId: b,
        distanceMeters: 50,
        speedKmh: 10,
        accessOnly: true,
      );

      GeoEdge road(int a, int b, double m) =>
          GeoEdge(sourceId: a, targetId: b, distanceMeters: m, speedKmh: 36);

      return GeoGraph(
        nodes: nodes,
        edges: [
          road(1, 5, 500),
          road(5, 2, 500),
          road(1, 11, 100),
          road(2, 12, 100),
          aisle(1, 6),
          aisle(6, 7),
          aisle(7, 8),
          aisle(8, 9),
          aisle(9, 2),
          aisle(7, 13),
        ],
      );
    }

    const onStreet = GeoCoordinate(lat: -23.5000, lon: -46.7000); // node 1
    const farEnd = GeoCoordinate(lat: -23.5000, lon: -46.6900); // node 2
    const inTheCarPark = GeoCoordinate(lat: -23.5010, lon: -46.6970); // node 7

    Future<RouteFinder> routerOver(GeoGraph geo) async {
      final storage = MemoryStorage();
      await storage.saveGraph('r', geo);
      return DijkstraRouter(storage: storage, graphId: 'r');
    }

    test('a car park is not a shortcut between two streets', () async {
      // 250 m through the bays against 1000 m round the street, so the search
      // takes it every time on cost alone. Nothing about the graph's shape
      // says no — this is the whole reason the flag exists.
      final route = await (await routerOver(
        carPark(),
      )).findRoute(onStreet, farEnd);

      expect(route.found, isTrue);
      expect(
        route.distanceMeters,
        closeTo(1000, 1),
        reason: 'the street, not the bays',
      );
    });

    test('but it can be driven into, to reach something inside', () async {
      final route = await (await routerOver(
        carPark(),
      )).findRoute(onStreet, inTheCarPark);

      expect(route.found, isTrue);
      expect(route.distanceMeters, closeTo(100, 1), reason: '1-6-7');
    });

    test('and driven out of, to reach the street', () async {
      final route = await (await routerOver(
        carPark(),
      )).findRoute(inTheCarPark, farEnd);

      expect(route.found, isTrue);
      expect(
        route.distanceMeters,
        closeTo(150, 1),
        reason: '7-8-9-2, out the near side rather than back round the street',
      );
    });

    test('a route between two places inside stays inside', () async {
      final route = await (await routerOver(carPark())).findRoute(
        inTheCarPark,
        const GeoCoordinate(lat: -23.5020, lon: -46.6970), // node 13
      );

      expect(route.distanceMeters, closeTo(50, 1), reason: '7-13');
    });

    test('every router gives the same answer', () async {
      // The contraction hierarchy cannot express this rule — its shortcuts are
      // baked before anyone asks, and whether a driveway may be used depends
      // on where the route ends — so it falls back to the plain search. This
      // pins that it falls back rather than quietly answering 250.
      final storage = MemoryStorage();
      await storage.saveGraph('r', carPark());

      final routers = <RouteFinder>[
        DijkstraRouter(storage: storage, graphId: 'r'),
        AStarRouter(storage: storage, graphId: 'r'),
        ContractionHierarchyRouter(storage: storage, graphId: 'r'),
      ];

      for (final router in routers) {
        final route = await router.findRoute(onStreet, farEnd);
        expect(
          route.distanceMeters,
          closeTo(1000, 1),
          reason: '${router.runtimeType} took the bays',
        );
      }
    });

    test('without the flag the shortcut wins, which is the old bug', () async {
      // The same graph with nothing marked. Pins what the rule is worth: the
      // difference is 750 m of someone else's car park on every such journey.
      final open = GeoGraph(
        nodes: carPark().nodes,
        edges: [
          for (final e in carPark().edges)
            GeoEdge(
              sourceId: e.sourceId,
              targetId: e.targetId,
              distanceMeters: e.distanceMeters,
              speedKmh: e.speedKmh,
            ),
        ],
      );

      final route = await (await routerOver(open)).findRoute(onStreet, farEnd);
      expect(route.distanceMeters, closeTo(250, 1));
    });
  });

  group('through the v5 format', () {
    test('round-trips exactly', () {
      final g = const GraphBuilder().build(street());
      final back = const GraphDeserializer().deserializeGraph(
        const GraphSerializer().serializeGraph(g),
      );

      expect(back.adjAccess, equals(g.adjAccess));
      expect(flagged(back), equals(flagged(g)));
    });

    test('a v4 graph is refused rather than read as all-public', () {
      // The dangerous direction, and the reason this is a version bump rather
      // than an optional array. A v4 graph was built before `service=` and
      // `access=destination` were read at all, so its edges are not merely
      // unflagged — a permit-only car park is in there as a 20 km/h road.
      final bytes = const GraphSerializer().serializeGraph(
        const GraphBuilder().build(street()),
      );
      ByteData.view(bytes.buffer).setInt32(4, 4, Endian.little);

      expect(
        () => const GraphDeserializer().deserializeGraph(bytes),
        throwsA(isA<GraphFormatException>()),
      );
    });

    test('the array is one byte per directed edge', () {
      final g = const GraphBuilder().build(street());
      final bytes = const GraphSerializer().serializeGraph(g);

      // Three u8 arrays now rather than two, and no condition table here.
      final header = 32;
      final f64 = 8 * (3 * g.nodeCount + 2 * g.edgeCount + g.geomCoords.length);
      final i32 = 4 * ((g.nodeCount + 1) + g.edgeCount + (g.edgeCount + 1));

      expect(bytes.length, equals(header + f64 + i32 + 3 * g.edgeCount));
    });
  });
}
