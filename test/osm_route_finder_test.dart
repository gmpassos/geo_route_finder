@Tags(['slow'])
library;

import 'dart:io';

import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Formats a [Duration] as a compact, human-readable string, e.g. `4.20s` or
/// `2m 03.5s` for longer phases.
String _fmtDuration(Duration d) {
  final totalSeconds = d.inMilliseconds / 1000.0;
  if (totalSeconds < 60) return '${totalSeconds.toStringAsFixed(2)}s';
  final minutes = d.inMinutes;
  final seconds = totalSeconds - minutes * 60;
  return '${minutes}m ${seconds.toStringAsFixed(1)}s';
}

/// Average throughput in MB/s over [bytes] transferred in [elapsed], or `n/a`
/// when the elapsed time is too small to be meaningful (e.g. a warm cache).
String _fmtThroughput(int bytes, Duration elapsed) {
  final seconds = elapsed.inMilliseconds / 1000.0;
  if (seconds < 0.05) return 'n/a';
  final mbPerSec = (bytes / (1024 * 1024)) / seconds;
  return '${mbPerSec.toStringAsFixed(1)} MB/s';
}

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
        final totalStopwatch = Stopwatch()..start();
        stdout.writeln('=== OSM end-to-end pipeline ===');
        stdout.writeln('Region: $region');
        stdout.writeln('Cache:  ${localDownloadCacheDirectory.path}');

        // 1. Download all OSM data covering the route area.
        stdout.writeln('\n[1/6] Downloading extract...');
        final downloader = OsmDownloader(
          outputDirectory: localDownloadCacheDirectory,
        );
        String pbfPath;
        var lastReportedMb = -1;
        final downloadStopwatch = Stopwatch()..start();
        try {
          pbfPath = await downloader.downloadRegion(
            region: region,
            onProgress: (received, total, url) {
              final mb = received ~/ (1024 * 1024);
              // Throttle progress output to once per ~16 MB.
              if (mb >= lastReportedMb + 16) {
                lastReportedMb = mb;
                final totalMb = total != null
                    ? '/${total ~/ (1024 * 1024)} MB'
                    : '';
                final speed = _fmtThroughput(
                  received,
                  downloadStopwatch.elapsed,
                );
                stdout.write('\r  $url: $mb MB$totalMb ($speed)   ');
              }
            },
          );
          stdout.writeln();
        } finally {
          downloader.close();
        }
        downloadStopwatch.stop();

        expect(
          File(pbfPath).existsSync(),
          isTrue,
          reason: 'downloaded extract should exist on disk',
        );

        final pbfBytes = File(pbfPath).lengthSync();
        stdout.writeln(
          '  Downloaded ${(pbfBytes / (1024 * 1024)).toStringAsFixed(1)} MB '
          'in ${_fmtDuration(downloadStopwatch.elapsed)} '
          '(avg ${_fmtThroughput(pbfBytes, downloadStopwatch.elapsed)})',
        );
        stdout.writeln('  File: $pbfPath');

        // 2. Convert the OSM extract into the package's internal format, and
        // 3. load it through the OSM data source. OsmDataSource performs the
        //    conversion via the OsmConverter it is given.
        stdout.writeln('\n[2/6] Converting PBF to routing graph...');
        final converter = OsmConverter();
        final dataSource = OsmDataSource(
          pbfFile: pbfPath,
          converter: converter,
        );
        final conversionStopwatch = Stopwatch()..start();
        final graph = await dataSource.loadGraph();
        conversionStopwatch.stop();

        stdout.writeln(
          '  Converted in ${_fmtDuration(conversionStopwatch.elapsed)}: '
          '${graph.nodes.length} nodes, ${graph.edges.length} edges',
        );

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
        stdout.writeln('\n[3/6] Storing graph as "$graphId"...');
        final storage = MemoryStorage();
        final storeStopwatch = Stopwatch()..start();
        await storage.saveGraph(graphId, graph);
        storeStopwatch.stop();
        stdout.writeln('  Stored in ${_fmtDuration(storeStopwatch.elapsed)}');

        // 4. Create a route finder instance and load its graph up front, so the
        // load cost is measured separately from the routing query.
        stdout.writeln('\n[4/6] Loading routing graph...');
        final router = AStarRouter(storage: storage, graphId: graphId);

        final loadStopwatch = Stopwatch()..start();
        await router.ensureLoaded();
        loadStopwatch.stop();
        stdout.writeln('  Loaded in ${_fmtDuration(loadStopwatch.elapsed)}');

        // 5. Calculate the shortest drivable route.
        stdout.writeln('\n[5/6] Routing Beiramar -> Villa Romana...');
        final routeStopwatch = Stopwatch()..start();
        final route = await router.findRoute(
          beiramarShopping,
          villaRomanaShopping,
        );
        routeStopwatch.stop();
        stdout.writeln('  Routed in ${_fmtDuration(routeStopwatch.elapsed)}');

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
        totalStopwatch.stop();
        stdout.writeln('\n[6/6] Result:');
        stdout.writeln(
          '  Route distance: '
          '${(route.distanceMeters / 1000).toStringAsFixed(2)} km',
        );
        stdout.writeln('  Estimated travel time: ${route.duration}');
        stdout.writeln('  Route points: ${route.geometry.length}');

        stdout.writeln('\n=== Timing summary ===');
        stdout.writeln(
          '  Download:   ${_fmtDuration(downloadStopwatch.elapsed)}',
        );
        stdout.writeln(
          '  Conversion: ${_fmtDuration(conversionStopwatch.elapsed)}',
        );
        stdout.writeln('  Storage:    ${_fmtDuration(storeStopwatch.elapsed)}');
        stdout.writeln('  Load:       ${_fmtDuration(loadStopwatch.elapsed)}');
        stdout.writeln('  Routing:    ${_fmtDuration(routeStopwatch.elapsed)}');
        stdout.writeln('  Total:      ${_fmtDuration(totalStopwatch.elapsed)}');
      },
      // The cold-cache download of a ~400 MB extract plus a full parse needs a
      // generous timeout.
      timeout: const Timeout(Duration(minutes: 30)),
    );
  });
}
