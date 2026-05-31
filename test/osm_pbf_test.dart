import 'dart:io';

import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  for (final compress in [false, true]) {
    group('OsmPbfParser (${compress ? 'zlib' : 'raw'})', () {
      late File file;

      setUp(() {
        file = File(
          writeTempPbf(
            buildWayPbf(
              tags: const {'highway': 'residential', 'oneway': 'yes'},
              compress: compress,
            ),
          ),
        );
      });

      tearDown(() => file.parent.deleteSync(recursive: true));

      test('decodes nodes with correct coordinates', () async {
        final nodes = <GeoNode>[];
        await const OsmPbfParser().parse(file.path, onNode: nodes.add);
        expect(nodes.length, 3);
        expect(nodes[0].id, 1);
        expect(nodes[0].lat, closeTo(-23.5, 1e-7));
        expect(nodes[0].lon, closeTo(-46.7, 1e-7));
        expect(nodes[2].lon, closeTo(-46.69, 1e-7));
      });

      test('decodes ways with tags and refs', () async {
        final ways = <GeoWay>[];
        await const OsmPbfParser().parse(file.path, onWay: ways.add);
        expect(ways.length, 1);
        expect(ways[0].id, 10);
        expect(ways[0].nodeIds, [1, 2, 3]);
        expect(ways[0].tags['highway'], 'residential');
        expect(ways[0].tags['oneway'], 'yes');
      });

      test('OsmConverter builds a routable graph', () async {
        final geo = await OsmConverter().toGeoGraph(file.path);
        expect(geo.nodes.length, 3);
        // 2 segments, one-way -> 2 directed edges.
        expect(geo.edges.length, 2);
        expect(geo.edges.every((e) => e.oneWay), isTrue);
        expect(
          geo.edges.first.speedKmh,
          OsmConverter.defaultSpeedKmh['residential'],
        );
      });
    });
  }
}
