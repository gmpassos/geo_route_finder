import 'mirror_benchmark.dart';
import 'osm_download_source.dart';
import 'sources/bbbike_source.dart';
import 'sources/geofabrik_source.dart';
import 'sources/osm_france_source.dart';
import 'sources/planet_source.dart';

/// An ordered collection of [OsmDownloadSource]s that locates the best source —
/// and the best mirror — for a requested region.
///
/// The registry is the [OsmSourceResolver] that [OsmDownloader] consumes, so the
/// downloader never sees provider-specific logic. It:
///
/// * tries sources in priority (registration) order,
/// * returns the first enabled source capable of serving a region,
/// * accepts custom sources via [register],
/// * supports enable/disable via [setEnabled],
/// * optionally benchmarks candidate mirrors and reorders them fastest-first,
///   caching probe results.
class OsmDownloadSourceRegistry implements OsmSourceResolver {
  final List<_SourceEntry> _entries = [];

  /// Whether [resolveCandidates] benchmarks mirrors unless told otherwise.
  final bool benchmarkByDefault;

  MirrorProber? _prober;
  MirrorBenchmark? _defaultBenchmark;

  final Map<Uri, MirrorProbe> _probeCache = {};

  /// Creates an empty registry. Provide a [prober] to customise (or fake)
  /// mirror benchmarking; otherwise a default [MirrorBenchmark] is created
  /// lazily the first time a benchmark is requested.
  OsmDownloadSourceRegistry({
    MirrorProber? prober,
    this.benchmarkByDefault = false,
  }) : _prober = prober;

  /// A registry preloaded with the built-in providers in sensible priority
  /// order: BBBike (cities) → Geofabrik (regions) → OSM France (mirror) →
  /// Planet (whole-planet, last resort).
  factory OsmDownloadSourceRegistry.withDefaults({
    MirrorProber? prober,
    bool benchmarkByDefault = false,
  }) {
    return OsmDownloadSourceRegistry(
        prober: prober,
        benchmarkByDefault: benchmarkByDefault,
      )
      ..register(BBBikeSource())
      ..register(GeofabrikSource())
      ..register(OsmFranceSource())
      ..register(PlanetSource());
  }

  /// All registered sources, highest priority first.
  Iterable<OsmDownloadSource> get sources => _entries.map((e) => e.source);

  /// Registers [source]. Registration order defines priority (earlier = higher).
  ///
  /// Pass [priority] to insert at a specific index (`0` = highest). Registering
  /// a source whose [OsmDownloadSource.id] already exists replaces it. Use
  /// [enabled] to register a source in a disabled state.
  void register(
    OsmDownloadSource source, {
    bool enabled = true,
    int? priority,
  }) {
    _entries.removeWhere((e) => e.source.id == source.id);
    final entry = _SourceEntry(source, enabled);
    if (priority == null || priority >= _entries.length) {
      _entries.add(entry);
    } else {
      _entries.insert(priority < 0 ? 0 : priority, entry);
    }
  }

  /// Removes the source with [id], if present. Returns whether one was removed.
  bool unregister(String id) {
    final before = _entries.length;
    _entries.removeWhere((e) => e.source.id == id);
    return _entries.length != before;
  }

  /// Enables or disables the source with [id]. Disabled sources are skipped by
  /// [resolveSource], [sourcesFor] and [resolveCandidates].
  void setEnabled(String id, bool enabled) {
    for (final e in _entries) {
      if (e.source.id == id) e.enabled = enabled;
    }
  }

  /// Whether the source with [id] is registered and enabled.
  bool isEnabled(String id) =>
      _entries.any((e) => e.source.id == id && e.enabled);

  /// The first enabled source that can serve [region], or `null` if none can.
  OsmDownloadSource? resolveSource(String region) {
    for (final e in _entries) {
      if (e.enabled && e.source.supportsRegion(region)) return e.source;
    }
    return null;
  }

  /// All enabled sources that can serve [region], in priority order.
  Iterable<OsmDownloadSource> sourcesFor(String region) => _entries
      .where((e) => e.enabled && e.source.supportsRegion(region))
      .map((e) => e.source);

  @override
  Future<List<OsmDownloadCandidate>> resolveCandidates(
    String region, {
    bool? benchmark,
  }) async {
    final candidates = <OsmDownloadCandidate>[];
    for (final e in _entries) {
      if (!e.enabled || !e.source.supportsRegion(region)) continue;
      for (final uri in await _urisFor(e.source, region)) {
        candidates.add(OsmDownloadCandidate(sourceId: e.source.id, uri: uri));
      }
    }

    final doBenchmark = benchmark ?? benchmarkByDefault;
    if (doBenchmark && candidates.length > 1) {
      return _rankByBenchmark(candidates);
    }
    return candidates;
  }

  /// Clears cached mirror [MirrorProbe] results, forcing re-benchmarking.
  void clearBenchmarkCache() => _probeCache.clear();

  /// The cached probe for [uri], if one is present and unexpired.
  MirrorProbe? cachedProbe(Uri uri) {
    final p = _probeCache[uri];
    return (p != null && !p.isExpired) ? p : null;
  }

  Future<List<Uri>> _urisFor(OsmDownloadSource source, String region) async {
    if (source is OsmMirroredSource) return source.resolveMirrors(region);
    final uri = await source.resolveRegion(region);
    return uri == null ? const [] : [uri];
  }

  Future<List<OsmDownloadCandidate>> _rankByBenchmark(
    List<OsmDownloadCandidate> candidates,
  ) async {
    // Decorate with original index so ties fall back to priority order
    // (List.sort is not guaranteed stable).
    final scored = <(int, OsmDownloadCandidate, MirrorProbe)>[];
    for (var i = 0; i < candidates.length; i++) {
      final c = candidates[i];
      scored.add((i, c, await _probe(c.uri)));
    }
    scored.sort((a, b) {
      final byProbe = _compareProbes(a.$3, b.$3);
      return byProbe != 0 ? byProbe : a.$1.compareTo(b.$1);
    });
    return [for (final s in scored) s.$2];
  }

  Future<MirrorProbe> _probe(Uri uri) async {
    final cached = _probeCache[uri];
    if (cached != null && !cached.isExpired) return cached;
    final probe = await _effectiveProber(uri);
    _probeCache[uri] = probe;
    return probe;
  }

  MirrorProber get _effectiveProber {
    final existing = _prober;
    if (existing != null) return existing;
    final benchmark = _defaultBenchmark ??= MirrorBenchmark();
    return _prober = benchmark.probe;
  }

  /// Orders probes best-first: available before unavailable, then higher
  /// throughput, then lower latency.
  static int _compareProbes(MirrorProbe a, MirrorProbe b) {
    if (a.available != b.available) return a.available ? -1 : 1;
    if (a.throughputBytesPerSecond != b.throughputBytesPerSecond) {
      return b.throughputBytesPerSecond.compareTo(a.throughputBytesPerSecond);
    }
    return a.latency.compareTo(b.latency);
  }
}

class _SourceEntry {
  final OsmDownloadSource source;
  bool enabled;

  _SourceEntry(this.source, this.enabled);
}
