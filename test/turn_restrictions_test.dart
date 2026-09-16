import 'dart:io';
import 'dart:typed_data';

import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Turn restrictions, from the extract to the graph.
///
/// A route that turns left where the sign forbids it is not a longer route,
/// it is a wrong one — and the rider finds out while sitting at the junction.
/// These cover the reading of `type=restriction` relations: what is accepted,
/// and, just as importantly, what is refused rather than guessed at.

/// A T-junction: way 10 runs 1→2→3 west to east, way 11 runs 3→4 north.
///
///     1 ——— 2 ——— 3        (way 10)
///                 |
///                 4        (way 11)
Uint8List _junction({
  Map<String, String>? restriction,
  List<PbfMember>? members,
  List<PbfWay>? ways,
}) => buildOsmPbf(
  nodeIds: const [1, 2, 3, 4],
  lats: const [-23.50, -23.50, -23.50, -23.51],
  lons: const [-46.70, -46.69, -46.68, -46.68],
  ways:
      ways ??
      const [
        (id: 10, nodeIds: [1, 2, 3], tags: {'highway': 'residential'}),
        (id: 11, nodeIds: [3, 4], tags: {'highway': 'residential'}),
      ],
  relations: restriction == null
      ? const []
      : [
          (
            id: 100,
            members:
                members ??
                const [
                  (type: 1, ref: 10, role: 'from'),
                  (type: 0, ref: 3, role: 'via'),
                  (type: 1, ref: 11, role: 'to'),
                ],
            tags: restriction,
          ),
        ],
);

Future<GeoGraph> _read(
  Uint8List pbf, {
  VehicleProfile profile = VehicleProfile.car,
  bool readTurnRestrictions = true,
}) async {
  final path = writeTempPbf(pbf);
  try {
    return await OsmConverter(
      profile: profile,
      readTurnRestrictions: readTurnRestrictions,
    ).toGeoGraph(path);
  } finally {
    File(path).parent.deleteSync(recursive: true);
  }
}

