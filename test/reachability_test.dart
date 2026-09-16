import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Invariants that hold of the whole graph, rather than scenarios.
///
/// Every other test here asks "does this shape route the way I expect". That
/// is how a suite stays green while 76 junctions in Florianópolis cannot be
/// delivered to: each of those junctions routed *through* perfectly, and no
/// test ever asked whether anything could stop at one.
///
/// These ask structural questions instead — can every place still be arrived
/// at, does each stage preserve what the last one could reach — and they are
/// the tests that would have caught it.

void main() {
  /// Vertices nothing points at.
  Set<int> unreachable(RoutingGraph g) {
    final hasIncoming = List<bool>.filled(g.nodeCount, false);
    for (var u = 0; u < g.nodeCount; u++) {
      for (var e = g.adjOffset[u]; e < g.adjOffset[u + 1]; e++) {
        hasIncoming[g.adjTarget[e]] = true;
      }
    }

    return {
      for (var v = 0; v < g.nodeCount; v++)
        // An isolated vertex has nothing to say about reachability; a vertex
        // you can leave and never arrive at is the failure.
        if (!hasIncoming[v] && g.adjOffset[v + 1] > g.adjOffset[v]) v,
    };
  }

  /// The places a route could legitimately be sent to, keyed the way a caller
  /// keys them: by the coordinate a rider would snap to.
  ///
  /// A split junction is several vertices at one point, and arriving at any of
  /// them is arriving at the junction — which is exactly what `RouteFinder`'s
  /// alias loop relies on.
  Set<String> arrivablePlaces(RoutingGraph g) {
    final places = <String>{};
    for (var u = 0; u < g.nodeCount; u++) {
      for (var e = g.adjOffset[u]; e < g.adjOffset[u + 1]; e++) {
        final v = g.adjTarget[e];
        places.add('${g.lat[v]},${g.lon[v]}');
      }
    }
    return places;
  }

  /// The junction every case below is built around.
  const junctionId = 3;

  /// A junction in a one-way grid, with its approaches restricted.
  ///
  ///     … →— a →—┐        ┌—→ exit
  ///               3 (junction)
  ///     … →— a →—┘        └—→ exit
  ///
  /// This is Avenida Madre Benvenuta, reduced, and every knob on it is one the
  /// real case turned.
  ///
  /// It matters that the streets are **one-way**. With two-way streets the
  /// junction stays reachable from whichever arm was not restricted, and the
  /// bug hides completely — which is exactly why the suite was green while 76
  /// junctions in the city could not be delivered to.
  ///
  /// [exits] and [only] together decide the shape that breaks: what the copy
  /// is left holding. One way in and one way out is what a chain merge
  /// swallows, and contracting the copy splices the approach straight to its
  /// permitted exit. Routing *through* stays perfect; there is simply nowhere
  /// at the junction's coordinate left to arrive at.
  GeoGraph oneWayJunction({
    int exits = 2,
    int approaches = 1,
    int approachLength = 1,
    bool only = true,
    String? condition,
  }) {
    const jLat = -23.500;
    const jLon = -46.680;

    GeoEdge oneWay(int a, int b) => GeoEdge(
      sourceId: a,
      targetId: b,
      distanceMeters: 500,
      speedKmh: 36,
      oneWay: true,
    );

    final nodes = <GeoNode>[
      const GeoNode(id: junctionId, lat: jLat, lon: jLon),
    ];
    final edges = <GeoEdge>[];
    final restrictions = <GeoTurnRestriction>[];

    final exitIds = <int>[];
    for (var i = 0; i < exits; i++) {
      final id = 40 + i;
      exitIds.add(id);
      nodes.add(GeoNode(id: id, lat: jLat - 0.01 * (i + 1), lon: jLon));
      edges.add(oneWay(junctionId, id));
    }

    for (var a = 0; a < approaches; a++) {
      // Far to near, so the last one is the arm that meets the junction.
      final chain = [
        for (var k = approachLength; k >= 1; k--) 100 + a * 10 + k,
      ];

      for (var k = 0; k < chain.length; k++) {
        nodes.add(
          GeoNode(
            id: chain[k],
            lat: jLat + 0.004 * a,
            lon: jLon - 0.01 * (chain.length - k),
          ),
        );
        if (k > 0) edges.add(oneWay(chain[k - 1], chain[k]));
      }
      edges.add(oneWay(chain.last, junctionId));

      restrictions.add(
        GeoTurnRestriction(
          fromNodeId: chain.last,
          viaNodeId: junctionId,
          toNodeId: exitIds[a % exitIds.length],
          isOnly: only,
          condition: condition,
        ),
      );
    }

    return GeoGraph(nodes: nodes, edges: edges, turnRestrictions: restrictions);
  }

  /// The same crossroads the rest of the suite uses: two-way, one restriction.
  ///
  /// Kept beside [oneWayJunction] so the contrast is on the page. Nothing here
  /// fails without the fix, because the junction is still reachable from the
  /// arms that were not restricted.
  GeoGraph crossroads({required bool only, int toNode = 4}) {
    const nodes = [
      GeoNode(id: 1, lat: -23.500, lon: -46.700),
      GeoNode(id: 2, lat: -23.500, lon: -46.690),
      GeoNode(id: 3, lat: -23.500, lon: -46.680),
      GeoNode(id: 4, lat: -23.510, lon: -46.680),
      GeoNode(id: 5, lat: -23.490, lon: -46.680),
      GeoNode(id: 6, lat: -23.500, lon: -46.670),
    ];

    const edges = [
      GeoEdge(sourceId: 1, targetId: 2, distanceMeters: 500, speedKmh: 36),
      GeoEdge(sourceId: 2, targetId: 3, distanceMeters: 500, speedKmh: 36),
      GeoEdge(sourceId: 3, targetId: 4, distanceMeters: 500, speedKmh: 36),
      GeoEdge(sourceId: 3, targetId: 5, distanceMeters: 500, speedKmh: 36),
      GeoEdge(sourceId: 3, targetId: 6, distanceMeters: 500, speedKmh: 36),
    ];

    return GeoGraph(
      nodes: nodes,
      edges: edges,
      turnRestrictions: [
        GeoTurnRestriction(
          fromNodeId: 2,
          viaNodeId: 3,
          toNodeId: toNode,
          isOnly: only,
        ),
      ],
    );
  }

  RoutingGraph pipeline(GeoGraph geo, {required bool compress}) {
    final split = const TurnRestrictionSplitter().split(
      const GraphBuilder().build(geo),
      geo.turnRestrictions,
    );
    return compress ? GraphCompressor().compress(split) : split;
  }

  /// Where the restrictions split a junction, as coordinates.
  Set<String> splitPlaces(RoutingGraph g) => {
    for (var v = 0; v < g.nodeCount; v++)
      if (g.isSplitCopy(v)) '${g.lat[v]},${g.lon[v]}',
  };

  group('compression must not take a junction away', () {
    // Deliberately narrow. Compression *is* the removal of degree-2 vertices,
    // so "every place arrivable before is arrivable after" is false by design
    // and asserting it only produces a test that has to be explained away.
    //
    // What must survive is a *junction*: somewhere roads meet, which a rider
    // can be sent to. That is the property the bug broke.
    //
    // The cases below are the shapes the copy can be left in. The ones marked
    // "was broken" all reduce to a copy with one way in and one way out —
    // which is what a chain merge swallows — reached by different routes: the
    // number of exits, the tag that closed them, how many arms are restricted,
    // and how long the approach is. The controls leave the copy with more than
    // one exit, so it was never contracted and passed before the fix as well;
    // they are here so a regression that breaks *them* is also caught.
    final cases = <(String, GeoGraph)>[
      // was broken —
      ('only_*, two exits', oneWayJunction()),
      ('only_*, three exits', oneWayJunction(exits: 3)),
      (
        'no_*, two exits (closing one leaves one)',
        oneWayJunction(exits: 2, only: false),
      ),
      ('two restricted approaches', oneWayJunction(approaches: 2)),
      (
        'a long approach, merged before the junction',
        oneWayJunction(approachLength: 4),
      ),
      (
        'three approaches onto three exits',
        oneWayJunction(exits: 3, approaches: 3),
      ),
      // controls —
      (
        'no_*, three exits (closing one leaves two)',
        oneWayJunction(exits: 3, only: false),
      ),
      (
        'a conditional restriction, which removes no edge at all',
        oneWayJunction(condition: 'no_left_turn @ (Mo-Fr 07:00-09:00)'),
      ),
      ('two-way crossroads', crossroads(only: true)),
    ];

    for (final c in cases) {
      test('${c.$1}: the junction can still be arrived at', () {
        final before = pipeline(c.$2, compress: false);
        final after = pipeline(c.$2, compress: true);

        final places = splitPlaces(before);
        expect(places, isNotEmpty, reason: 'the fixture must actually split');

        expect(
          places.difference(arrivablePlaces(after)),
          isEmpty,
          reason: 'compression stranded a junction: nothing can arrive there',
        );
      });
    }
  });

  group('nowhere is one-way into oblivion', () {
    test('an ordinary grid leaves nothing stranded', () {
      final g = GraphCompressor().compress(
        const GraphBuilder().build(buildGrid(n: 6)),
      );

      expect(unreachable(g), isEmpty);
    });

    for (final only in [false, true]) {
      test('nor does a restricted crossroads (only: $only)', () {
        final g = pipeline(crossroads(only: only), compress: true);

        // A split parent legitimately has no in-degree of its own — every
        // approach is retargeted onto a copy. What must not happen is the
        // *place* becoming unarrivable, which the group above covers. Here:
        // no vertex should be stranded once copies are counted as the
        // junction they stand for.
        final stranded = <int>[];
        for (final v in unreachable(g)) {
          final place = '${g.lat[v]},${g.lon[v]}';
          if (!arrivablePlaces(g).contains(place)) stranded.add(v);
        }

        expect(
          stranded,
          isEmpty,
          reason:
              'vertices you can leave and never reach: '
              '${stranded.map((v) => g.originalId[v]).toList()}',
        );
      });
    }
  });

  group('every junction answers as a destination', () {
    /// Which of [geo]'s nodes cannot be routed to from node 1.
    Future<List<int>> unroutableNodes(GeoGraph geo) async {
      final storage = MemoryStorage();
      await storage.saveGraph('r', geo);

      final router = DijkstraRouter(storage: storage, graphId: 'r');
      const origin = GeoCoordinate(lat: -23.500, lon: -46.700); // node 1

      final out = <int>[];
      for (final node in geo.nodes) {
        if (node.id == 1) continue;

        final route = await router.findRoute(
          origin,
          GeoCoordinate(lat: node.lat, lon: node.lon),
        );
        if (!route.found) out.add(node.id);
      }
      return out;
    }

    for (final only in [false, true]) {
      test('on a two-way crossroads (only: $only)', () async {
        expect(await unroutableNodes(crossroads(only: only)), isEmpty);
      });
    }

    test('on the one-way junction', () async {
      // Only node 3 is asserted, and only that. Several of the others are
      // legitimately unroutable *from node 1* and it would be dishonest to
      // pretend otherwise: node 6 is a source in a one-way grid with nothing
      // leading to it, node 5 is reachable only by the approach the
      // restriction closes, and node 2 is a degree-2 vertex compression is
      // entitled to remove.
      //
      // The junction is none of those. It is the whole point.
      final unroutable = await unroutableNodes(oneWayJunction());

      expect(
        unroutable,
        isNot(contains(3)),
        reason: 'the junction cannot be delivered to',
      );
    });
  });

  group('what a route reports is a number', () {
    test('a found route carries finite totals', () async {
      // `double.infinity` is what an unroutable pair produces, and it is not
      // JSON: a consumer that puts one on the wire answers an ordinary "no
      // route" with a 500. Worth pinning at the source rather than at every
      // boundary that has to carry it.
      final storage = MemoryStorage();
      await storage.saveGraph('r', crossroads(only: false));

      final route = await DijkstraRouter(storage: storage, graphId: 'r')
          .findRoute(
            const GeoCoordinate(lat: -23.500, lon: -46.700),
            const GeoCoordinate(lat: -23.490, lon: -46.680),
          );

      expect(route.found, isTrue);
      expect(route.distanceMeters.isFinite, isTrue);
      expect(route.duration.inSeconds, greaterThan(0));
      for (final c in route.geometry) {
        expect(c.lat.isFinite && c.lon.isFinite, isTrue);
      }
    });
  });
}
