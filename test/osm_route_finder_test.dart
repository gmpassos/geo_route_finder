@Tags(['slow'])
library;

import 'dart:io';

import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

import 'support.dart';

/// End-to-end integration test exercising the full OpenStreetMap pipeline
/// against **real** data, with nothing mocked:
///
///   [OsmDownloader] -> [OsmConverter] -> [OsmDataSource] -> [AStarRouter]
///
/// It downloads the South Brazil (`sul`) Geofabrik extract — which covers
/// Santa Catarina, and therefore Florianópolis — converts it into the
/// engine's internal [GeoGraph], loads it through the OSM data source, and
/// routes between two real shopping malls in Florianópolis.
///
/// The extract is large (~400 MB), so the download dominates the runtime on a
/// cold cache. [OsmDownloader] caches (ETag/Last-Modified) and resumes partial
/// downloads, so repeated runs reuse the local file. The cache lives in a
/// stable temp directory so it survives between runs.
void main() {
  final localDownloadCacheDirectory = Directory(
    '/tmp/test-geo-route-finder-osm-cache',
  );

  // Florianópolis, Santa Catarina, Brazil.
  const beiramarShopping = GeoCoordinate(lat: -27.5848902, lon: -48.5476098);
  const villaRomanaShopping = GeoCoordinate(lat: -27.5901143, lon: -48.5176072);

  // Geofabrik region covering Santa Catarina (South Brazil).
  const region = 'south-america/brazil/sul';
  const graphId = 'florianopolis';

  // How close the snapped route endpoints must be to the requested
  // coordinates. The malls sit a little off the road network, so the nearest
  // routable node can be a couple hundred metres away; 1 km is a safe bound.
  const endpointToleranceMeters = 1000.0;

  group('OSM end-to-end routing (real data)', () {
    test(
      'downloads, converts, loads and routes Beiramar -> Villa Romana',
      () async {
        // 1. Download all OSM data covering the route area.
        final downloader = OsmDownloader(
          outputDirectory: localDownloadCacheDirectory,
        );
        String pbfPath;
        var lastReportedMb = -1;
        try {
          pbfPath = await downloader.downloadRegion(
            region: region,
            onProgress: (received, total) {
              final mb = received ~/ (1024 * 1024);
              // Throttle progress output to once per ~16 MB.
              if (mb >= lastReportedMb + 16) {
                lastReportedMb = mb;
                final totalMb = total != null
                    ? '/${total ~/ (1024 * 1024)} MB'
                    : '';
                stdout.write('\rDownloading $region: $mb MB$totalMb   ');
              }
            },
          );
          stdout.writeln();
        } finally {
          downloader.close();
        }

        expect(
          File(pbfPath).existsSync(),
          isTrue,
          reason: 'downloaded extract should exist on disk',
        );

        // 2. Convert the OSM extract into the package's internal format, and
        // 3. load it through the OSM data source. OsmDataSource performs the
        //    conversion via the OsmConverter it is given.
        final converter = OsmConverter();
        final dataSource = OsmDataSource(
          pbfFile: pbfPath,
          converter: converter,
        );
        final graph = await dataSource.loadGraph();

        expect(
          graph.nodes,
          isNotEmpty,
          reason: 'converted graph should contain road nodes',
        );
        expect(
          graph.edges,
          isNotEmpty,
          reason: 'converted graph should contain road edges',
        );

        // Make the loaded graph routable by storing it under a graph id.
        final storage = MemoryStorage();
        await storage.saveGraph(graphId, graph);

        // 4. Create a route finder instance.
        final router = AStarRouter(storage: storage, graphId: graphId);

        // 5. Calculate the shortest drivable route.
        final route = await router.findRoute(
          beiramarShopping,
          villaRomanaShopping,
        );

        // 6. Verify the result.
        expect(route.found, isTrue, reason: 'a valid route should be found');
        expect(
          route.geometry.length,
          greaterThanOrEqualTo(2),
          reason: 'route should contain at least two nodes',
        );
        expect(
          route.distanceMeters,
          greaterThan(0),
          reason: 'total distance should be greater than zero',
        );

        final routeStart = route.geometry.first;
        final routeEnd = route.geometry.last;
        expect(
          routeStart.distanceTo(beiramarShopping),
          lessThan(endpointToleranceMeters),
          reason: 'route should start near Beiramar Shopping',
        );
        expect(
          routeEnd.distanceTo(villaRomanaShopping),
          lessThan(endpointToleranceMeters),
          reason: 'route should end near Villa Romana Shopping',
        );

        // 7. Debug output.
        stdout.writeln(
          'Route distance: '
          '${(route.distanceMeters / 1000).toStringAsFixed(2)} km',
        );
        stdout.writeln('Estimated travel time: ${route.duration}');
        stdout.writeln('Route points: ${route.geometry.length}');
      },
      // The cold-cache download of a ~400 MB extract plus a full parse needs a
      // generous timeout.
      timeout: const Timeout(Duration(minutes: 30)),
    );
  });
}
