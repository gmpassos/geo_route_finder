import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

void main() {
  group('GeoCoordinate', () {
    test('haversine matches a known distance', () {
      // São Paulo (Sé) to Rio de Janeiro (Centro) ~ 360 km.
      const sp = GeoCoordinate(lat: -23.5505, lon: -46.6333);
      const rio = GeoCoordinate(lat: -22.9068, lon: -43.1729);
      final d = sp.distanceTo(rio);
      expect(d, closeTo(360000, 5000));
    });

    test('distance to self is zero', () {
      const c = GeoCoordinate(lat: 10, lon: 20);
      expect(c.distanceTo(c), 0);
    });

    test('equality and hashCode', () {
      expect(
        const GeoCoordinate(lat: 1, lon: 2),
        const GeoCoordinate(lat: 1, lon: 2),
      );
      expect(
        const GeoCoordinate(lat: 1, lon: 2).hashCode,
        const GeoCoordinate(lat: 1, lon: 2).hashCode,
      );
    });
  });

  group('GeoEdge', () {
    test('travel time derives from distance and speed', () {
      const e = GeoEdge(
        sourceId: 0,
        targetId: 1,
        distanceMeters: 1000,
        speedKmh: 36, // 10 m/s
      );
      expect(e.travelTimeSeconds, closeTo(100, 1e-9));
    });

    test('zero speed yields infinite time', () {
      const e = GeoEdge(
        sourceId: 0,
        targetId: 1,
        distanceMeters: 1000,
        speedKmh: 0,
      );
      expect(e.travelTimeSeconds, double.infinity);
    });
  });

  group('GeoRoute', () {
    test('none sentinel is not found', () {
      expect(GeoRoute.none.found, isFalse);
    });
  });
}
