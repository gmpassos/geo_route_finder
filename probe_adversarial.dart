import 'dart:typed_data';

import 'package:geo_route_finder/geo_route_finder.dart';

/// PROBE 3: a conditional edge in a chain interior when splitParent is absent.
///
/// `_pinnedVertices` returns all-false the moment `splitParent == null`, so
/// nothing is pinned and the chain walk is free to swallow a conditional edge.
/// Straight line: 0 -> 1 -> 2 -> 3, all one-way, with the 1->2 edge conditional.
void probe3() {
  print('--- PROBE 3: conditional edge swallowed when splitParent is null ---');
  final n = 4;
  final g = RoutingGraph(
    lat: Float64List.fromList([0, 0.001, 0.002, 0.003]),
    lon: Float64List.fromList([0, 0, 0, 0]),
    originalId: Int64List.fromList([10, 11, 12, 13]),
    adjOffset: Int32List.fromList([0, 1, 2, 3, 3]),
    adjTarget: Int32List.fromList([1, 2, 3]),
    adjTime: Float64List.fromList([10, 10, 10]),
    adjDist: Float64List.fromList([100, 100, 100]),
    adjToll: Uint8List(3),
    adjSignal: Uint8List(3),
    geomCoords: Float64List(0),
    geomOffset: Int32List.fromList([0, 0, 0, 0]),
    // No splitParent. adjCond marks edge 1 (1->2) as conditional.
    adjCond: Uint8List.fromList([0, 1, 0]),
    conditions: const ['no_left_turn @ (Mo-Fr 07:00-09:00)'],
  );
  print('before: $g  conditions=${g.conditions}');
  // Vertices 1 and 2 have in=1/out=1 so both are contractible.
  try {
    final c = GraphCompressor(minComponentNodes: 1).compress(g);
    print('after : $c  conditions=${c.conditions}  adjCond=${c.adjCond}');
    print(
      'the condition survived? ${c.conditions.isNotEmpty} '
      '(assert did not fire - so this is what a release build does)',
    );
  } catch (e) {
    print('threw (assert fired, debug-only): $e');
  }
  print('n=$n');
}

/// PROBE 4: the alias loop picks by distance while the search minimises time.
///
/// Destination junction D(=node 50) is split, so `_targetsFor` yields
/// [D, D_copy]. One approach reaches D directly on a slow road; the other
/// reaches D_copy on a fast road. The fast one is LONGER in metres, so the
/// alias loop discards it even though the contract says "fastest".
Future<void> probe4() async {
  print('');
  print('--- PROBE 4: alias loop compares metres, search minimises seconds ---');

  // S(1) --slow,short--> A(2) --> D(5)
  // S(1) --fast,long---> B(3) --> D(5)        (B->D is the restricted approach)
  // D(5) --> E(6), D(5) --> F(7)
  // Restriction: from B(3), via D(5), to F(7) forbidden -> D is split.
  final nodes = <GeoNode>[
    GeoNode(id: 1, lat: 0.000, lon: 0.000),
    GeoNode(id: 2, lat: 0.010, lon: 0.000),
    GeoNode(id: 3, lat: -0.010, lon: 0.000),
    GeoNode(id: 5, lat: 0.000, lon: 0.030),
    GeoNode(id: 6, lat: 0.010, lon: 0.040),
    GeoNode(id: 7, lat: -0.010, lon: 0.040),
  ];
  GeoEdge road(int a, int b, double m, double kmh) => GeoEdge(
    sourceId: a,
    targetId: b,
    distanceMeters: m,
    speedKmh: kmh,
    oneWay: true,
  );
  final edges = <GeoEdge>[
    road(1, 2, 500, 10), // slow arm out
    road(2, 5, 500, 10), // slow arm in: 1000 m at 10 km/h = 360 s
    road(1, 3, 1500, 120), // fast arm out
    road(3, 5, 1500, 120), // fast arm in: 3000 m at 120 km/h = 90 s
    road(5, 6, 100, 50),
    road(5, 7, 100, 50),
  ];
  final restriction = const GeoTurnRestriction(
    fromNodeId: 3,
    viaNodeId: 5,
    toNodeId: 7,
    isOnly: false,
  );
  final geo = GeoGraph(
    nodes: nodes,
    edges: edges,
    turnRestrictions: [restriction],
  );

  final storage = _Mem()..store['g_car'] = geo;
  final router = DijkstraRouter(storage: storage, graphId: 'g');
  final route = await router.findRoute(
    const GeoCoordinate(lat: 0.0, lon: 0.0),
    const GeoCoordinate(lat: 0.0, lon: 0.03),
  );
  print(
    'chosen route: ${route.distanceMeters.toStringAsFixed(0)} m, '
    '${route.duration.inSeconds} s',
  );
  print(
    'the fast arm is 3000 m / 90 s; the slow arm is 1000 m / 360 s. '
    'A "fastest route" should be 90 s.',
  );
}

/// PROBE 5: an `only_*` whose `to` is not an exit of the junction.
Future<void> probe5() async {
  print('');
  print('--- PROBE 5: only_* naming a `to` that is not an exit ---');
  final nodes = <GeoNode>[
    GeoNode(id: 1, lat: 0.000, lon: 0.000),
    GeoNode(id: 2, lat: 0.010, lon: 0.000),
    GeoNode(id: 3, lat: 0.020, lon: 0.000),
    GeoNode(id: 4, lat: 0.010, lon: 0.010),
    GeoNode(id: 9, lat: 0.050, lon: 0.050),
    GeoNode(id: 8, lat: 0.050, lon: 0.060),
  ];
  GeoEdge road(int a, int b) =>
      GeoEdge(sourceId: a, targetId: b, distanceMeters: 500, speedKmh: 50);
  final geo = GeoGraph(
    nodes: nodes,
    edges: [road(1, 2), road(2, 3), road(2, 4), road(9, 8)],
    // "only_straight_on from 1 via 2 to 9" - 9 is nowhere near junction 2.
    turnRestrictions: const [
      GeoTurnRestriction(
        fromNodeId: 1,
        viaNodeId: 2,
        toNodeId: 9,
        isOnly: true,
      ),
    ],
  );
  final built = const GraphBuilder().build(geo);
  final split = const TurnRestrictionSplitter().split(
    built,
    geo.turnRestrictions,
  );
  print('built $built -> split $split');
  print(
    'splitParent present? ${split.splitParent != null}; '
    'copies added? ${split.nodeCount - built.nodeCount}',
  );
  print(
    'An only_* whose `to` is unreachable should ban every other exit '
    '(or be reported). It is silently ignored instead.',
  );
}

class _Mem implements GeoStorage {
  final store = <String, GeoGraph>{};
  @override
  Future<void> saveGraph(
    String id,
    GeoGraph graph, {
    VehicleProfile profile = VehicleProfile.car,
  }) async => store['${id}_${profile.name}'] = graph;
  @override
  Future<GeoGraph?> loadGraph(
    String id, {
    VehicleProfile profile = VehicleProfile.car,
  }) async => store['${id}_${profile.name}'];
  @override
  Future<bool> exists(
    String id, {
    VehicleProfile profile = VehicleProfile.car,
  }) async => store.containsKey('${id}_${profile.name}');
  @override
  Future<void> delete(
    String id, {
    VehicleProfile profile = VehicleProfile.car,
  }) async => store.remove('${id}_${profile.name}');
}

Future<void> main() async {
  probe3();
  await probe4();
  await probe5();
}
