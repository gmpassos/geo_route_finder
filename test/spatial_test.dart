import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('KdTree', () {
    final graph = const GraphBuilder().build(buildGrid(n: 12));
    final tree = KdTree.build(graph);

    test('finds the exact nearest vertex (brute-force agreement)', () {
      // Probe many random-ish points and compare with a linear scan.
      for (var i = 0; i < 50; i++) {
        final lat = -23.5 + (i % 12) * 0.0103 + 0.0001 * i;
        final lon = -46.7 + (i % 7) * 0.0099 - 0.0002 * i;
        final kd = tree.findNearest(lat, lon);
        var bestDist = double.infinity;
        for (var v = 0; v < graph.nodeCount; v++) {
          final d = haversineMeters(lat, lon, graph.lat[v], graph.lon[v]);
          if (d < bestDist) bestDist = d;
        }
        // The KD-tree must return a vertex at the true minimum distance.
        expect(kd.distanceMeters, closeTo(bestDist, 1e-6));
      }
    });

    test('radius query returns exactly the in-range vertices', () {
      const lat = -23.5;
      const lon = -46.7;
      const radius = 1500.0;
      final within = tree.findWithinRadius(lat, lon, radius);
      var expected = 0;
      for (var v = 0; v < graph.nodeCount; v++) {
        if (haversineMeters(lat, lon, graph.lat[v], graph.lon[v]) <= radius) {
          expected++;
        }
      }
      // Projected metric is within a fraction of a percent; allow a small
      // boundary tolerance.
      expect((within.length - expected).abs(), lessThanOrEqualTo(2));
      // Results are sorted nearest-first.
      for (var i = 1; i < within.length; i++) {
        expect(
          within[i].distanceMeters,
          greaterThanOrEqualTo(within[i - 1].distanceMeters),
        );
      }
    });

    test('empty graph yields no result', () {
      final empty = const GraphBuilder().build(GeoGraph.empty);
      final t = KdTree.build(empty);
      expect(t.findNearest(0, 0).found, isFalse);
    });
  });

  group('NearestNodeSearch', () {
    test('respects maxSnapMeters', () {
      final graph = const GraphBuilder().build(buildGrid(n: 5));
      final search = NearestNodeSearch.build(graph);
      // A point far away from the grid.
      const far = GeoCoordinate(lat: 0, lon: 0);
      expect(search.snap(far, maxSnapMeters: 100).found, isFalse);
      expect(search.snap(far).found, isTrue);
    });
  });
}
