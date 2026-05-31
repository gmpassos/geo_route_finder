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

    test('tolls count and hasToll getter', () {
      const free = GeoEdge(
        sourceId: 0,
        targetId: 1,
        distanceMeters: 100,
        speedKmh: 50,
      );
      const tolled = GeoEdge(
        sourceId: 0,
        targetId: 1,
        distanceMeters: 100,
        speedKmh: 50,
        tolls: 2,
      );
      expect(free.hasToll, isFalse);
      expect(free.tolls, 0);
      expect(tolled.hasToll, isTrue);
      expect(tolled.tolls, 2);
    });
  });

  group('GeoRoute', () {
    GeoRoute route({required double km, required int tolls}) => GeoRoute(
      distanceMeters: km * 1000,
      duration: Duration.zero,
      geometry: const [GeoCoordinate(lat: 0, lon: 0)],
      tollCount: tolls,
    );

    test('none sentinel is not found', () {
      expect(GeoRoute.none.found, isFalse);
    });

    test('hasTolls reflects tollCount', () {
      expect(route(km: 5, tolls: 0).hasTolls, isFalse);
      expect(route(km: 5, tolls: 1).hasTolls, isTrue);
    });

    test('Comparable orders by tolls then distance', () {
      final routes = [
        route(km: 5, tolls: 2),
        route(km: 20, tolls: 0),
        route(km: 8, tolls: 0),
        route(km: 3, tolls: 1),
      ]..sort();
      // Fewest tolls first; ties broken by shorter distance.
      expect(routes.map((r) => r.tollCount), [0, 0, 1, 2]);
      expect(routes.first.distanceMeters, 8000); // 8 km beats 20 km at 0 tolls
      // A not-found route sorts last.
      final withNone = [route(km: 1, tolls: 3), GeoRoute.none]..sort();
      expect(withNone.first.found, isTrue);
    });
  });
}
