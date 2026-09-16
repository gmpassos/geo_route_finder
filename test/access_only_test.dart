import 'dart:typed_data';

import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

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
