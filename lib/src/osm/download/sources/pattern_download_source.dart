import '../osm_download_source.dart';

/// Convenience base for sources whose URLs follow a fixed pattern over one or
/// more interchangeable mirror roots ([baseUrls]).
///
/// Subclasses only declare their [id], a [supportsRegion] predicate and how to
/// [buildUri] for a single base. Mirror handling and trailing-slash
/// normalization are provided here.
abstract class OsmPatternDownloadSource implements OsmMirroredSource {
  /// Mirror roots, normalized to always end with a `/`. The first entry is the
  /// preferred mirror.
  final List<String> baseUrls;

  OsmPatternDownloadSource({required List<String> baseUrls})
    : assert(baseUrls.isNotEmpty, 'at least one base URL is required'),
      baseUrls = List.unmodifiable([
        for (final b in baseUrls) b.endsWith('/') ? b : '$b/',
      ]);

  /// Builds the extract URL for [region] under [base] (guaranteed to end with
  /// `/`). Called once per mirror.
  Uri buildUri(String base, String region);

  @override
  Future<Uri?> resolveRegion(String region) async =>
      supportsRegion(region) ? buildUri(baseUrls.first, region) : null;

  @override
  Future<List<Uri>> resolveMirrors(String region) async =>
      supportsRegion(region)
      ? [for (final b in baseUrls) buildUri(b, region)]
      : const [];
}
