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
}
