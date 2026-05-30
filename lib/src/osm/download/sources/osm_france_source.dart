import '../osm_download_source.dart';
import 'pattern_download_source.dart';

/// [OSM France](https://download.openstreetmap.fr/extracts/) — an alternative
/// provider of hierarchical `.osm.pbf` extracts.
///
/// It mirrors the same `continent/country/...` hierarchy as Geofabrik but uses
/// a different URL scheme (`<region>.osm.pbf`, without the `-latest` suffix),
/// which makes it a natural fallback/mirror for the same regions.
class OsmFranceSource extends OsmPatternDownloadSource {
  static const String defaultBaseUrl =
      'https://download.openstreetmap.fr/extracts/';

  OsmFranceSource({super.baseUrls = const [defaultBaseUrl]});

  @override
  String get id => 'osm_france';

  @override
  bool supportsRegion(String region) =>
      region.isNotEmpty && osmContinents.contains(region.split('/').first);

  @override
  Uri buildUri(String base, String region) => Uri.parse('$base$region.osm.pbf');
}