void main() {
  group('reading a restriction out of an extract', () {
    test('resolves the ways to the nodes either side of the via', () async {
      // The relation names *ways*; routing needs the one segment on each side
      // of the junction. Way 10 ends at node 3, so its last-but-one node is
      // the approach; way 11 starts there, so its second node is the exit.
      final graph = await _read(
        _junction(
          restriction: const {
            'type': 'restriction',
            'restriction': 'no_left_turn',
          },
        ),
      );

      expect(graph.turnRestrictions, hasLength(1));

      final r = graph.turnRestrictions.single;
      expect(r.fromNodeId, equals(2));
      expect(r.viaNodeId, equals(3));
      expect(r.toNodeId, equals(4));
      expect(r.isOnly, isFalse);
      expect(r.isConditional, isFalse);
    });

    test('tells `only_*` from `no_*`, because they are opposites', () async {
      // `no_left_turn` removes one movement; `only_straight_on` removes every
      // movement except one. Reading this backwards produces a graph that
      // forbids precisely what it should allow.
      final graph = await _read(
        _junction(
          restriction: const {
            'type': 'restriction',
            'restriction': 'only_straight_on',
          },
        ),
      );

      expect(graph.turnRestrictions.single.isOnly, isTrue);
    });

    test('keeps a conditional expression as written', () async {
      // It cannot be resolved at build time: the same graph has to answer both
      // "restricted now" and "not restricted now".
      final graph = await _read(
        _junction(
          restriction: const {
            'type': 'restriction',
            'restriction:conditional': 'no_left_turn @ (Mo-Fr 07:00-09:00)',
          },
        ),
      );

      final r = graph.turnRestrictions.single;
      expect(r.isConditional, isTrue);
      expect(r.condition, equals('no_left_turn @ (Mo-Fr 07:00-09:00)'));
      expect(r.isOnly, isFalse);

      final stats = OsmConverter().lastRestrictionStats;
      expect(stats, isNull, reason: 'a fresh converter has read nothing');
    });

    test('reports the distinct conditional expressions it kept', () async {
      final converter = OsmConverter();
      final path = writeTempPbf(
        _junction(
          restriction: const {
            'type': 'restriction',
            'restriction:conditional': 'no_left_turn @ (Sa,Su)',
          },
        ),
      );

      try {
        await converter.toGeoGraph(path);
      } finally {
        File(path).parent.deleteSync(recursive: true);
      }

      expect(converter.lastRestrictionStats!.conditions, equals(1));
      expect(converter.lastRestrictionStats!.accepted, equals(1));
    });

    test('reads `type=restriction:<mode>` the same way', () async {
      // The same shape with a mode attached, which `startsWith` catches.
      final graph = await _read(
        _junction(
          restriction: const {
            'type': 'restriction:motorcar',
            'restriction': 'no_right_turn',
          },
        ),
      );

      expect(graph.turnRestrictions, hasLength(1));
    });

    test('reads nothing when asked not to', () async {
      final graph = await _read(
        _junction(
          restriction: const {
            'type': 'restriction',
            'restriction': 'no_left_turn',
          },
        ),
        readTurnRestrictions: false,
      );

      expect(graph.turnRestrictions, isEmpty);
      // And the roads are still there — declining restrictions must not
      // decline the graph.
      expect(graph.edges, isNotEmpty);
    });

    test('a graph with no relations reports none, not nothing', () async {
      final converter = OsmConverter();
      final path = writeTempPbf(_junction());

      try {
        await converter.toGeoGraph(path);
      } finally {
        File(path).parent.deleteSync(recursive: true);
      }

      expect(converter.lastRestrictionStats!.accepted, isZero);
      expect(converter.lastRestrictionStats!.skipped, isZero);
    });
  });

  group('what it refuses rather than guesses', () {
    Future<TurnRestrictionStats> statsOf(
      Uint8List pbf, {
      VehicleProfile profile = VehicleProfile.car,
    }) async {
      final converter = OsmConverter(profile: profile);
      final path = writeTempPbf(pbf);
      try {
        await converter.toGeoGraph(path);
      } finally {
        File(path).parent.deleteSync(recursive: true);
      }
      return converter.lastRestrictionStats!;
    }

    test('a via-way is counted, not silently dropped', () async {
      // The other shape of restriction, used where a divided road forces
      // traffic through a connector. Out of scope — but a number nobody can
      // see is a decision nobody can revisit.
      final stats = await statsOf(
        _junction(
          restriction: const {
            'type': 'restriction',
            'restriction': 'no_left_turn',
          },
          members: const [
            (type: 1, ref: 10, role: 'from'),
            (type: 1, ref: 11, role: 'via'),
            (type: 1, ref: 10, role: 'to'),
          ],
        ),
      );

      expect(stats.skippedViaWay, equals(1));
      expect(stats.accepted, isZero);
    });

    test('a way that runs through the via node is ambiguous', () async {
      // Way 10 does not end at node 2, it passes through it, so "the segment
      // the restriction means" has two candidates and the relation does not
      // say which. Banning both would forbid a legal movement; allowing both
      // would permit an illegal one.
      final stats = await statsOf(
        _junction(
          restriction: const {
            'type': 'restriction',
            'restriction': 'no_left_turn',
          },
          members: const [
            (type: 1, ref: 10, role: 'from'),
            (type: 0, ref: 2, role: 'via'),
            (type: 1, ref: 10, role: 'to'),
          ],
        ),
      );

      expect(stats.ambiguousMember, equals(1));
      expect(stats.accepted, isZero);
    });

    test('a member way this profile cannot use is unresolved', () async {
      // Way 11 is a motorway, which a bicycle may not ride, so the graph does
      // not contain it and the restriction has nothing to point at.
      final stats = await statsOf(
        _junction(
          restriction: const {
            'type': 'restriction',
            'restriction': 'no_left_turn',
          },
          ways: const [
            (id: 10, nodeIds: [1, 2, 3], tags: {'highway': 'residential'}),
            (id: 11, nodeIds: [3, 4], tags: {'highway': 'motorway'}),
          ],
        ),
        profile: VehicleProfile.bicycle,
      );

      expect(stats.unresolvedMember, equals(1));
      expect(stats.accepted, isZero);
    });

    test('`except=` exempts the profile it names', () async {
      // "No left turn except bicycles" applied to bicycles is exactly the
      // over-restriction this is for, and it lands on the mode with the
      // fewest alternatives.
      final pbf = _junction(
        restriction: const {
          'type': 'restriction',
          'restriction': 'no_left_turn',
          'except': 'psv;bicycle',
        },
      );

      expect((await statsOf(pbf, profile: VehicleProfile.bicycle)).excepted, 1);

      // The same sign still binds a car.
      expect((await statsOf(pbf)).accepted, equals(1));
    });

    test('a relation with no restriction value is not a restriction', () async {
      final stats = await statsOf(
        _junction(restriction: const {'type': 'restriction'}),
      );

      expect(stats.accepted, isZero);
      expect(stats.unresolvedMember, equals(1));
    });
  });

  group('splitting the junction', () {
    /// A crossroads, so a banned exit still leaves somewhere to go.
    ///
    ///            5
    ///            |
    ///     1 — 2 — 3 — 6      (way 10 runs 1-2-3, way 12 runs 3-6)
    ///            |
    ///            4
    GeoGraph crossroads({
      String? restriction,
      int toNode = 4,
      String? condition,
    }) {
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
        turnRestrictions: restriction == null
            ? const []
            : [
                GeoTurnRestriction(
                  fromNodeId: 2,
                  viaNodeId: 3,
                  toNodeId: toNode,
                  isOnly: restriction == 'only',
                  condition: condition,
                ),
              ],
      );
    }

    /// The vertex a given OSM id compiled to, and its exits by OSM id.
    Set<int> exitsFrom(RoutingGraph g, int vertex) => {
      for (var e = g.adjOffset[vertex]; e < g.adjOffset[vertex + 1]; e++)
        g.originalId[g.adjTarget[e]],
    };

    /// Where the edge `fromId -> viaId` actually lands after splitting.
    int arrivalOf(RoutingGraph g, int fromId, int viaId) {
      final from = [
        for (var v = 0; v < g.nodeCount; v++)
          if (g.originalId[v] == fromId && !g.isSplitCopy(v)) v,
      ].single;

      return [
        for (var e = g.adjOffset[from]; e < g.adjOffset[from + 1]; e++)
          if (g.originalId[g.adjTarget[e]] == viaId) g.adjTarget[e],
      ].single;
    }

    RoutingGraph split(GeoGraph geo) => const TurnRestrictionSplitter().split(
      const GraphBuilder().build(geo),
      geo.turnRestrictions,
    );

    test('a `no_*` turn simply has no edge', () async {
      final g = split(crossroads(restriction: 'no'));

      // Arriving from 2, node 4 is gone and everything else remains.
      final arrival = arrivalOf(g, 2, 3);
      expect(g.isSplitCopy(arrival), isTrue);
      expect(exitsFrom(g, arrival), equals({5, 6, 2}));

      expect(
        exitsFrom(g, arrival),
        isNot(contains(4)),
        reason: 'the forbidden movement must be absent, not expensive',
      );
    });

    test('an `only_*` turn leaves exactly one exit', () async {
      final g = split(crossroads(restriction: 'only'));
      final arrival = arrivalOf(g, 2, 3);

      expect(exitsFrom(g, arrival), equals({4}));
    });

    test('only the named approach is affected', () async {
      final g = split(crossroads(restriction: 'no'));

      // The junction itself keeps every exit, which is what a route arriving
      // from any other arm — or starting here — should still see.
      final junction = [
        for (var v = 0; v < g.nodeCount; v++)
          if (g.originalId[v] == 3 && !g.isSplitCopy(v)) v,
      ].single;

      expect(exitsFrom(g, junction), equals({2, 4, 5, 6}));
    });

    test('a U-turn is banned only where the sign says so', () async {
      // `no_u_turn` needs no special handling: the `to` is the reverse of the
      // `from`, and the ordinary rule removes it. What matters is that this
      // changes nothing anywhere else.
      final g = split(crossroads(restriction: 'no', toNode: 2));
      final arrival = arrivalOf(g, 2, 3);

      expect(exitsFrom(g, arrival), equals({4, 5, 6}));

      final junction = [
        for (var v = 0; v < g.nodeCount; v++)
          if (g.originalId[v] == 3 && !g.isSplitCopy(v)) v,
      ].single;

      expect(
        exitsFrom(g, junction),
        contains(2),
        reason: 'U-turns elsewhere are untouched',
      );
    });

    test('the copy is never reachable from its parent', () async {
      // A zero-cost edge from copy back to junction would re-admit every
      // forbidden turn by going the long way round inside the junction.
      final g = split(crossroads(restriction: 'no'));

      for (var v = 0; v < g.nodeCount; v++) {
        for (var e = g.adjOffset[v]; e < g.adjOffset[v + 1]; e++) {
          final target = g.adjTarget[e];
          if (!g.isSplitCopy(target)) continue;

          expect(
            g.splitParent![target],
            isNot(equals(v)),
            reason: 'a copy must be reached only by its own approach',
          );
        }
      }
    });

    test('a conditional ban keeps the edge and flags it', () async {
      // It cannot be topology: one graph has to answer both "restricted now"
      // and "not restricted now".
      final g = split(
        crossroads(restriction: 'no', condition: 'no_left_turn @ (Sa,Su)'),
      );

      final arrival = arrivalOf(g, 2, 3);
      expect(exitsFrom(g, arrival), equals({2, 4, 5, 6}));

      final toFour = [
        for (var e = g.adjOffset[arrival]; e < g.adjOffset[arrival + 1]; e++)
          if (g.originalId[g.adjTarget[e]] == 4) e,
      ].single;

      expect(g.conditionOf(toFour), equals('no_left_turn @ (Sa,Su)'));

      // And nothing else is flagged.
      for (var e = g.adjOffset[arrival]; e < g.adjOffset[arrival + 1]; e++) {
        if (e == toFour) continue;
        expect(g.conditionOf(e), isNull);
      }
    });

    test('a graph with no restrictions is returned untouched', () async {
      final geo = crossroads();
      final built = const GraphBuilder().build(geo);
      final g = const TurnRestrictionSplitter().split(built, const []);

      expect(identical(g, built), isTrue);
      expect(g.splitParent, isNull);
      expect(g.adjCond, isNull);
    });

    test('copies stay out of the spatial index', () async {
      // They sit at the junction's exact coordinate. Snapping to one would
      // start a route already committed to an approach it never made.
      final g = split(crossroads(restriction: 'no'));
      final tree = KdTree.build(g);

      expect(tree.order.length, lessThan(g.nodeCount));

      final at = g.coordinateOf(arrivalOf(g, 2, 3));
      final snapped = tree.findNearest(at.lat, at.lon);

      expect(g.isSplitCopy(snapped.node), isFalse);
      expect(g.originalId[snapped.node], equals(3));
    });
  });
}
