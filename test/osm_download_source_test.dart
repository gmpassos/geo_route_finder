import 'dart:io';

import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

/// A throwaway in-memory source used to exercise registry behavior (priority,
/// custom registration, fallback) without touching the network.
class _FakeSource implements OsmDownloadSource {
  @override
  final String id;
  final Set<String> regions;
  final Map<String, Uri> urls;

  _FakeSource(this.id, {this.regions = const {}, this.urls = const {}});

  @override
  bool supportsRegion(String region) =>
      regions.contains(region) || urls.containsKey(region);

  @override
  Future<Uri?> resolveRegion(String region) async => urls[region];
}

void main() {
  group('Provider region resolution', () {
    test('Geofabrik supports the continent hierarchy', () {
      final geofabrik = GeofabrikSource();
      expect(
        geofabrik.supportsRegion('south-america/brazil/santa-catarina'),
        isTrue,
      );
      expect(geofabrik.supportsRegion('south-america/brazil'), isTrue);
      expect(geofabrik.supportsRegion('north-america/us/california'), isTrue);
      expect(geofabrik.supportsRegion('europe/germany'), isTrue);
      // Not a continent prefix.
      expect(geofabrik.supportsRegion('planet'), isFalse);
      expect(geofabrik.supportsRegion('bbbike/Berlin'), isFalse);
      expect(geofabrik.supportsRegion(''), isFalse);
    });

    test('Geofabrik builds <region>-latest.osm.pbf URLs', () async {
      final uri = await GeofabrikSource().resolveRegion(
        'south-america/brazil/santa-catarina',
      );
      expect(
        uri.toString(),
        'https://download.geofabrik.de/'
        'south-america/brazil/santa-catarina-latest.osm.pbf',
      );
    });

    test('Geofabrik returns null for unsupported regions', () async {
      expect(await GeofabrikSource().resolveRegion('planet'), isNull);
    });

    test(
      'OSM France shares the hierarchy with a distinct URL scheme',
      () async {
        final france = OsmFranceSource();
        expect(france.supportsRegion('europe/germany'), isTrue);
        final uri = await france.resolveRegion('europe/germany');
        expect(
          uri.toString(),
          'https://download.openstreetmap.fr/extracts/europe/germany.osm.pbf',
        );
      },
    );

    test('BBBike resolves prefixed city regions only', () async {
      final bbbike = BBBikeSource();
      expect(bbbike.supportsRegion('bbbike/Berlin'), isTrue);
      expect(bbbike.supportsRegion('bbbike/'), isFalse);
      expect(bbbike.supportsRegion('bbbike/Berlin/extra'), isFalse);
      expect(bbbike.supportsRegion('europe/germany'), isFalse);
      final uri = await bbbike.resolveRegion('bbbike/Berlin');
      expect(
        uri.toString(),
        'https://download.bbbike.org/osm/bbbike/Berlin/Berlin.osm.pbf',
      );
    });

    test('Planet resolves only the whole-planet region', () async {
      final planet = PlanetSource();
      expect(planet.supportsRegion('planet'), isTrue);
      expect(planet.supportsRegion('europe/germany'), isFalse);
      final uri = await planet.resolveRegion('planet');
      expect(
        uri.toString(),
        'https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf',
      );
    });
  });

  group('Registry: source selection & priority', () {
    test('resolveSource picks the first supporting provider by priority', () {
      final registry = OsmDownloadSourceRegistry.withDefaults();
      // Geofabrik is registered before OSM France, so it wins for regions both
      // support.
      expect(
        registry.resolveSource('south-america/brazil/santa-catarina')?.id,
        'geofabrik',
      );
      expect(registry.resolveSource('bbbike/Berlin')?.id, 'bbbike');
      expect(registry.resolveSource('planet')?.id, 'planet');
    });

    test('sourcesFor lists every supporting provider in priority order', () {
      final registry = OsmDownloadSourceRegistry.withDefaults();
      expect(registry.sourcesFor('europe/germany').map((s) => s.id), [
        'geofabrik',
        'osm_france',
      ]);
    });

    test('unsupported regions resolve to nothing', () async {
      final registry = OsmDownloadSourceRegistry.withDefaults();
      expect(registry.resolveSource('mars/olympus-mons'), isNull);
      expect(await registry.resolveCandidates('mars/olympus-mons'), isEmpty);
    });

    test('custom providers can be registered at a chosen priority', () {
      final registry = OsmDownloadSourceRegistry.withDefaults();
      final custom = _FakeSource(
        'enterprise',
        urls: {
          'europe/germany': Uri.parse('https://maps.corp.example/de.osm.pbf'),
        },
      );
      registry.register(custom, priority: 0);
      expect(registry.resolveSource('europe/germany')?.id, 'enterprise');
      expect(registry.sourcesFor('europe/germany').map((s) => s.id), [
        'enterprise',
        'geofabrik',
        'osm_france',
      ]);
    });

    test('registering a duplicate id replaces the previous source', () {
      final registry = OsmDownloadSourceRegistry();
      registry.register(_FakeSource('x', regions: {'a'}));
      registry.register(_FakeSource('x', regions: {'b'}));
      expect(registry.sources.length, 1);
      expect(registry.resolveSource('a'), isNull);
      expect(registry.resolveSource('b')?.id, 'x');
    });

    test('providers can be disabled and re-enabled', () {
      final registry = OsmDownloadSourceRegistry.withDefaults();
      registry.setEnabled('geofabrik', false);
      // With Geofabrik disabled, OSM France becomes the primary for the region.
      expect(registry.resolveSource('europe/germany')?.id, 'osm_france');
      expect(registry.isEnabled('geofabrik'), isFalse);

      registry.setEnabled('geofabrik', true);
      expect(registry.resolveSource('europe/germany')?.id, 'geofabrik');
    });

    test(
      'resolveCandidates enumerates mirrors across providers in order',
      () async {
        final registry = OsmDownloadSourceRegistry.withDefaults();
        final candidates = await registry.resolveCandidates('europe/germany');
        expect(candidates.map((c) => c.sourceId), ['geofabrik', 'osm_france']);
        expect(
          candidates.first.uri.toString(),
          'https://download.geofabrik.de/europe/germany-latest.osm.pbf',
        );
      },
    );
  });

  group('Registry: mirror benchmarking', () {
    // A deterministic prober: latency/throughput keyed by URL, and a call
    // counter to assert caching.
    test('reorders candidates fastest-first and caches probes', () async {
      final probeCounts = <Uri, int>{};
      final fast = Uri.parse('https://fast.example/de.osm.pbf');
      final slow = Uri.parse('https://slow.example/de.osm.pbf');

      Future<MirrorProbe> prober(Uri uri) async {
        probeCounts.update(uri, (n) => n + 1, ifAbsent: () => 1);
        final throughput = uri == fast ? 10e6 : 1e6;
        return MirrorProbe(
          uri: uri,
          available: true,
          latency: const Duration(milliseconds: 20),
          throughputBytesPerSecond: throughput,
        );
      }

      final registry = OsmDownloadSourceRegistry(prober: prober)
        // Register the SLOW mirror at higher priority to prove benchmarking
        // overrides registration order.
        ..register(_FakeSource('slow-first', urls: {'de': slow}))
        ..register(_FakeSource('fast-second', urls: {'de': fast}));

      final ranked = await registry.resolveCandidates('de', benchmark: true);
      expect(ranked.map((c) => c.uri), [fast, slow]);

      // Without benchmarking, original priority order is preserved.
      final unranked = await registry.resolveCandidates('de');
      expect(unranked.map((c) => c.uri), [slow, fast]);

      // Probes are cached: a second benchmark does not re-probe.
      await registry.resolveCandidates('de', benchmark: true);
      expect(probeCounts[fast], 1);
      expect(probeCounts[slow], 1);

      // Clearing the cache forces a re-probe.
      registry.clearBenchmarkCache();
      await registry.resolveCandidates('de', benchmark: true);
      expect(probeCounts[fast], 2);
    });

    test('unavailable mirrors rank last', () async {
      final up = Uri.parse('https://up.example/x.pbf');
      final down = Uri.parse('https://down.example/x.pbf');

      Future<MirrorProbe> prober(Uri uri) async => uri == up
          ? MirrorProbe(
              uri: uri,
              available: true,
              throughputBytesPerSecond: 1e6,
            )
          : MirrorProbe.unavailable(uri);

      final registry = OsmDownloadSourceRegistry(prober: prober)
        ..register(_FakeSource('down', urls: {'r': down}))
        ..register(_FakeSource('up', urls: {'r': up}));

      final ranked = await registry.resolveCandidates('r', benchmark: true);
      expect(ranked.first.uri, up);
      expect(ranked.last.uri, down);
    });
  });

  group('Downloader: automatic selection & fallback', () {
    late HttpServer server;
    late Directory outDir;
    late String host;
    final body = List<int>.generate(2048, (i) => i % 256);

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      host = '127.0.0.1:${server.port}';
      outDir = await Directory.systemTemp.createTemp('osm-dl-test');
      // Route by path: anything under /good/ serves the body; under /bad/ a 500.
      server.listen((req) async {
        final isHead = req.method == 'HEAD';
        if (req.uri.path.contains('/bad/')) {
          req.response.statusCode = HttpStatus.internalServerError;
        } else if (req.uri.path.contains('/good/')) {
          req.response
            ..statusCode = HttpStatus.ok
            ..contentLength = body.length;
          // A HEAD response carries headers only, never a body.
          if (!isHead) req.response.add(body);
        } else {
          req.response.statusCode = HttpStatus.notFound;
        }
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (outDir.existsSync()) await outDir.delete(recursive: true);
    });

    test('downloads from the resolved source automatically', () async {
      // A Geofabrik-shaped source pointing at our local "good" mirror.
      final registry = OsmDownloadSourceRegistry()
        ..register(GeofabrikSource(baseUrls: ['http://$host/good/']));
      final downloader = OsmDownloader(
        sourceResolver: registry,
        outputDirectory: outDir,
      );
      addTearDown(downloader.close);

      final path = await downloader.downloadRegion(region: 'europe/test');
      expect(File(path).existsSync(), isTrue);
      expect(await File(path).readAsBytes(), body);
    });

    test('falls back to the next mirror when the first fails', () async {
      // First mirror returns 500, second succeeds — same provider, two mirrors.
      final registry = OsmDownloadSourceRegistry()
        ..register(
          GeofabrikSource(
            baseUrls: ['http://$host/bad/', 'http://$host/good/'],
          ),
        );
      final downloader = OsmDownloader(
        sourceResolver: registry,
        outputDirectory: outDir,
      );
      addTearDown(downloader.close);

      final path = await downloader.downloadRegion(region: 'europe/test');
      expect(await File(path).readAsBytes(), body);
    });

    test('falls back across providers when one provider fails', () async {
      // Geofabrik (bad) is higher priority than OSM France (good).
      final registry = OsmDownloadSourceRegistry()
        ..register(GeofabrikSource(baseUrls: ['http://$host/bad/']))
        ..register(OsmFranceSource(baseUrls: ['http://$host/good/']));
      final downloader = OsmDownloader(
        sourceResolver: registry,
        outputDirectory: outDir,
      );
      addTearDown(downloader.close);

      final path = await downloader.downloadRegion(region: 'europe/test');
      expect(await File(path).readAsBytes(), body);
    });

    test('throws OsmSourceException for unsupported regions', () async {
      final downloader = OsmDownloader(
        sourceResolver: OsmDownloadSourceRegistry.withDefaults(),
        outputDirectory: outDir,
      );
      addTearDown(downloader.close);

      expect(
        () => downloader.downloadRegion(region: 'mars/olympus-mons'),
        throwsA(isA<OsmSourceException>()),
      );
    });

    test('throws OsmSourceException when every candidate fails', () async {
      final registry = OsmDownloadSourceRegistry()
        ..register(GeofabrikSource(baseUrls: ['http://$host/bad/']));
      final downloader = OsmDownloader(
        sourceResolver: registry,
        outputDirectory: outDir,
      );
      addTearDown(downloader.close);

      expect(
        () => downloader.downloadRegion(region: 'europe/test'),
        throwsA(isA<OsmSourceException>()),
      );
    });

    test('real MirrorBenchmark probes a live mirror', () async {
      final benchmark = MirrorBenchmark(sampleBytes: 1024);
      addTearDown(benchmark.close);

      final good = await benchmark.probe(Uri.parse('http://$host/good/x.pbf'));
      expect(good.available, isTrue);
      expect(good.contentLength, body.length);

      final bad = await benchmark.probe(Uri.parse('http://$host/bad/x.pbf'));
      expect(bad.available, isFalse);
    });
  });
}
