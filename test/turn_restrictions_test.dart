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

    test('both tags on one relation are two signs, not one', () async {
      // A junction can carry a permanent sign and a timed plate that forbid
      // *different* movements. Reading the ban from `restriction` and the
      // timetable from `restriction:conditional` makes one record whose ban is
      // permanent and whose window is not — so outside the window the
      // always-on restriction stops applying and the router offers exactly the
      // turn the fixed sign forbids.
      final graph = await _read(
        _junction(
          restriction: const {
            'type': 'restriction',
            'restriction': 'no_left_turn',
            'restriction:conditional': 'only_straight_on @ (Sa,Su)',
          },
        ),
      );

      expect(graph.turnRestrictions, hasLength(2));

      final permanent = graph.turnRestrictions
          .where((r) => !r.isConditional)
          .single;
      expect(permanent.isOnly, isFalse);
      expect(permanent.condition, isNull);

      final timed = graph.turnRestrictions.where((r) => r.isConditional).single;
      expect(timed.condition, equals('only_straight_on @ (Sa,Su)'));
      expect(
        timed.isOnly,
        isTrue,
        reason: 'the timed sign states its own movement; it inherits nothing',
      );
    });

    test('an unreadable tag does not take the readable one down', () async {
      // Judged one value at a time: a junction whose permanent tag is a typo
      // still has a timed sign standing at it.
      final graph = await _read(
        _junction(
          restriction: const {
            'type': 'restriction',
            'restriction': 'left_turn_prohibited',
            'restriction:conditional': 'no_left_turn @ (Sa,Su)',
          },
        ),
      );

      expect(graph.turnRestrictions, hasLength(1));
      expect(graph.turnRestrictions.single.isConditional, isTrue);
    });

    /// Reads one relation and reports what the converter made of it.
    Future<(GeoGraph, TurnRestrictionStats)> readOne(
      Map<String, String> tags,
    ) async {
      final converter = OsmConverter();
      final path = writeTempPbf(_junction(restriction: tags));

      try {
        final graph = await converter.toGeoGraph(path);
        return (graph, converter.lastRestrictionStats!);
      } finally {
        File(path).parent.deleteSync(recursive: true);
      }
    }

    group('the vocabulary of `no` and `only`', () {
      /// What the converter made of a single `restriction` value: whether it
      /// is an `only_*`, or null when the value named no movement.
      Future<bool?> kindOf(String value) async {
        final (graph, stats) = await readOne({
          'type': 'restriction',
          'restriction': value,
        });

        if (graph.turnRestrictions.isEmpty) {
          // Dropped is not enough — it has to be *counted*, or a mis-tagged
          // relation leaves no trace in the build report at all.
          expect(
            stats.unresolvedMember,
            equals(1),
            reason: '"$value" was dropped without being counted',
          );
          return null;
        }

        expect(stats.accepted, equals(1));
        return graph.turnRestrictions.single.isOnly;
      }

      // The whole standard vocabulary, because the prefix and the movement are
      // read separately and a set that is missing one value drops every sign
      // in the city that uses it — silently, since the restriction simply
      // never arrives.
      const readable = {
        'no_left_turn': false,
        'no_right_turn': false,
        'no_straight_on': false,
        'no_u_turn': false,
        'no_entry': false,
        'no_exit': false,
        'only_left_turn': true,
        'only_right_turn': true,
        'only_straight_on': true,
        'only_u_turn': true,
      };

      for (final entry in readable.entries) {
        test('`${entry.key}` is read as a restriction', () async {
          expect(
            await kindOf(entry.key),
            equals(entry.value),
            reason: entry.value
                ? 'an `only_*` keeps one exit and removes the rest'
                : 'a `no_*` removes one exit and keeps the rest',
          );
        });
      }

      // Values that begin like a restriction and are not one. Reading any of
      // these as a ban removes a movement the sign never mentioned — and the
      // relation's members then supply a concrete turn the value never
      // described, so the rider goes the long way round a junction they could
      // have turned at.
      const notRestrictions = [
        'no parking',
        'no_parking',
        'no stopping',
        'no_standing',
        'nonsense',
        'notice',
        'north',
        'only_buses',
        'no',
        'only',
        'no_',
        'only_',
        'left_turn_prohibited',
        'yes',
        '',
      ];

      for (final value in notRestrictions) {
        test('`$value` is not a restriction', () async {
          expect(await kindOf(value), isNull);
        });
      }

      test('separators and case are forgiven', () async {
        // The strictness is about the *movement*, not the spelling. This is
        // hand-edited data, and rejecting `No Left Turn` would drop a real ban
        // over a space.
        for (final spelling in [
          'No Left Turn',
          'NO_LEFT_TURN',
          'no-left-turn',
          '  no_left_turn  ',
          'no   left   turn',
        ]) {
          expect(
            await kindOf(spelling),
            isFalse,
            reason: '"$spelling" is the same sign as no_left_turn',
          );
        }
      });

      test('a value listing several bans is still one ban', () async {
        // One relation forbidding two movements. Which turn it means comes
        // from the members either way; the value only has to say `no` rather
        // than `only`.
        expect(await kindOf('no_left_turn;no_u_turn'), isFalse);
        expect(await kindOf('only_straight_on;only_right_turn'), isTrue);
      });

      test('an unreadable part does not spoil a readable one', () async {
        expect(await kindOf('no_parking;no_left_turn'), isFalse);
      });

      test('a value that both bans and mandates is refused', () async {
        // One record cannot be an `only_*` and a `no_*` at once, and choosing
        // either half states something the source did not: `only_straight_on`
        // removes every exit but one, `no_left_turn` removes exactly one.
        expect(await kindOf('no_left_turn;only_straight_on'), isNull);
        expect(await kindOf('only_straight_on;no_left_turn'), isNull);
      });

      test('a timetable is not read as part of the movement', () async {
        // The `@` is split off *before* the `;` list, and the order matters:
        // `opening_hours` uses `;` to separate its own rules, so splitting the
        // other way round would hand `Sa 08:00-12:00)` to the vocabulary check
        // and turn a readable restriction into an unreadable one.
        final (graph, _) = await readOne(const {
          'type': 'restriction',
          'restriction:conditional':
              'no_left_turn @ (Mo-Fr 07:00-09:00; Sa 08:00-12:00)',
        });

        expect(graph.turnRestrictions, hasLength(1));

        final r = graph.turnRestrictions.single;
        expect(r.isOnly, isFalse);
        expect(
          r.condition,
          equals('no_left_turn @ (Mo-Fr 07:00-09:00; Sa 08:00-12:00)'),
          reason: 'the expression is stored whole, timetable included',
        );
      });

      test('both tags unreadable drops the relation once', () async {
        final (graph, stats) = await readOne(const {
          'type': 'restriction',
          'restriction': 'left_turn_prohibited',
          'restriction:conditional': 'weekend_ban @ (Sa,Su)',
        });

        expect(graph.turnRestrictions, isEmpty);
        expect(stats.accepted, isZero);
        expect(
          stats.unresolvedMember,
          equals(1),
          reason: 'one relation, one count — not one per unreadable tag',
        );
      });
    });

    test('convert carries restrictions into a plain storage too', () async {
      // `convert` has two branches. The compiled one is covered by the
      // end-to-end test; this is the other, where the converter hands a
      // `GeoGraph` to a storage that is not a `CompiledGraphStorage`. The
      // restrictions have to travel with it — a `GeoGraph` that arrives
      // without them produces a router that is confidently wrong.
      final storage = MemoryStorage();
      final path = writeTempPbf(
        _junction(
          restriction: const {
            'type': 'restriction',
            'restriction': 'no_left_turn',
          },
        ),
      );

      try {
        await OsmConverter().convert(
          inputFile: path,
          storage: storage,
          graphId: 'plain',
        );
      } finally {
        File(path).parent.deleteSync(recursive: true);
      }

      final stored = await storage.loadGraph('plain');
      expect(stored!.turnRestrictions, hasLength(1));
      expect(stored.turnRestrictions.single.viaNodeId, equals(3));
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

  group('saying what was and was not honoured', () {
    // The cost of a restriction is invisible by construction — a forbidden
    // turn is an edge that is not there — so everything that makes a build
    // *explicable* is a reporting surface. A build that states only what it
    // accepted cannot be judged.

    test('a restriction describes itself', () {
      const r = GeoTurnRestriction(
        fromNodeId: 2,
        viaNodeId: 3,
        toNodeId: 4,
        isOnly: true,
      );

      expect(r.toString(), contains('only'));
      expect(r.toString(), contains('2 -> 3 -> 4'));
      expect(r.isUTurn, isFalse);
    });

    test('a U-turn is one whose exit is its approach', () {
      const r = GeoTurnRestriction(
        fromNodeId: 2,
        viaNodeId: 3,
        toNodeId: 2,
        isOnly: false,
      );

      expect(r.isUTurn, isTrue);
      expect(r.toString(), startsWith('GeoTurnRestriction(no '));
    });

    test('a condition is named in the description', () {
      const r = GeoTurnRestriction(
        fromNodeId: 2,
        viaNodeId: 3,
        toNodeId: 4,
        isOnly: false,
        condition: 'no_left_turn @ (Sa,Su)',
      );

      expect(r.toString(), contains('@ no_left_turn @ (Sa,Su)'));
    });

    test('skipped is every reason a restriction was not honoured', () {
      // If this drifts out of step with the fields, a build reports fewer
      // losses than it had — which is the one direction that matters.
      const stats = TurnRestrictionStats(
        accepted: 10,
        skippedViaWay: 1,
        unresolvedMember: 2,
        ambiguousMember: 3,
        contradictory: 4,
        excepted: 5,
        conditions: 6,
      );

      expect(stats.skipped, equals(15));
      expect(stats.toString(), contains('10 accepted'));
      expect(stats.toString(), contains('15 skipped'));
      expect(stats.toString(), contains('6 conditional'));
    });

    test('a clean build reports zero rather than nothing', () {
      const stats = TurnRestrictionStats();
      expect(stats.skipped, isZero);
      expect(stats.toString(), contains('0 accepted'));
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

    test('round-trips through the v4 format', () async {
      final g = split(
        crossroads(restriction: 'no', condition: 'no_left_turn @ (Sa,Su)'),
      );

      final bytes = const GraphSerializer().serializeGraph(g);
      final back = const GraphDeserializer().deserializeGraph(bytes);

      expect(back.nodeCount, equals(g.nodeCount));
      expect(back.splitParent, equals(g.splitParent));
      expect(back.adjCond, equals(g.adjCond));
      expect(back.conditions, equals(g.conditions));

      // And the meaning survives, not just the bytes.
      final arrival = arrivalOf(back, 2, 3);
      expect(back.isSplitCopy(arrival), isTrue);

      final toFour = [
        for (
          var e = back.adjOffset[arrival];
          e < back.adjOffset[arrival + 1];
          e++
        )
          if (back.originalId[back.adjTarget[e]] == 4) e,
      ].single;

      expect(back.conditionOf(toFour), equals('no_left_turn @ (Sa,Su)'));
    });

    test('a graph with no restrictions writes no new arrays', () async {
      // The common case has to stay exactly as cheap as it was.
      final g = const GraphBuilder().build(crossroads());
      final back = const GraphDeserializer().deserializeGraph(
        const GraphSerializer().serializeGraph(g),
      );

      expect(back.splitParent, isNull);
      expect(back.adjCond, isNull);
      expect(back.conditions, isEmpty);
    });

    test('the header stays a multiple of eight', () async {
      // The reason it went 24 -> 32 rather than 24 -> 28: `asFloat64List`
      // throws on a misaligned offset, so a header that is not a multiple of
      // 8 makes every f64 array behind it unreadable rather than merely
      // slower.
      final g = const GraphBuilder().build(crossroads());
      final bytes = const GraphSerializer().serializeGraph(g);

      // lat[0] is the first f64, immediately after the header.
      final header = 32;
      expect(header % 8, isZero);
      expect(
        ByteData.view(bytes.buffer).getFloat64(header, Endian.host),
        closeTo(-23.5, 0.01),
      );
    });

    test('a v3 graph is refused rather than read as unrestricted', () async {
      // The dangerous direction. A v3 graph has no split junctions, so read
      // as a v4 every restriction in the city silently would not apply — and
      // the routes would look entirely reasonable while being illegal.
      final bytes = const GraphSerializer().serializeGraph(
        const GraphBuilder().build(crossroads()),
      );
      ByteData.view(bytes.buffer).setInt32(4, 3, Endian.little);

      expect(
        () => const GraphDeserializer().deserializeGraph(bytes),
        throwsA(isA<GraphFormatException>()),
      );
    });

    test('routing honours the ban, and still reaches the junction', () async {
      // The end of the exercise, through the real entry point.
      //
      // 1-2-3 then 3-4. With `only_straight_on` from 2, a route from 1 to 4
      // may not turn — but a route from 1 *to 3* must still arrive, and that
      // is the case the split breaks if the alias loop is missing: every path
      // reaching 3 from this approach lands on the copy, and under `only_*`
      // the real vertex can be left with no incoming edge at all.
      final storage = MemoryStorage();
      await storage.saveGraph('r', crossroads(restriction: 'only', toNode: 5));

      final router = DijkstraRouter(storage: storage, graphId: 'r');

      // To the junction itself: reachable, despite arriving on a copy.
      final toJunction = await router.findRoute(
        const GeoCoordinate(lat: -23.500, lon: -46.700),
        const GeoCoordinate(lat: -23.500, lon: -46.680),
      );
      expect(
        toJunction.found,
        isTrue,
        reason: 'a restricted junction must still be a destination',
      );

      // And the ban holds. Not by making 4 unreachable — it is still legally
      // reachable by continuing to 5 and turning round at that dead end,
      // which is a manoeuvre a driver may actually make — but by costing the
      // detour. Asserting "no route" here would be asserting something false.
      final free = MemoryStorage();
      await free.saveGraph('f', crossroads());

      final direct = await DijkstraRouter(storage: free, graphId: 'f')
          .findRoute(
            const GeoCoordinate(lat: -23.500, lon: -46.700),
            const GeoCoordinate(lat: -23.510, lon: -46.680),
          );

      final restricted = await router.findRoute(
        const GeoCoordinate(lat: -23.500, lon: -46.700),
        const GeoCoordinate(lat: -23.510, lon: -46.680),
      );

      expect(direct.found, isTrue);
      expect(restricted.found, isTrue);
      expect(
        restricted.distanceMeters,
        greaterThan(direct.distanceMeters),
        reason: 'the forbidden turn must cost a detour, not nothing',
      );
    });

    test('every router agrees on a restricted graph', () async {
      // Dijkstra, A* and CH must return the same answer, or the restriction is
      // being honoured by some searches and not others.
      final storage = MemoryStorage();
      await storage.saveGraph('r', crossroads(restriction: 'no'));

      const from = GeoCoordinate(lat: -23.500, lon: -46.700);
      const to = GeoCoordinate(lat: -23.490, lon: -46.680);

      final routers = <String, RouteFinder>{
        'dijkstra': DijkstraRouter(storage: storage, graphId: 'r'),
        'astar': AStarRouter(storage: storage, graphId: 'r'),
        'ch': ContractionHierarchyRouter(storage: storage, graphId: 'r'),
      };

      final distances = <String, double>{};
      for (final entry in routers.entries) {
        final route = await entry.value.findRoute(from, to);
        expect(route.found, isTrue, reason: entry.key);
        distances[entry.key] = route.distanceMeters;
      }

      expect(
        distances.values.toSet(),
        hasLength(1),
        reason: 'routers disagree: $distances',
      );
    });

    test('a conditional ban is closed when no clock is given', () async {
      // The deliberate default: a turn forbidden *sometimes* is treated as
      // forbidden. Assuming the permissive case would route a rider through a
      // junction they may be barred from at exactly the hour the restriction
      // exists for.
      final storage = MemoryStorage();
      await storage.saveGraph(
        'r',
        crossroads(restriction: 'no', condition: 'no_left_turn @ (Sa,Su)'),
      );

      final free = MemoryStorage();
      await free.saveGraph('f', crossroads());

      const from = GeoCoordinate(lat: -23.500, lon: -46.700);
      const to = GeoCoordinate(lat: -23.510, lon: -46.680);

      final direct = await DijkstraRouter(
        storage: free,
        graphId: 'f',
      ).findRoute(from, to);

      final restricted = await DijkstraRouter(
        storage: storage,
        graphId: 'r',
      ).findRoute(from, to);

      expect(
        restricted.distanceMeters,
        greaterThan(direct.distanceMeters),
        reason: 'a conditional ban with no clock must bite like a fixed one',
      );
    });

    test('a conditional `only_*` flags every exit but the one', () async {
      // The hardest combination in the feature, and the one where getting the
      // set backwards is least visible. An unconditional `only_*` deletes the
      // other exits; a conditional one cannot, because the same graph has to
      // answer both states — so the copy keeps *every* exit and flags all of
      // them except the one the sign names. Flag the named exit instead and
      // the restriction is inverted: the only legal movement becomes the only
      // forbidden one.
      final g = split(
        crossroads(
          restriction: 'only',
          condition: 'only_straight_on @ (Mo-Fr 07:00-09:00)',
        ),
      );

      final arrival = arrivalOf(g, 2, 3);
      expect(g.isSplitCopy(arrival), isTrue);
      expect(
        exitsFrom(g, arrival),
        equals({2, 4, 5, 6}),
        reason: 'nothing is deleted — the ban only applies inside the window',
      );

      for (var e = g.adjOffset[arrival]; e < g.adjOffset[arrival + 1]; e++) {
        final to = g.originalId[g.adjTarget[e]];

        if (to == 4) {
          expect(
            g.conditionOf(e),
            isNull,
            reason: 'the movement the sign permits is never conditional',
          );
        } else {
          expect(
            g.conditionOf(e),
            equals('only_straight_on @ (Mo-Fr 07:00-09:00)'),
            reason: 'exit to $to is forbidden while the window is open',
          );
        }
      }
    });

    test('a conditional `only_*` binds and releases on the clock', () async {
      // The same restriction as a rider meets it. Inside the window the only
      // way to 5 is out to 4 and back — which is legal, because arriving at
      // the junction from 4 is a different approach that no sign governs.
      final storage = MemoryStorage();
      await storage.saveGraph(
        'r',
        crossroads(
          restriction: 'only',
          condition: 'only_straight_on @ (Mo-Fr 07:00-09:00)',
        ),
      );

      // Node 5, which is *not* the exit the sign permits — node 4 is. Routing
      // to the permitted exit would be 1500 m in every case and would prove
      // nothing about the condition.
      const from = GeoCoordinate(lat: -23.500, lon: -46.700); // node 1
      const to = GeoCoordinate(lat: -23.490, lon: -46.680); // node 5

      final router = DijkstraRouter(storage: storage, graphId: 'r');

      // Monday 08:00 — only straight on, so the turn to 5 is closed and the
      // route goes 1-2-3' -> 4 -> 3 -> 5 rather than turning at the junction.
      final restricted = await router.findRoute(
        from,
        to,
        at: DateTime(2026, 9, 14, 8),
      );
      expect(restricted.found, isTrue);
      expect(restricted.distanceMeters, closeTo(2500, 1));

      // Sunday 08:00 — outside the window, so every exit is open again.
      final open = await router.findRoute(
        from,
        to,
        at: DateTime(2026, 9, 13, 8),
      );
      expect(open.distanceMeters, closeTo(1500, 1));

      // And with no clock at all, the strictest reading stands.
      final noClock = await router.findRoute(from, to);
      expect(
        noClock.distanceMeters,
        closeTo(2500, 1),
        reason: 'not knowing the time is not a reason to assume it is open',
      );
    });

    test('a clock reopens a turn outside its window', () async {
      // The point of carrying the expression rather than resolving it at build
      // time: one graph answers both states.
      final storage = MemoryStorage();
      await storage.saveGraph(
        'r',
        crossroads(
          restriction: 'no',
          condition: 'no_left_turn @ (Mo-Fr 07:00-09:00)',
        ),
      );

      final free = MemoryStorage();
      await free.saveGraph('f', crossroads());

      const from = GeoCoordinate(lat: -23.500, lon: -46.700);
      const to = GeoCoordinate(lat: -23.510, lon: -46.680);

      final direct = await DijkstraRouter(
        storage: free,
        graphId: 'f',
      ).findRoute(from, to);

      final router = DijkstraRouter(storage: storage, graphId: 'r');

      // Monday 08:00 — inside the window, so the detour stands.
      final restricted = await router.findRoute(
        from,
        to,
        at: DateTime(2026, 9, 14, 8),
      );
      expect(restricted.distanceMeters, greaterThan(direct.distanceMeters));

      // Sunday 08:00 — outside it, so the direct turn is legal again.
      final open = await router.findRoute(
        from,
        to,
        at: DateTime(2026, 9, 13, 8),
      );
      expect(
        open.distanceMeters,
        closeTo(direct.distanceMeters, 0.001),
        reason: 'outside its window the turn is simply allowed',
      );
    });

    test('every router agrees once a clock is supplied', () async {
      // CH cannot use its hierarchy for a clocked query — it was built with
      // conditional edges removed — so it falls back. The three must still
      // return the same answer, or the fallback is not equivalent.
      final storage = MemoryStorage();
      await storage.saveGraph(
        'r',
        crossroads(
          restriction: 'no',
          condition: 'no_left_turn @ (Mo-Fr 07:00-09:00)',
        ),
      );

      const from = GeoCoordinate(lat: -23.500, lon: -46.700);
      const to = GeoCoordinate(lat: -23.510, lon: -46.680);
      final sunday = DateTime(2026, 9, 13, 8);

      final distances = <String, double>{};
      for (final entry in <String, RouteFinder>{
        'dijkstra': DijkstraRouter(storage: storage, graphId: 'r'),
        'astar': AStarRouter(storage: storage, graphId: 'r'),
        'ch': ContractionHierarchyRouter(storage: storage, graphId: 'r'),
      }.entries) {
        final route = await entry.value.findRoute(from, to, at: sunday);
        expect(route.found, isTrue, reason: entry.key);
        distances[entry.key] = route.distanceMeters;
      }

      expect(
        distances.values.map((d) => d.round()).toSet(),
        hasLength(1),
        reason: 'routers disagree with a clock: $distances',
      );
    });

    test('two restricted junctions in series both bind', () async {
      // Arriving at a junction through a restricted approach lands on a copy,
      // and the copy's exits are the parent's. If one of those exits is itself
      // the approach of a *second* restriction, it has to lead to that
      // restriction's copy too — otherwise leaving the first junction hands
      // the rider a clean entry into the second, and the second sign is not
      // enforced for anyone who came that way.
      //
      // A one-way grid with a `no_left_turn` on consecutive blocks is exactly
      // this shape, so it is ordinary city data rather than a corner case.
      //
      //   1 — 2 — 3 — 6
      //       |
      //       5
      const nodes = [
        GeoNode(id: 1, lat: -23.500, lon: -46.700),
        GeoNode(id: 2, lat: -23.500, lon: -46.690),
        GeoNode(id: 3, lat: -23.500, lon: -46.680),
        GeoNode(id: 5, lat: -23.510, lon: -46.690),
        GeoNode(id: 6, lat: -23.500, lon: -46.670),
      ];

      const edges = [
        GeoEdge(sourceId: 1, targetId: 2, distanceMeters: 500, speedKmh: 36),
        GeoEdge(sourceId: 2, targetId: 3, distanceMeters: 500, speedKmh: 36),
        GeoEdge(sourceId: 2, targetId: 5, distanceMeters: 500, speedKmh: 36),
        GeoEdge(sourceId: 3, targetId: 6, distanceMeters: 500, speedKmh: 36),
      ];

      final geo = GeoGraph(
        nodes: nodes,
        edges: edges,
        turnRestrictions: const [
          // Arriving at 2 from 1, you may not turn to 5.
          GeoTurnRestriction(
            fromNodeId: 1,
            viaNodeId: 2,
            toNodeId: 5,
            isOnly: false,
          ),
          // Arriving at 3 from 2, you may not continue to 6.
          GeoTurnRestriction(
            fromNodeId: 2,
            viaNodeId: 3,
            toNodeId: 6,
            isOnly: false,
          ),
        ],
      );

      final storage = MemoryStorage();
      await storage.saveGraph('series', geo);

      // 6 hangs off 3, and 3 is only reachable from 2 — by the one edge the
      // second sign restricts. So there is no legal way in.
      final route = await DijkstraRouter(storage: storage, graphId: 'series')
          .findRoute(
            const GeoCoordinate(lat: -23.500, lon: -46.700), // 1
            const GeoCoordinate(lat: -23.500, lon: -46.670), // 6
          );

      expect(
        route.found,
        isFalse,
        reason:
            'the second restriction must bind a rider who arrived through '
            'the first',
      );
    });

    test('more conditions than a byte can hold saturate, not wrap', () async {
      // `adjCond` is one byte per edge, so past 255 distinct expressions the
      // index would wrap — and a wrapped value is still *in range*, so one
      // edge silently loses its condition and others are judged against some
      // other junction's timetable. Neither throws; both are wrong answers.
      //
      // The overflow slot holds an expression no parser can read, so it is
      // always in force: the failure over-restricts, which is the direction
      // every other decision here leans.
      const junction = 2;
      final nodes = <GeoNode>[
        const GeoNode(id: 1, lat: -23.500, lon: -46.700),
        const GeoNode(id: junction, lat: -23.500, lon: -46.690),
        for (var i = 0; i < 300; i++)
          GeoNode(id: 100 + i, lat: -23.510 - i * 0.001, lon: -46.690),
      ];

      final edges = <GeoEdge>[
        const GeoEdge(
          sourceId: 1,
          targetId: junction,
          distanceMeters: 500,
          speedKmh: 36,
        ),
        for (var i = 0; i < 300; i++)
          GeoEdge(
            sourceId: junction,
            targetId: 100 + i,
            distanceMeters: 500,
            speedKmh: 36,
          ),
      ];

      final geo = GeoGraph(
        nodes: nodes,
        edges: edges,
        turnRestrictions: [
          for (var i = 0; i < 300; i++)
            GeoTurnRestriction(
              fromNodeId: 1,
              viaNodeId: junction,
              toNodeId: 100 + i,
              isOnly: false,
              // Distinct per exit, which is what a city's worth of free-text
              // conditional expressions looks like.
              condition: 'no_turn @ (Mo-Fr 0$i:00-09:00)',
            ),
        ],
      );

      final g = const TurnRestrictionSplitter().split(
        const GraphBuilder().build(geo),
        geo.turnRestrictions,
      );

      expect(
        g.conditions.length,
        lessThanOrEqualTo(RoutingGraph.conditionOverflowIndex),
        reason: 'a byte cannot index more than this',
      );

      // No restricted exit carries an index past the end of the table, and
      // none wrapped to zero — which would read as "no condition at all", and
      // is exactly what the unguarded version produced.
      //
      // The way back to node 1 is not restricted and is expected to be 0, so
      // only the exits the signs name are checked.
      final arrival = arrivalOf(g, 1, junction);
      var restricted = 0;

      for (var e = g.adjOffset[arrival]; e < g.adjOffset[arrival + 1]; e++) {
        if (g.originalId[g.adjTarget[e]] == 1) continue;

        final index = g.adjCond![e];
        expect(index, isNot(isZero), reason: 'a sign names this exit');
        expect(index, lessThanOrEqualTo(g.conditions.length));
        expect(g.conditionOf(e), isNotNull);
        restricted++;
      }

      expect(restricted, equals(300));

      // And the overflow reading is "in force", not "open".
      expect(
        ConditionalRestriction.appliesAt(
          RoutingGraph.overflowCondition,
          DateTime(2026, 9, 13, 3),
        ),
        isTrue,
      );

      // The compressor rebuilds the table from scratch, so it has the same
      // ceiling to saturate at and its own copy of the code that does it. A
      // graph this size only reaches that branch after compression, which is
      // the form every shipped graph is in.
      final compressed = GraphCompressor().compress(g);

      expect(
        compressed.conditions.length,
        lessThanOrEqualTo(RoutingGraph.conditionOverflowIndex),
      );
      expect(
        compressed.conditions.last,
        equals(RoutingGraph.overflowCondition),
        reason: 'the last slot is the sentinel, not a real expression',
      );

      for (var e = 0; e < compressed.edgeCount; e++) {
        expect(
          compressed.adjCond![e],
          lessThanOrEqualTo(compressed.conditions.length),
          reason: 'no edge may index past the table it was rebuilt against',
        );
      }
    });

    test('an `only_*` junction can still be delivered to', () async {
      // Its copy has one way in and one out, which is exactly the shape a
      // chain merge swallows. Contracting it splices the approach straight to
      // the permitted exit — routing *through* stays correct, which is why
      // this went unnoticed — but it leaves the junction with no aliases and
      // no in-degree, so nothing can be delivered *to* it.
      //
      // It reads as "no route" for an address plainly on a street. Found on
      // Florianópolis, where 76 junctions were unreachable from anywhere in
      // the city; Avenida Madre Benvenuta was one of them.
      final storage = MemoryStorage();
      await storage.saveGraph('r', crossroads(restriction: 'only'));

      final route = await DijkstraRouter(storage: storage, graphId: 'r')
          .findRoute(
            const GeoCoordinate(lat: -23.500, lon: -46.700), // node 1
            const GeoCoordinate(lat: -23.500, lon: -46.680), // the junction
          );

      expect(
        route.found,
        isTrue,
        reason: 'a junction is a place, not only somewhere to pass through',
      );
      expect(route.distanceMeters, closeTo(1000, 1));
    });

    test('the alias loop takes the direct way in, not a lap', () async {
      // The destination fix, on the shape that first reached it. A `no_*` copy
      // at a crossroads keeps three exits, so it is an anchor either way.
      //
      // Arriving from 2, every path lands on the copy. Without the alias loop
      // the search cannot call that "reaching 3" and has to go round — out to
      // another arm and back — which is twice the distance.
      final storage = MemoryStorage();
      await storage.saveGraph('r', crossroads(restriction: 'no'));

      final route = await DijkstraRouter(storage: storage, graphId: 'r')
          .findRoute(
            const GeoCoordinate(lat: -23.500, lon: -46.700), // node 1
            const GeoCoordinate(
              lat: -23.500,
              lon: -46.680,
            ), // node 3, the junction
          );

      expect(route.found, isTrue);
      expect(
        route.distanceMeters,
        closeTo(1000, 1),
        reason: 'straight in along 1-2-3, not a lap through another arm',
      );
    });

    /// Two ways in to one restricted junction, so an *alternative* exists.
    ///
    ///           2
    ///          / \
    ///     7 — 1   4 — 5     way in via 2 is 1000 m, via 3 is 1200 m
    ///          \ /  \
    ///           3    6
    ///
    /// The ban is "arriving from 2, you may not turn to 5", so the junction
    /// splits and a route arriving via 2 lands on the copy while one arriving
    /// via 3 lands on 4 itself. A destination of 4 therefore has two vertices
    /// a search could legitimately reach.
    ///
    /// Node 7 is a stub that exists only to give node 1 a third edge. Without
    /// it node 1 is degree 2, the chain compressor merges 2-1-3 into one edge,
    /// and the start of every route below snaps to somewhere else entirely.
    GeoGraph twoWaysIn({int tollsOnFastRoute = 0}) {
      const nodes = [
        GeoNode(id: 1, lat: -23.500, lon: -46.700),
        GeoNode(id: 2, lat: -23.495, lon: -46.690),
        GeoNode(id: 3, lat: -23.505, lon: -46.690),
        GeoNode(id: 4, lat: -23.500, lon: -46.680),
        GeoNode(id: 5, lat: -23.510, lon: -46.680),
        GeoNode(id: 6, lat: -23.490, lon: -46.680),
        GeoNode(id: 7, lat: -23.500, lon: -46.710),
      ];

      return GeoGraph(
        nodes: nodes,
        edges: [
          const GeoEdge(
            sourceId: 1,
            targetId: 7,
            distanceMeters: 500,
            speedKmh: 36,
          ),
          GeoEdge(
            sourceId: 1,
            targetId: 2,
            distanceMeters: 500,
            speedKmh: 36,
            tolls: tollsOnFastRoute,
          ),
          GeoEdge(
            sourceId: 2,
            targetId: 4,
            distanceMeters: 500,
            speedKmh: 36,
            tolls: tollsOnFastRoute,
          ),
          const GeoEdge(
            sourceId: 1,
            targetId: 3,
            distanceMeters: 600,
            speedKmh: 36,
          ),
          const GeoEdge(
            sourceId: 3,
            targetId: 4,
            distanceMeters: 600,
            speedKmh: 36,
          ),
          const GeoEdge(
            sourceId: 4,
            targetId: 5,
            distanceMeters: 500,
            speedKmh: 36,
          ),
          const GeoEdge(
            sourceId: 4,
            targetId: 6,
            distanceMeters: 500,
            speedKmh: 36,
          ),
        ],
        turnRestrictions: const [
          GeoTurnRestriction(
            fromNodeId: 2,
            viaNodeId: 4,
            toNodeId: 5,
            isOnly: false,
          ),
        ],
      );
    }

    const start = GeoCoordinate(lat: -23.500, lon: -46.700); // node 1
    const junction = GeoCoordinate(lat: -23.500, lon: -46.680); // node 4

    test('alternatives to a split junction all arrive at it', () async {
      // `findRoutes` does not reuse `findRoute`'s search: alternatives go
      // through a *penalized* one, which has its own copy of the alias loop.
      // Until this test, that copy ran only in its single-target form — so the
      // branch that picks between a junction and its copies was dead code in
      // every test, on the path that serves both `avoidTolls` and every
      // alternative route.
      final storage = MemoryStorage();
      await storage.saveGraph('r', twoWaysIn());

      final routes = await DijkstraRouter(
        storage: storage,
        graphId: 'r',
      ).findRoutes(start, junction, maxRoutes: 2);

      expect(routes, hasLength(2));

      // Both actually end at the junction rather than near it, and neither
      // took a lap to get there. 1-2-4 is 1000 m and 1-3-4 is 1200 m; anything
      // longer means the search could not call the copy "arriving at 4" and
      // went round.
      expect(routes[0].distanceMeters, closeTo(1000, 1));
      expect(routes[1].distanceMeters, closeTo(1200, 1));

      for (final route in routes) {
        final last = route.geometry.last;
        expect(last.lat, closeTo(junction.lat, 1e-9));
        expect(last.lon, closeTo(junction.lon, 1e-9));
      }
    });

    test('alternatives keep avoiding tolls, seeded from the first', () async {
      // The alternative search starts from the toll-avoidance penalties rather
      // than from a neutral array, so route 2 steers clear of tolls as well as
      // route 1. Seeded from a flat array instead, `avoidTolls` would hold for
      // the first route and quietly lapse for every one after it — which is
      // the route a rider takes when the first is refused.
      final storage = MemoryStorage();
      await storage.saveGraph('r', twoWaysIn(tollsOnFastRoute: 1));

      final routes = await DijkstraRouter(
        storage: storage,
        graphId: 'r',
      ).findRoutes(start, junction, maxRoutes: 2, avoidTolls: true);

      expect(routes, isNotEmpty);
      expect(
        routes.first.distanceMeters,
        closeTo(1200, 1),
        reason: 'the longer toll-free way in wins',
      );
      expect(routes.every((r) => r.tollCount == 0), isTrue);
    });

    test('a route from a junction to itself is zero, not a lap', () async {
      // Snapping start and end to the same vertex. Worth pinning here because
      // the junction has copies: an early return that compared the wrong pair
      // would send a rider once around the block to arrive where they stand.
      final storage = MemoryStorage();
      await storage.saveGraph('r', twoWaysIn());

      final routes = await DijkstraRouter(
        storage: storage,
        graphId: 'r',
      ).findRoutes(junction, junction, maxRoutes: 2);

      expect(routes, hasLength(1));
      expect(routes.single.distanceMeters, isZero);
      expect(routes.single.duration, Duration.zero);
    });

    test('a split copy keeps the geometry of the edges it copies', () async {
      // The copy duplicates its parent's exit edges, intermediate points and
      // all. Dropped, the restricted route still costs the right distance and
      // draws as a straight line through whatever the road actually bends
      // around — correct arithmetic over a shape that is not the road.
      final base = crossroads(restriction: 'no');

      // Nodes 70+ appear only as shape points, so the builder folds them into
      // edge geometry rather than making them vertices. Every arm of the
      // junction gets one, so no exit of the copy is straight and a dropped
      // geometry shows up as an empty list.
      final shapeOf = {2: 72, 4: 74, 5: 75, 6: 76};

      final bent = GeoGraph(
        nodes: [
          ...base.nodes,
          for (final id in shapeOf.values)
            GeoNode(id: id, lat: -23.5005, lon: -46.6805),
        ],
        edges: [
          for (final e in base.edges)
            GeoEdge(
              sourceId: e.sourceId,
              targetId: e.targetId,
              distanceMeters: e.distanceMeters,
              speedKmh: e.speedKmh,
              tolls: e.tolls,
              shapePoints: [
                if (e.sourceId == 3) shapeOf[e.targetId]!,
                if (e.targetId == 3) shapeOf[e.sourceId]!,
              ],
            ),
        ],
        turnRestrictions: base.turnRestrictions,
      );

      final g = split(bent);
      final arrival = arrivalOf(g, 2, 3);

      expect(g.isSplitCopy(arrival), isTrue);

      for (var e = g.adjOffset[arrival]; e < g.adjOffset[arrival + 1]; e++) {
        expect(
          g.geometryOf(e),
          hasLength(1),
          reason: 'the copy carries the road shape, not just the endpoints',
        );
        expect(g.geometryOf(e).single.lat, closeTo(-23.5005, 1e-9));
      }
    });

    test('survives the compiled pipeline, which is what ships', () async {
      // Every other routing test here goes through `MemoryStorage`, i.e. the
      // generic `GeoStorage` path — and `ensureLoaded` has *two* branches. The
      // one production uses is this one: `OsmConverter.convert` writes the
      // .graph/.index/.meta triple and the router loads the compiled artifact.
      //
      // So this is the path where the split has to survive serialization, the
      // KD-tree subset has to round-trip, and the compressor has to have kept
      // the parent alive. Testing only the generic path would leave all of
      // that unexercised in the shape that actually ships.
      final dir = Directory.systemTemp.createTempSync('grf_compiled_');

      try {
        final path = writeTempPbf(
          _junction(
            restriction: const {
              'type': 'restriction',
              'restriction': 'no_left_turn',
            },
          ),
        );

        try {
          await OsmConverter().convert(
            inputFile: path,
            storage: LocalFileStorage(directory: dir.path),
            graphId: 'compiled',
          );
        } finally {
          File(path).parent.deleteSync(recursive: true);
        }

        final loaded = await LocalFileStorage(
          directory: dir.path,
        ).loadCompiled('compiled', profile: VehicleProfile.car);

        final g = loaded!.graph;

        expect(
          g.splitParent,
          isNotNull,
          reason: 'the split must survive being written and read back',
        );
        expect(
          [
            for (var v = 0; v < g.nodeCount; v++)
              if (g.isSplitCopy(v)) v,
          ],
          isNotEmpty,
          reason: 'a restricted junction must still be split after compiling',
        );

        // And the index still snaps, despite covering fewer vertices than the
        // graph has.
        expect(loaded.tree.order.length, lessThan(g.nodeCount));
        final snapped = loaded.tree.findNearest(-23.50, -46.68);
        expect(g.isSplitCopy(snapped.node), isFalse);
      } finally {
        dir.deleteSync(recursive: true);
      }
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

    test('signs that contradict each other are counted, not obeyed', () async {
      // "only straight on" and "no straight on" from the same arm. Honouring
      // both strands the approach; honouring either invents a sign. The only
      // honest move is to enforce neither and say so.
      final base = crossroads();
      final g = split(
        GeoGraph(
          nodes: base.nodes,
          edges: base.edges,
          turnRestrictions: const [
            GeoTurnRestriction(
              fromNodeId: 2,
              viaNodeId: 3,
              toNodeId: 4,
              isOnly: true,
            ),
            GeoTurnRestriction(
              fromNodeId: 2,
              viaNodeId: 3,
              toNodeId: 4,
              isOnly: false,
            ),
          ],
        ),
      );

      expect(
        g.splitParent,
        isNull,
        reason: 'the approach must not be stranded',
      );

      final stats = TurnRestrictionSplitter.lastStats!;
      expect(stats.applied, isZero);
      expect(
        stats.contradictory,
        equals(2),
        reason:
            'counted in restrictions, so the report adds up against what '
            'was read — not in approaches, which would say 1 for both signs',
      );
    });

    test('the split counts describe themselves', () async {
      // This string is the whole interface to the split for whoever runs a
      // build: the loss is invisible by construction — a forbidden turn is an
      // edge that is not there — so a mislabelled count is a number read as
      // the wrong thing entirely. `applied` and `copies` are especially easy
      // to swap, and they are not the same unit.
      const stats = TurnRestrictionSplitStats(
        applied: 7,
        unresolved: 1,
        contradictory: 2,
        inert: 3,
        copies: 5,
      );

      final text = stats.toString();
      expect(text, contains('7 applied'));
      expect(text, contains('5 copies'));
      expect(text, contains('1 unresolved'));
      expect(text, contains('2 contradictory'));
      expect(text, contains('3 inert'));
      expect(text, contains('0 orphaned'));
    });

    /// Two one-way approaches, two one-way exits, and a sign on each approach
    /// sending it to the same exit — so the other exit is left with no way in.
    ///
    /// Drawn from OSM node 1874470572, where Rodovia Admar Gonzaga (SC-404)
    /// meets Avenida Madre Benvenuta in Florianópolis. Relation 2364753
    /// (`only_straight_on`, from Madre Benvenuta) and relation 21323550
    /// (`only_left_turn`, from Admar Gonzaga) both name the same slip road,
    /// which leaves the SC-404's own continuation unenterable. The graph obeyed
    /// both, the router detoured, and nothing in the build said why.
    ///
    ///     1 ——→ 3 ——→ 5      1,2 approach; 4 is the slip road both
    ///           ↑ ↘          signs name; 5 is the severed mainline
    ///           2   4
    GeoGraph severed({
      bool secondApproachRestricted = true,
      bool isOnly = true,
    }) {
      const nodes = [
        GeoNode(id: 1, lat: -23.500, lon: -46.700),
        GeoNode(id: 2, lat: -23.510, lon: -46.690),
        GeoNode(id: 3, lat: -23.500, lon: -46.690),
        GeoNode(id: 4, lat: -23.510, lon: -46.680),
        GeoNode(id: 5, lat: -23.500, lon: -46.680),
      ];

      const edges = [
        GeoEdge(
          sourceId: 1,
          targetId: 3,
          distanceMeters: 500,
          speedKmh: 60,
          oneWay: true,
        ),
        GeoEdge(
          sourceId: 2,
          targetId: 3,
          distanceMeters: 500,
          speedKmh: 60,
          oneWay: true,
        ),
        GeoEdge(
          sourceId: 3,
          targetId: 4,
          distanceMeters: 500,
          speedKmh: 60,
          oneWay: true,
        ),
        GeoEdge(
          sourceId: 3,
          targetId: 5,
          distanceMeters: 500,
          speedKmh: 60,
          oneWay: true,
        ),
      ];

      return GeoGraph(
        nodes: nodes,
        edges: edges,
        turnRestrictions: [
          GeoTurnRestriction(
            fromNodeId: 1,
            viaNodeId: 3,
            toNodeId: 4,
            isOnly: isOnly,
          ),
          if (secondApproachRestricted)
            GeoTurnRestriction(
              fromNodeId: 2,
              viaNodeId: 3,
              toNodeId: 4,
              isOnly: isOnly,
            ),
        ],
      );
    }

    test('reports a road every approach is forbidden to enter', () async {
      split(severed());

      expect(
        TurnRestrictionSplitter.lastStats!.orphanedExits,
        equals(const [OrphanedExit(viaNodeId: 3, toNodeId: 5)]),
        reason:
            'both signs name exit 4, so nothing may enter 5 — which is a '
            'carriageway no vehicle can legally reach',
      );
    });

    test('still refuses the movement it reports', () async {
      // The point of the report is that the data is suspect, not that the
      // graph should second-guess it. Inventing a movement no sign allows is
      // precisely the failure this package exists to prevent, so the exit stays
      // unreachable and the build says so.
      final g = split(severed());

      final reachable = {
        for (var v = 0; v < g.nodeCount; v++)
          for (var e = g.adjOffset[v]; e < g.adjOffset[v + 1]; e++)
            if (g.originalId[v] == 3 && g.isSplitCopy(v))
              g.originalId[g.adjTarget[e]],
      };

      expect(reachable, equals({4}));
      expect(TurnRestrictionSplitter.lastStats!.applied, equals(2));
    });

    test('one unrestricted approach means nothing is orphaned', () async {
      // Approach 2 carries no sign, so it reaches every exit and the junction
      // is fine however severe the sign on approach 1 is. This is the check
      // that keeps the report from firing on every ordinary `only_*`.
      split(severed(secondApproachRestricted: false));

      expect(TurnRestrictionSplitter.lastStats!.orphanedExits, isEmpty);
      expect(TurnRestrictionSplitter.lastStats!.applied, equals(1));
    });

    test('a `no_*` orphans what it names, an `only_*` what it does not', () {
      // The same two approaches and the same two signs, differing only in
      // kind, and they strand opposite roads. `no_*` closes exit 4, the one it
      // names; `only_*` closes exit 5, which neither sign mentions at all.
      //
      // That second case is why this check is worth having. Nobody writes a
      // relation meaning to sever a road they never named — it is the reach of
      // `only_*` that does it, and the reach is invisible in the relation.
      split(severed(isOnly: false));
      expect(
        TurnRestrictionSplitter.lastStats!.orphanedExits,
        equals(const [OrphanedExit(viaNodeId: 3, toNodeId: 4)]),
      );

      split(severed());
      expect(
        TurnRestrictionSplitter.lastStats!.orphanedExits,
        equals(const [OrphanedExit(viaNodeId: 3, toNodeId: 5)]),
      );
    });

    test('an orphaned exit reads as a place, not a number', () async {
      // Whoever sees this has to find the junction in an editor, so the string
      // carries the two ids that locate it rather than just a count.
      const orphan = OrphanedExit(viaNodeId: 1874470572, toNodeId: 2380729425);

      expect(orphan.toString(), contains('1874470572'));
      expect(orphan.toString(), contains('2380729425'));
    });

    test('the same orphaned exit is one entry, not two', () async {
      // Value equality has to reach `hashCode` as well as `==`, or a caller
      // collecting these into a set to de-duplicate across profiles gets one
      // entry per car, bike and foot build of the same junction.
      const a = OrphanedExit(viaNodeId: 3, toNodeId: 5);
      const b = OrphanedExit(viaNodeId: 3, toNodeId: 5);
      const other = OrphanedExit(viaNodeId: 3, toNodeId: 4);

      final seen = <OrphanedExit, int>{};
      for (final o in const [a, b, other]) {
        seen[o] = (seen[o] ?? 0) + 1;
      }

      expect(seen, hasLength(2));
      expect(seen[a], equals(2), reason: 'a and b are the same junction');
      expect(a.hashCode, equals(b.hashCode));
    });

    test('the read counts mention orphaned exits only when there are any', () {
      // This string is what a build prints. An unconditional "0 orphaned
      // exits" on every clean build is noise that trains the reader to skip
      // the line — which is the one line that matters on the build where it
      // is not zero.
      const clean = TurnRestrictionStats(accepted: 4);
      expect(clean.toString(), isNot(contains('orphaned')));

      const severed = TurnRestrictionStats(
        accepted: 4,
        orphanedExits: [
          OrphanedExit(viaNodeId: 1874470572, toNodeId: 2380729425),
        ],
      );
      expect(severed.toString(), contains('1 orphaned exits'));
    });

    test('a restriction naming an exit the junction lacks is inert', () async {
      // Node 1 is not an exit of node 3, so the ban removes nothing and the
      // copy would permit exactly what its parent does — a vertex, a duplicate
      // of every exit edge, and a pin against compression, all for no effect.
      final g = split(crossroads(restriction: 'no', toNode: 1));

      expect(g.splitParent, isNull);
      expect(TurnRestrictionSplitter.lastStats!.inert, equals(1));
    });

    test('a restriction this graph has no nodes for is counted', () async {
      final g = split(crossroads(restriction: 'no', toNode: 999));

      expect(g.splitParent, isNull);
      expect(TurnRestrictionSplitter.lastStats!.unresolved, equals(1));
    });

    test('the counts describe this build, not the one before it', () async {
      // `lastStats` is static by design, which makes every early return a
      // chance to leave the previous build's numbers standing — and they do not
      // read as stale, they read as this build's.
      split(crossroads(restriction: 'no'));
      expect(TurnRestrictionSplitter.lastStats!.applied, equals(1));

      split(crossroads(restriction: 'no', toNode: 999));
      expect(TurnRestrictionSplitter.lastStats!.applied, isZero);
      expect(TurnRestrictionSplitter.lastStats!.unresolved, equals(1));

      split(crossroads());
      expect(TurnRestrictionSplitter.lastStats!.unresolved, isZero);
    });

    test('a condition containing a newline survives the round trip', () async {
      // `restriction:conditional` is free-form OSM text. The table used to be
      // newline-joined, so a value with a newline in it split into two entries
      // and shifted every later index by one — the file stayed self-consistent,
      // the CRC still matched, and the only symptom was conditional turns being
      // judged against another junction's timetable.
      final g = split(
        crossroads(restriction: 'no', condition: 'no_left_turn @\n(Sa,Su)'),
      );

      final back = const GraphDeserializer().deserializeGraph(
        const GraphSerializer().serializeGraph(g),
      );

      expect(back.conditions, equals(g.conditions));
      expect(back.conditions.single, equals('no_left_turn @\n(Sa,Su)'));
    });

    test('an edge naming a condition that is not there is refused', () async {
      // The index is one byte and the table is separate, so the two can
      // disagree. Caught at load, because `conditionOf` is called inside the
      // relaxation loops — where the choice is between throwing mid-search and
      // reading a neighbouring junction's timetable.
      final g = split(
        crossroads(restriction: 'no', condition: 'no_left_turn @ (Sa,Su)'),
      );

      final cond = Uint8List.fromList(g.adjCond!);
      cond[cond.indexWhere((c) => c != 0)] = 9;

      final bytes = const GraphSerializer().serializeGraph(
        RoutingGraph(
          lat: g.lat,
          lon: g.lon,
          originalId: g.originalId,
          adjOffset: g.adjOffset,
          adjTarget: g.adjTarget,
          adjTime: g.adjTime,
          adjDist: g.adjDist,
          adjToll: g.adjToll,
          adjSignal: g.adjSignal,
          adjAccess: g.adjAccess,
          geomCoords: g.geomCoords,
          geomOffset: g.geomOffset,
          splitParent: g.splitParent,
          adjCond: cond,
          conditions: g.conditions,
        ),
      );

      expect(
        () => const GraphDeserializer().deserializeGraph(bytes),
        throwsA(isA<GraphFormatException>()),
      );
    });

    test('an index with no expression behind it bans the turn', () async {
      // The guard inside `conditionOf`, which runs in the relaxation loops.
      // Unreachable through either producer — the splitter allocates every
      // index it writes and the deserializer refuses a graph that disagrees
      // with its table — so it asserts, and falls back to the reading that
      // cannot hand back an illegal route.
      final g = split(
        crossroads(restriction: 'no', condition: 'no_left_turn @ (Sa,Su)'),
      );

      final cond = Uint8List.fromList(g.adjCond!);
      final bad = cond.indexWhere((c) => c != 0);
      cond[bad] = 9;

      final broken = RoutingGraph(
        lat: g.lat,
        lon: g.lon,
        originalId: g.originalId,
        adjOffset: g.adjOffset,
        adjTarget: g.adjTarget,
        adjTime: g.adjTime,
        adjDist: g.adjDist,
        adjToll: g.adjToll,
        adjSignal: g.adjSignal,
        adjAccess: g.adjAccess,
        geomCoords: g.geomCoords,
        geomOffset: g.geomOffset,
        splitParent: g.splitParent,
        adjCond: cond,
        conditions: g.conditions,
      );

      expect(() => broken.conditionOf(bad), throwsA(isA<AssertionError>()));
    });

    test('a truncated condition table is refused', () async {
      final g = split(
        crossroads(restriction: 'no', condition: 'no_left_turn @ (Sa,Su)'),
      );
      final bytes = const GraphSerializer().serializeGraph(g);

      // Shrink the declared blob so the last expression runs off the end.
      final bd = ByteData.view(bytes.buffer);
      bd.setInt32(28, bd.getInt32(28, Endian.little) - 4, Endian.little);

      expect(
        () => const GraphDeserializer().deserializeGraph(bytes),
        throwsA(isA<GraphFormatException>()),
      );
    });

    test('a condition count the blob cannot hold is refused', () async {
      // Checked before anything is allocated for it, so a corrupt count is a
      // format error rather than an out-of-memory.
      final g = split(
        crossroads(restriction: 'no', condition: 'no_left_turn @ (Sa,Su)'),
      );
      final bytes = const GraphSerializer().serializeGraph(g);
      final bd = ByteData.view(bytes.buffer);

      // The table sits at the very end of the payload, counted by the header.
      final condStart = bytes.length - bd.getInt32(28, Endian.little);
      bd.setInt32(condStart, 1 << 20, Endian.little);

      expect(
        () => const GraphDeserializer().deserializeGraph(bytes),
        throwsA(isA<GraphFormatException>()),
      );
    });

    test('a condition table with bytes left over is refused', () async {
      // Every entry is length-prefixed, so the last one has to land exactly on
      // the end. Anything else means the table and the count disagree about
      // where the entries are, and every index past that point is wrong.
      final g = split(
        crossroads(restriction: 'no', condition: 'no_left_turn @ (Sa,Su)'),
      );
      final bytes = const GraphSerializer().serializeGraph(g);
      final bd = ByteData.view(bytes.buffer);

      final condStart = bytes.length - bd.getInt32(28, Endian.little);
      // Shorten the one expression, leaving its tail unaccounted for.
      bd.setInt32(
        condStart + 4,
        bd.getInt32(condStart + 4, Endian.little) - 3,
        Endian.little,
      );

      expect(
        () => const GraphDeserializer().deserializeGraph(bytes),
        throwsA(
          isA<GraphFormatException>().having(
            (e) => e.message,
            'message',
            contains('trailing'),
          ),
        ),
      );
    });

    test('an index entry outside the graph is refused', () async {
      // The likeliest cause is a stale `.index` beside a graph that has since
      // been rebuilt smaller. Unchecked, the entry lands as a subscript deep
      // inside a nearest-neighbour descent, and the error names neither file.
      final g = split(crossroads(restriction: 'no'));
      final bytes = const GraphSerializer().serializeIndex(KdTree.build(g));

      ByteData.view(bytes.buffer).setInt32(24, g.nodeCount, Endian.little);

      expect(
        () => const GraphDeserializer().deserializeIndex(bytes, g),
        throwsA(isA<GraphFormatException>()),
      );
    });

    test('an index that claims more entries than it has is refused', () async {
      final g = split(crossroads(restriction: 'no'));
      final bytes = const GraphSerializer().serializeIndex(KdTree.build(g));

      ByteData.view(bytes.buffer).setInt32(12, 1 << 20, Endian.little);

      expect(
        () => const GraphDeserializer().deserializeIndex(bytes, g),
        throwsA(isA<GraphFormatException>()),
      );
    });

    test('saving a graph splits it, exactly as compiling one does', () async {
      // `saveGraph` builds and indexes on its own, so it was the one path that
      // never ran the splitter — and the loss was silent, because the graph it
      // wrote routes perfectly well while offering every turn the signs forbid.
      final dir = Directory.systemTemp.createTempSync('grf_save');
      try {
        final storage = LocalFileStorage(directory: dir.path);
        await storage.saveGraph('x', crossroads(restriction: 'no'));

        final compiled = await storage.loadCompiled('x');
        final g = compiled!.graph;

        expect(g.splitParent, isNotNull);

        final arrival = arrivalOf(g, 2, 3);
        expect(g.isSplitCopy(arrival), isTrue);
        expect(exitsFrom(g, arrival), isNot(contains(4)));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('a split graph is refused as a GeoGraph, not collapsed', () async {
      // A `GeoGraph` is keyed by OSM id and the copies share their parent's,
      // so they would merge back into it and take every restriction with them.
      // The collapsed graph routes fine and is wrong, which is the case for
      // refusing rather than returning it.
      final dir = Directory.systemTemp.createTempSync('grf_load');
      try {
        final storage = LocalFileStorage(directory: dir.path);
        await storage.saveGraph('x', crossroads(restriction: 'no'));

        expect(storage.loadGraph('x'), throwsA(isA<StateError>()));

        // And an unrestricted graph still round-trips, as it always did.
        await storage.saveGraph('plain', crossroads());
        expect(await storage.loadGraph('plain'), isNotNull);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
