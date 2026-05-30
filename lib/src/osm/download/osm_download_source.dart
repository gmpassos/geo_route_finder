/// Pluggable OSM download-source abstraction.
///
/// This layer is responsible for one thing only: turning a *region identifier*
/// (e.g. `south-america/brazil/santa-catarina`) into a concrete, downloadable
/// extract URL. It knows nothing about how the bytes are fetched, parsed or
/// routed — that keeps [OsmDownloader] completely source-agnostic.
///
/// A source can resolve to any [Uri] scheme, so future providers may serve:
///
/// * `.osm.pbf` extracts (the common case),
/// * compressed `.osm.bz2` dumps,
/// * custom extracts behind bespoke path schemes,
/// * cloud-storage buckets (`gs://`, `s3://`, …),
/// * local mirrors (`file://`),
/// * enterprise/private datasets,
///
/// without changing the downloader interface.
library;

/// The continents recognised by the Geofabrik-style hierarchical providers.
///
/// A region whose first path segment is one of these is treated as a candidate
/// for hierarchical mirrors such as Geofabrik and OSM France.
const Set<String> osmContinents = {
  'africa',
  'antarctica',
  'asia',
  'australia-oceania',
  'central-america',
  'europe',
  'north-america',
  'south-america',
  'russia',
};

/// A pluggable source that resolves an OSM *region identifier* into a
/// downloadable extract URL.
///
/// Implementations encapsulate all provider-specific URL generation and region
/// mapping. New providers and mirrors can be added simply by implementing this
/// interface and registering them in an [OsmDownloadSourceRegistry] — no
/// downloader code changes.
abstract interface class OsmDownloadSource {
  /// Stable, unique identifier for this source (e.g. `geofabrik`).
  String get id;

  /// Whether this source can serve [region].
  ///
  /// This is a cheap, synchronous predicate (typically a hierarchy/prefix
  /// check). Returning `true` does not guarantee the extract exists on the
  /// server — only that the source's naming scheme covers the region.
  bool supportsRegion(String region);

  /// Resolves [region] to a downloadable [Uri], or `null` when this source
  /// cannot serve the region.
  Future<Uri?> resolveRegion(String region);
}

/// An [OsmDownloadSource] that can expose several mirror URLs for the same
/// region, enabling the registry to benchmark and pick the fastest one.
abstract interface class OsmMirroredSource implements OsmDownloadSource {
  /// All candidate mirror URLs for [region], in the source's own preference
  /// order. Returns an empty list when the region is unsupported.
  Future<List<Uri>> resolveMirrors(String region);
}

/// A single resolved download option: the [uri] to try and the [sourceId] of
/// the provider that produced it.
class OsmDownloadCandidate {
  /// Identifier of the [OsmDownloadSource] that produced [uri].
  final String sourceId;

  /// The downloadable extract URL.
  final Uri uri;

  const OsmDownloadCandidate({required this.sourceId, required this.uri});

  @override
  bool operator ==(Object other) =>
      other is OsmDownloadCandidate &&
      other.sourceId == sourceId &&
      other.uri == uri;

  @override
  int get hashCode => Object.hash(sourceId, uri);

  @override
  String toString() => 'OsmDownloadCandidate($sourceId -> $uri)';
}

/// The narrow abstraction [OsmDownloader] depends on to obtain download URLs.
///
/// It returns an ordered list of [OsmDownloadCandidate]s; the downloader tries
/// them in order, falling back to the next when one fails. This is the single
/// seam that keeps the downloader free of any provider-specific logic.
abstract interface class OsmSourceResolver {
  /// Returns the ordered candidate URLs for [region] (best first). An empty
  /// list means no registered source can serve the region.
  Future<List<OsmDownloadCandidate>> resolveCandidates(String region);
}

/// Thrown when a region cannot be resolved to any source, or when every
/// candidate source fails to serve it.
class OsmSourceException implements Exception {
  /// Human-readable description of the failure.
  final String message;

  /// The underlying error that triggered this failure, if any.
  final Object? cause;

  OsmSourceException(this.message, {this.cause});

  @override
  String toString() => cause == null
      ? 'OsmSourceException: $message'
      : 'OsmSourceException: $message (cause: $cause)';
}
