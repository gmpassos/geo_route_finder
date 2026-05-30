import '../osm_download_source.dart';
import 'pattern_download_source.dart';

/// [Geofabrik](https://download.geofabrik.de/) — the most widely used provider
/// of per-region `.osm.pbf` extracts.
///
/// Regions are hierarchical, `continent[/country[/subregion]]`, e.g.:
///
/// ```text
/// south-america/brazil/santa-catarina
/// north-america/us/california
/// europe/germany
/// ```
///
/// A region is supported when its first path segment is a known continent
/// (see [osmContinents]). Files are named `<region>-latest.osm.pbf`.
class GeofabrikSource extends OsmPatternDownloadSource {
  static const String defaultBaseUrl = 'https://download.geofabrik.de/';

  GeofabrikSource({super.baseUrls = const [defaultBaseUrl]});

  @override
  String get id => 'geofabrik';

  @override
  bool supportsRegion(String region) =>
      region.isNotEmpty && osmContinents.contains(region.split('/').first);

  @override
  Uri buildUri(String base, String region) =>
      Uri.parse('$base$region-latest.osm.pbf');
}
