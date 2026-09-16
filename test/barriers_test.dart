import 'dart:io';
import 'dart:typed_data';

import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Gates, bollards and the rest.
///
/// These are *node* tags on a way's vertices, and nothing read them: a bollard,
/// a locked gate and a fire barrier were plain vertices and every route drove
/// straight through them. A barrier that is not read is not a slower route, it
/// is a rider arriving at something they cannot pass.

/// A straight road 1-2-3-4, with node 3 optionally carrying a barrier.
///
///     1 ——— 2 ——— 3 ——— 4
Uint8List _road({
  Map<String, String>? barrier,
  String highway = 'residential',
}) => buildOsmPbf(
  nodeIds: const [1, 2, 3, 4],
  lats: const [-23.500, -23.500, -23.500, -23.500],
  lons: const [-46.700, -46.690, -46.680, -46.670],
  ways: [
    (id: 10, nodeIds: const [1, 2, 3, 4], tags: {'highway': highway}),
  ],
  taggedNodes: barrier == null ? const {} : {3: barrier},
);

void main() {
  Future<GeoGraph> read(
    Uint8List pbf, {
    VehicleProfile profile = VehicleProfile.car,
  }) async {
    final path = writeTempPbf(pbf);
    try {
      return await OsmConverter(profile: profile).toGeoGraph(path);
    } finally {
      File(path).parent.deleteSync(recursive: true);
    }
  }

  /// Whether the graph still lets a route run from end to end.
  bool passable(GeoGraph geo) {
    final g = const GraphBuilder().build(geo);

    final from = [
      for (var v = 0; v < g.nodeCount; v++)
        if (g.originalId[v] == 1) v,
    ].single;
    final to = [
      for (var v = 0; v < g.nodeCount; v++)
        if (g.originalId[v] == 4) v,
    ].single;

    // Plain reachability, so the test says "can you get there" rather than
    // depending on how the search happens to be built.
    final seen = <int>{from};
    final queue = <int>[from];
    while (queue.isNotEmpty) {
      final v = queue.removeLast();
      if (v == to) return true;
      for (var e = g.adjOffset[v]; e < g.adjOffset[v + 1]; e++) {
        final w = g.adjTarget[e];
        if (seen.add(w)) queue.add(w);
      }
    }
    return false;
  }

  group('what stops a car', () {
    test('an untagged road with no barrier is passable', () async {
      expect(passable(await read(_road())), isTrue);
    });

    for (final barrier in const [
      'bollard',
      'block',
      'chain',
      'jersey_barrier',
      'cycle_barrier',
      'stile',
      'kissing_gate',
      'turnstile',
    ]) {
      test('barrier=$barrier stops a car', () async {
        final geo = await read(_road(barrier: {'barrier': barrier}));
        expect(passable(geo), isFalse);
      });
    }

    for (final barrier in const [
      'toll_booth',
      'border_control',
      'cattle_grid',
      'entrance',
      'arch',
    ]) {
      test('barrier=$barrier lets a car through', () async {
        expect(
          passable(await read(_road(barrier: {'barrier': barrier}))),
          isTrue,
        );
      });
    }

    test('an unrecognised barrier stops a car', () async {
      // Deliberately cautious, and the opposite of how an unreadable *access
      // value* is treated. An unknown `barrier=` is a mapper saying a physical
      // thing stands in the road; over-blocking costs a detour, under-blocking
      // sends a rider into something they cannot see on the map.
      final geo = await read(_road(barrier: {'barrier': 'something_new'}));
      expect(passable(geo), isFalse);
    });
  });

  group('what stops a car but not a bicycle', () {
    for (final barrier in const ['bollard', 'block', 'bus_trap']) {
      test('barrier=$barrier', () async {
        // Their whole purpose: keep cars out of somewhere people cycle.
        final pbf = _road(barrier: {'barrier': barrier});

        expect(passable(await read(pbf)), isFalse);
        expect(
          passable(await read(pbf, profile: VehicleProfile.bicycle)),
          isTrue,
        );
      });
    }
  });

  group('a gate takes its default from the road it sits on', () {
    test('on a residential street it stands open', () async {
      // Most mappers leave a passable gate untagged and put `access=private`
      // on the shut ones. Blocking every bare gate would cut public streets on
      // a guess.
      final geo = await read(_road(barrier: {'barrier': 'gate'}));
      expect(passable(geo), isTrue);
    });

    test('on a service road it is a property boundary', () async {
      final geo = await read(
        _road(barrier: {'barrier': 'gate'}, highway: 'service'),
      );
      expect(passable(geo), isFalse);
    });

    test('on a track it is a property boundary', () async {
      final geo = await read(
        _road(barrier: {'barrier': 'gate'}, highway: 'track'),
      );
      expect(passable(geo), isFalse);
    });
  });

  group('the node tags win over every default', () {
    test('access=private shuts a gate on any road', () async {
      final geo = await read(
        _road(barrier: {'barrier': 'gate', 'access': 'private'}),
      );
      expect(passable(geo), isFalse);
    });

    test('locked=yes shuts it too', () async {
      final geo = await read(
        _road(barrier: {'barrier': 'gate', 'locked': 'yes'}),
      );
      expect(passable(geo), isFalse, reason: 'a locked gate is a wall');
    });

    test('motor_vehicle=yes opens a bollard for a car', () async {
      // The mapper knows something the category default does not.
      final geo = await read(
        _road(barrier: {'barrier': 'bollard', 'motor_vehicle': 'yes'}),
      );
      expect(passable(geo), isTrue);
    });

    test('a gate on a service road opens when it says so', () async {
      final geo = await read(
        _road(
          barrier: {'barrier': 'gate', 'access': 'yes'},
          highway: 'service',
        ),
      );
      expect(passable(geo), isTrue);
    });
  });

  group('severing keeps the gate reachable from both sides', () {
    test('the gate becomes two vertices at one coordinate', () async {
      // Mechanism (b). Dropping the node instead would stop both sides a node
      // short of the gate — and for a delivery the gate usually *is* the
      // address.
      final geo = await read(
        _road(barrier: {'barrier': 'gate'}, highway: 'service'),
      );

      final atGate = geo.nodes
          .where((n) => n.lat == -23.500 && n.lon == -46.680)
          .toList();

      expect(atGate, hasLength(2));
      expect(
        atGate.map((n) => n.id).toSet(),
        hasLength(2),
        reason: 'the twin needs an id of its own',
      );
      expect(
        atGate.any((n) => n.id < 0),
        isTrue,
        reason: 'negative, because OSM never issues one',
      );
    });

    test('each side reaches its own half of the gate', () async {
      final geo = await read(
        _road(barrier: {'barrier': 'gate'}, highway: 'service'),
      );
      final g = const GraphBuilder().build(geo);

      int vertexOf(int osmId) => [
        for (var v = 0; v < g.nodeCount; v++)
          if (g.originalId[v] == osmId) v,
      ].single;

      Set<int> reachableFrom(int start) {
        final seen = <int>{start};
        final queue = <int>[start];
        while (queue.isNotEmpty) {
          final v = queue.removeLast();
          for (var e = g.adjOffset[v]; e < g.adjOffset[v + 1]; e++) {
            if (seen.add(g.adjTarget[e])) queue.add(g.adjTarget[e]);
          }
        }
        return seen;
      }

      // Node 1's side reaches the real gate node; node 4's side reaches the
      // twin. Neither reaches the other.
      expect(reachableFrom(vertexOf(1)), contains(vertexOf(3)));
      expect(reachableFrom(vertexOf(1)), isNot(contains(vertexOf(4))));
      expect(reachableFrom(vertexOf(4)), isNot(contains(vertexOf(1))));
    });

    test('a route to the gate finds the side it can reach', () async {
      // The alias that makes mechanism (b) usable. Snapping picks one of the
      // two vertices at the gate's coordinate, and without aliasing a route
      // from the wrong side reports no route at all.
      final storage = MemoryStorage();
      await storage.saveGraph(
        'r',
        await read(_road(barrier: {'barrier': 'gate'}, highway: 'service')),
      );

      final route = await DijkstraRouter(storage: storage, graphId: 'r')
          .findRoute(
            const GeoCoordinate(lat: -23.500, lon: -46.700), // node 1
            const GeoCoordinate(lat: -23.500, lon: -46.680), // the gate
          );

      expect(route.found, isTrue);
      expect(
        route.distanceMeters,
        greaterThan(0),
        reason: 'the rider is taken to the gate, not told there is no route',
      );
    });
  });

  group('at the edge of a clipped extract', () {
    test('a way running past the box keeps the part inside it', () async {
      // Every pack is built from a clip, so a way whose far nodes fall outside
      // the box is the ordinary case rather than a corruption. The severing
      // walk reads the whole node list, so it meets those ids too.
      final pbf = buildOsmPbf(
        nodeIds: const [1, 2],
        lats: const [-23.500, -23.500],
        lons: const [-46.700, -46.690],
        ways: [
          // Nodes 3 and 4 are referenced and never defined.
          (
            id: 10,
            nodeIds: const [1, 2, 3, 4],
            tags: const {'highway': 'service'},
          ),
        ],
      );

      final path = writeTempPbf(pbf);
      try {
        final geo = await OsmConverter().toGeoGraph(path);

        expect(geo.nodes.map((n) => n.id), containsAll(<int>[1, 2]));
        expect(
          geo.edges.any((e) => e.sourceId == 1 && e.targetId == 2),
          isTrue,
        );
        expect(
          geo.nodes.any((n) => n.id < 0),
          isFalse,
          reason: 'nothing was severed, so no twin should exist',
        );
      } finally {
        File(path).parent.deleteSync(recursive: true);
      }
    });
  });

  group('reading them can be declined', () {
    test('readBarriers: false leaves the road whole', () async {
      final path = writeTempPbf(
        _road(barrier: {'barrier': 'gate'}, highway: 'service'),
      );

      try {
        final geo = await OsmConverter(readBarriers: false).toGeoGraph(path);

        expect(passable(geo), isTrue);
        expect(geo.nodes.any((n) => n.id < 0), isFalse);
      } finally {
        File(path).parent.deleteSync(recursive: true);
      }
    });
  });
}
