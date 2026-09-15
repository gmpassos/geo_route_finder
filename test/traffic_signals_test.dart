import 'dart:io';

import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Signalised junctions in the cost model.
///
/// A route through fifteen sets of lights is genuinely slower than one through
/// three, and a router that cannot see them keeps choosing the straight run
/// down the arterial over the quiet parallel street that is actually quicker.
/// These cover the whole path a light takes: from a node id on the input
/// graph, through the per-direction charge, the chain compressor and the
/// on-disk format, to a route that says how many it passed.

/// Two nodes joined by one two-way road, with a light at [signalAt].
GeoGraph _pair({Set<int> signalAt = const {}}) => GeoGraph(
  nodes: const [
    GeoNode(id: 1, lat: -23.50, lon: -46.70),
    GeoNode(id: 2, lat: -23.50, lon: -46.69),
  ],
  edges: const [
    GeoEdge(sourceId: 1, targetId: 2, distanceMeters: 1000, speedKmh: 36),
  ],
  signalNodeIds: signalAt,
);

void main() {
  group('charging a light', () {
    test('costs the direction that arrives at it, and only that one', () {
      // The reason signals live on the graph rather than on the edge: this is
      // *one* GeoEdge, and the builder materialises both directions from it.
      final g = const GraphBuilder().build(_pair(signalAt: {2}));

      expect(g.edgeCount, equals(2));

      // By original id, not by vertex index: the builder assigns dense indices
      // of its own, and reading one as the other is how this test first lied
      // to itself.
      final toTheLight = [
        for (var e = 0; e < g.edgeCount; e++)
          if (g.originalId[g.adjTarget[e]] == 2) e,
      ].single;
      final awayFromIt = [
        for (var e = 0; e < g.edgeCount; e++)
          if (g.originalId[g.adjTarget[e]] == 1) e,
      ].single;

      expect(g.signalsOf(toTheLight), equals(1));
      expect(
        g.signalsOf(awayFromIt),
        equals(0),
        reason: 'leaving a junction is not waiting at it',
      );
    });

    test('adds its delay to the weight the routers minimise', () {
      final plain = const GraphBuilder().build(_pair());
      final lit = const GraphBuilder().build(_pair(signalAt: {2}));

      final toSignal = [
        for (var e = 0; e < lit.edgeCount; e++)
          if (lit.signalsOf(e) == 1) e,
      ].single;

      // 1000 m at 36 km/h is 100 s, plus the junction.
      expect(plain.adjTime[toSignal], closeTo(100, 0.5));
      expect(
        lit.adjTime[toSignal],
        closeTo(100 + GraphBuilder.defaultSignalDelaySeconds, 0.5),
      );
    });

    test('a zero delay still counts the junction', () {
      // What a caller needs to compare routes with and without the penalty,
      // and what keeps "how many lights" separable from "how much slower".
      final g = const GraphBuilder(
        signalDelaySeconds: 0,
      ).build(_pair(signalAt: {2}));

      final toSignal = [
        for (var e = 0; e < g.edgeCount; e++)
          if (g.signalsOf(e) == 1) e,
      ].single;

      expect(g.adjTime[toSignal], closeTo(100, 0.5));
      expect(g.signalsOf(toSignal), equals(1));
    });

    test('a graph that knows nothing about signals costs nothing extra', () {
      // The default for every source that has never heard of them.
      final g = const GraphBuilder().build(buildGrid(n: 3));

      for (var e = 0; e < g.edgeCount; e++) {
        expect(g.signalsOf(e), equals(0));
      }
    });

    test('an id that is not a routing vertex is ignored, not an error', () {
      // A light on a street this profile cannot use, or one outside the
      // extract, must not knock the build over.
      final g = const GraphBuilder().build(_pair(signalAt: {999}));

      for (var e = 0; e < g.edgeCount; e++) {
        expect(g.signalsOf(e), equals(0));
      }
    });
  });

  group('surviving compression', () {
    test('a light on a collapsed vertex keeps its count and its delay', () {
      // A signalised pedestrian crossing mid-block sits on a degree-2 vertex,
      // which is exactly what the compressor removes. Lose the count here and
      // a street full of crossings compresses into a street with none.
      final geo = GeoGraph(
        nodes: const [
          GeoNode(id: 1, lat: -23.50, lon: -46.70),
          GeoNode(id: 2, lat: -23.50, lon: -46.69),
          GeoNode(id: 3, lat: -23.50, lon: -46.68),
        ],
        edges: const [
          GeoEdge(sourceId: 1, targetId: 2, distanceMeters: 500, speedKmh: 36),
          GeoEdge(sourceId: 2, targetId: 3, distanceMeters: 500, speedKmh: 36),
        ],
        // Vertex 2 is the degree-2 one in the middle.
        signalNodeIds: const {2},
      );

      final built = const GraphBuilder().build(geo);
      final compressed = GraphCompressor().compress(built);

      final before = [
        for (var e = 0; e < built.edgeCount; e++) built.signalsOf(e),
      ].fold<int>(0, (a, b) => a + b);

      final after = [
        for (var e = 0; e < compressed.edgeCount; e++) compressed.signalsOf(e),
      ].fold<int>(0, (a, b) => a + b);

      expect(before, equals(2), reason: 'one per direction of arrival');
      expect(
        after,
        equals(before),
        reason: 'the junction has to survive losing its vertex',
      );
    });
  });

  group('on disk', () {
    test('signal counts round-trip through serialization', () {
      final g = const GraphBuilder().build(_pair(signalAt: {2}));

      final serializer = const GraphSerializer();
      final restored = const GraphDeserializer().deserializeGraph(
        serializer.serializeGraph(g),
      );

      expect(restored.adjSignal, equals(g.adjSignal));
      expect(restored.adjTime, equals(g.adjTime));
    });

    test('the format version moved, so old graphs are refused', () {
      // A v2 graph's `adjTime` was computed with no signal delay in it.
      // Reading one as a v3 would give routes whose cost silently disagrees
      // with every route planned since — and nothing in the file would say so.
      expect(kGraphFormatVersion, greaterThanOrEqualTo(3));
    });
  });

  group('the point of the exercise', () {
    /// Routes through the real entry point: stored graph, compiled and
    /// compressed by the router itself, snapped from coordinates.
    Future<GeoRoute> routeOf(GeoGraph geo, int fromId, int toId) async {
      final storage = MemoryStorage();
      await storage.saveGraph('signals', geo);

      final from = geo.nodes.firstWhere((n) => n.id == fromId).coordinate;
      final to = geo.nodes.firstWhere((n) => n.id == toId).coordinate;

      return DijkstraRouter(
        storage: storage,
        graphId: 'signals',
      ).findRoute(from, to);
    }

    test(
      'a longer way round wins when the short way is full of lights',
      () async {
        // Two ways from 1 to 4. The direct road is 3 km through two signalised
        // junctions; the parallel street is 3.15 km through none. At 36 km/h
        // that is 300 s against 315 s, so without the delay the direct road wins
        // on time as well as distance — which is exactly the choice a router
        // blind to lights makes, and exactly the one riders complain about.
        //
        // The lights sit at 2 and 3 only. Putting one on the shared destination
        // would charge both routes and prove nothing.
        // Nodes 0 and 5 are stubs, and they are load-bearing: without them
        // every vertex here has degree 2, the whole corridor is one cycle, and
        // the chain compressor contracts it out of existence before any router
        // sees it. A junction needs a third road to stay a junction.
        GeoGraph corridor({required bool lights}) => GeoGraph(
          nodes: const [
            GeoNode(id: 0, lat: -23.500, lon: -46.705),
            GeoNode(id: 1, lat: -23.500, lon: -46.700),
            GeoNode(id: 2, lat: -23.500, lon: -46.690),
            GeoNode(id: 3, lat: -23.500, lon: -46.680),
            GeoNode(id: 4, lat: -23.500, lon: -46.670),
            GeoNode(id: 5, lat: -23.500, lon: -46.665),
            GeoNode(id: 10, lat: -23.505, lon: -46.694),
            GeoNode(id: 11, lat: -23.505, lon: -46.676),
          ],
          edges: const [
            GeoEdge(
              sourceId: 0,
              targetId: 1,
              distanceMeters: 500,
              speedKmh: 36,
            ),
            GeoEdge(
              sourceId: 4,
              targetId: 5,
              distanceMeters: 500,
              speedKmh: 36,
            ),
            GeoEdge(
              sourceId: 1,
              targetId: 2,
              distanceMeters: 1000,
              speedKmh: 36,
            ),
            GeoEdge(
              sourceId: 2,
              targetId: 3,
              distanceMeters: 1000,
              speedKmh: 36,
            ),
            GeoEdge(
              sourceId: 3,
              targetId: 4,
              distanceMeters: 1000,
              speedKmh: 36,
            ),
            GeoEdge(
              sourceId: 1,
              targetId: 10,
              distanceMeters: 1050,
              speedKmh: 36,
            ),
            GeoEdge(
              sourceId: 10,
              targetId: 11,
              distanceMeters: 1050,
              speedKmh: 36,
            ),
            GeoEdge(
              sourceId: 11,
              targetId: 4,
              distanceMeters: 1050,
              speedKmh: 36,
            ),
          ],
          signalNodeIds: lights ? const {2, 3} : const {},
        );

        final withoutLights = await routeOf(corridor(lights: false), 1, 4);
        final withLights = await routeOf(corridor(lights: true), 1, 4);

        expect(withoutLights.found, isTrue);
        expect(withLights.found, isTrue);

        // No lights: the shorter, faster direct road, as before.
        expect(withoutLights.distanceMeters, closeTo(3000, 5));
        expect(withoutLights.signalCount, equals(0));

        // With them: 300 s + 40 s of waiting loses to 315 s of quiet street.
        expect(
          withLights.distanceMeters,
          closeTo(3150, 5),
          reason: 'two junctions should now outweigh 150 m',
        );
        expect(
          withLights.signalCount,
          equals(0),
          reason: 'the route that won passes no lights, and says so',
        );
      },
    );

    test('a route reports the junctions it did pass', () async {
      final geo = GeoGraph(
        nodes: const [
          GeoNode(id: 1, lat: -23.500, lon: -46.700),
          GeoNode(id: 2, lat: -23.500, lon: -46.690),
          GeoNode(id: 3, lat: -23.500, lon: -46.680),
        ],
        edges: const [
          GeoEdge(sourceId: 1, targetId: 2, distanceMeters: 1000, speedKmh: 36),
          GeoEdge(sourceId: 2, targetId: 3, distanceMeters: 1000, speedKmh: 36),
        ],
        signalNodeIds: const {2, 3},
      );

      final route = await routeOf(geo, 1, 3);

      expect(route.signalCount, equals(2));
      expect(route.hasSignals, isTrue);

      // 2 km at 36 km/h is 200 s, plus two junctions. The duration has to
      // include the waiting or it is not the time the rider will experience.
      expect(
        route.duration.inSeconds,
        closeTo(200 + 2 * GraphBuilder.defaultSignalDelaySeconds, 2),
      );
    });
  });

  group('every router agrees', () {
    // Contraction hierarchies are the reason this group exists. CH inserts
    // *shortcut* edges during preprocessing, and a shortcut carries no
    // `adjSignal` of its own — it is unpacked back into original edges before
    // a path is built. That makes the count correct by construction, which is
    // exactly the kind of claim that stops being true quietly.
    late Directory dir;
    late MemoryStorage generic;
    late LocalFileStorage compiled;

    setUp(() async {
      final geo = GeoGraph(
        nodes: const [
          GeoNode(id: 1, lat: -23.500, lon: -46.700),
          GeoNode(id: 2, lat: -23.500, lon: -46.690),
          GeoNode(id: 3, lat: -23.500, lon: -46.680),
          GeoNode(id: 4, lat: -23.500, lon: -46.670),
          GeoNode(id: 5, lat: -23.500, lon: -46.660),
        ],
        edges: const [
          GeoEdge(sourceId: 1, targetId: 2, distanceMeters: 1000, speedKmh: 36),
          GeoEdge(sourceId: 2, targetId: 3, distanceMeters: 1000, speedKmh: 36),
          GeoEdge(sourceId: 3, targetId: 4, distanceMeters: 1000, speedKmh: 36),
          GeoEdge(sourceId: 4, targetId: 5, distanceMeters: 1000, speedKmh: 36),
        ],
        signalNodeIds: const {2, 3, 4},
      );

      generic = MemoryStorage();
      await generic.saveGraph('signals', geo);

      dir = Directory.systemTemp.createTempSync('grf_signals_');
      compiled = LocalFileStorage(directory: dir.path);
      await compiled.saveGraph('signals', geo);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    GraphRouteFinder routerOf(String type, GeoStorage storage) =>
        switch (type) {
          'dijkstra' => DijkstraRouter(storage: storage, graphId: 'signals'),
          'astar' => AStarRouter(storage: storage, graphId: 'signals'),
          'ch' => ContractionHierarchyRouter(
            storage: storage,
            graphId: 'signals',
          ),
          _ => throw ArgumentError(type),
        };

    for (final type in ['dijkstra', 'astar', 'ch']) {
      for (final backend in ['generic', 'compiled']) {
        test('$type via $backend counts and charges the same', () async {
          // The compiled backend matters as much as the algorithm: it is the
          // one that round-trips `adjSignal` through the on-disk format before
          // anything routes over it.
          final storage = backend == 'generic'
              ? generic as GeoStorage
              : compiled;

          final route = await routerOf(type, storage).findRoute(
            const GeoCoordinate(lat: -23.500, lon: -46.700),
            const GeoCoordinate(lat: -23.500, lon: -46.660),
          );

          final ctx = '$type via $backend';

          expect(route.found, isTrue, reason: ctx);

          // Lights at 2, 3 and 4. The one at the origin is not charged,
          // because nothing arrives there.
          expect(route.signalCount, equals(3), reason: ctx);

          // 4 km at 36 km/h is 400 s, plus three junctions.
          expect(
            route.duration.inSeconds,
            closeTo(400 + 3 * GraphBuilder.defaultSignalDelaySeconds, 2),
            reason: ctx,
          );
        });
      }
    }
  });

  group('reading them out of OSM', () {
    /// Converts a synthetic extract carrying [nodeTags] into a graph.
    Future<GeoGraph> convert(
      Map<int, Map<String, String>> nodeTags, {
      bool readSignals = true,
    }) async {
      final dir = await Directory.systemTemp.createTemp('signals_pbf');
      addTearDown(() => dir.deleteSync(recursive: true));

      final file = File('${dir.path}/extract.osm.pbf')
        ..writeAsBytesSync(
          buildWayPbf(
            tags: const {'highway': 'residential'},
            taggedNodes: nodeTags,
          ),
        );

      return OsmConverter(readSignals: readSignals).toGeoGraph(file.path);
    }

    test('a light in the extract becomes a light in the graph', () async {
      // End to end through real bytes: the tag stream has to be decoded, the
      // node matched, and the id kept. Testing `isSignalNode` alone proves the
      // classification and nothing about whether it is ever called.
      final geo = await convert(const {
        2: {'highway': 'traffic_signals'},
      });

      expect(geo.signalNodeIds, equals({2}));
      expect(geo.signalCount, equals(1));
    });

    test('and is charged to whichever direction arrives at it', () async {
      // The fixture's way runs 1 - 2 - 3 with the light at 2, so *two*
      // directed edges end there: 1→2 and 3→2. Both are charged, and that is
      // right — a rider meets that light coming either way. What must not
      // happen is a single pass paying twice, and it does not: one journey
      // traverses one of those edges, never both.
      final geo = await convert(const {
        2: {'highway': 'traffic_signals'},
      });

      final g = const GraphBuilder().build(geo);

      final chargedAt = [
        for (var e = 0; e < g.edgeCount; e++)
          if (g.signalsOf(e) > 0) g.originalId[g.adjTarget[e]],
      ];

      expect(
        chargedAt,
        equals([2, 2]),
        reason: 'both approaches to the junction, and nothing else',
      );
    });

    test('declining to read them costs nothing and finds none', () async {
      final geo = await convert(const {
        2: {'highway': 'traffic_signals'},
      }, readSignals: false);

      expect(geo.signalNodeIds, isEmpty);
      // The road is still there: turning signals off must not change routing
      // in any other way.
      expect(geo.edges, isNotEmpty);
    });

    test('an extract with no tagged nodes at all still converts', () async {
      // The common case, and the one where the `keys_vals` stream is absent
      // from the file entirely rather than present and empty.
      final geo = await convert(const {});

      expect(geo.signalNodeIds, isEmpty);
      expect(geo.edges, isNotEmpty);
    });

    test('a tagged node that is not a control is ignored', () async {
      final geo = await convert(const {
        2: {'highway': 'street_lamp'},
        3: {'amenity': 'bench'},
      });

      expect(geo.signalNodeIds, isEmpty);
    });

    test('a traffic signal node is one', () {
      expect(
        OsmConverter.isSignalNode(const {'highway': 'traffic_signals'}),
        isTrue,
      );
    });

    test('so is a signalised pedestrian crossing', () {
      // Tagged as a crossing rather than as `highway=traffic_signals`, and it
      // stops traffic exactly as much.
      expect(
        OsmConverter.isSignalNode(const {
          'highway': 'crossing',
          'crossing': 'traffic_signals',
        }),
        isTrue,
      );
      expect(
        OsmConverter.isSignalNode(const {
          'highway': 'crossing',
          'crossing:signals': 'yes',
        }),
        isTrue,
      );
    });

    test('an unsignalised crossing is not, and neither is a stop sign', () {
      // A stop sign costs a few seconds against a light's tens, and the graph
      // carries a count rather than a per-class delay — so folding it in at
      // the same weight would say a street of stop signs costs as much as a
      // street of lights. `DeliverySchema` still draws them; the cost model
      // leaves them alone.
      for (final tags in [
        {'highway': 'crossing'},
        {'highway': 'crossing', 'crossing': 'zebra'},
        {'highway': 'stop'},
        {'highway': 'give_way'},
        {'railway': 'level_crossing'},
        {'highway': 'street_lamp'},
        <String, String>{},
      ]) {
        expect(
          OsmConverter.isSignalNode(tags),
          isFalse,
          reason: '$tags is not a signalised junction for routing',
        );
      }
    });
  });
}
