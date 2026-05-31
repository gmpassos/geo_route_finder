import 'dart:io';

import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Converts a single tagged way through [profile] and returns the resulting
/// generic graph. The way's three nodes form two segments.
Future<GeoGraph> _convert(
  Map<String, String> tags,
  VehicleProfile profile,
) async {
  final path = writeTempPbf(buildWayPbf(tags: tags));
  try {
    return await OsmConverter(profile: profile).toGeoGraph(path);
  } finally {
    File(path).parent.deleteSync(recursive: true);
  }
}

void main() {
  group('VehicleProfile routability', () {
    test('a motorway is routable for car but not for bicycle', () async {
      final tags = {'highway': 'motorway'};
      expect((await _convert(tags, VehicleProfile.car)).edges, isNotEmpty);
      expect((await _convert(tags, VehicleProfile.bicycle)).edges, isEmpty);
    });

    test('a cycleway is routable for bicycle but not for car', () async {
      final tags = {'highway': 'cycleway'};
      expect((await _convert(tags, VehicleProfile.bicycle)).edges, isNotEmpty);
      expect((await _convert(tags, VehicleProfile.car)).edges, isEmpty);
    });

    test('motorcycle shares the car network', () async {
      final tags = {'highway': 'motorway'};
      expect(
        (await _convert(tags, VehicleProfile.motorcycle)).edges,
        isNotEmpty,
      );
    });

    test('a bicycle-forbidden access tag blocks bicycle only', () async {
      final tags = {'highway': 'residential', 'bicycle': 'no'};
      expect((await _convert(tags, VehicleProfile.bicycle)).edges, isEmpty);
      // The car profile does not consult `bicycle`, so it stays routable.
      expect((await _convert(tags, VehicleProfile.car)).edges, isNotEmpty);
    });
  });

  group('VehicleProfile one-way handling', () {
    test('car honors oneway; bicycle ignores it', () async {
      final tags = {'highway': 'residential', 'oneway': 'yes'};
      // The car keeps the segments one-way; the bicycle makes them traversable
      // both ways (the GraphBuilder later materialises the reverse direction).
      final car = await _convert(tags, VehicleProfile.car);
      expect(car.edges.every((e) => e.oneWay), isTrue);
      final bike = await _convert(tags, VehicleProfile.bicycle);
      expect(bike.edges.every((e) => !e.oneWay), isTrue);
    });

    test('oneway:bicycle is honored even by the bicycle profile', () async {
      final tags = {
        'highway': 'residential',
        'oneway': 'no',
        'oneway:bicycle': 'yes',
      };
      final geo = await _convert(tags, VehicleProfile.bicycle);
      expect(geo.edges.length, 2);
      expect(geo.edges.every((e) => e.oneWay), isTrue);
    });
  });

  group('VehicleProfile speed', () {
    test('bicycle ignores the posted maxspeed and caps speed', () async {
      final geo = await _convert({
        'highway': 'residential',
        'maxspeed': '120',
      }, VehicleProfile.bicycle);
      expect(geo.edges.first.speedKmh, lessThanOrEqualTo(25));
    });

    test('car reads the posted maxspeed', () async {
      final geo = await _convert({
        'highway': 'residential',
        'maxspeed': '30',
      }, VehicleProfile.car);
      expect(geo.edges.first.speedKmh, closeTo(30, 1e-9));
    });
  });

  group('toll tagging', () {
    test('toll=yes flags the converted edges', () async {
      final geo = await _convert({
        'highway': 'motorway',
        'toll': 'yes',
      }, VehicleProfile.car);
      expect(geo.edges, isNotEmpty);
      expect(geo.edges.every((e) => e.hasToll), isTrue);
    });

    test('untolled ways are not flagged', () async {
      final geo = await _convert({'highway': 'motorway'}, VehicleProfile.car);
      expect(geo.edges.every((e) => !e.hasToll), isTrue);
    });
  });
}
