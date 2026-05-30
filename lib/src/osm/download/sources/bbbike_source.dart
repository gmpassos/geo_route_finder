import 'pattern_download_source.dart';

/// [BBBike](https://download.bbbike.org/osm/bbbike/) — per-*city* extracts.
///
/// BBBike has a flat, city-keyed namespace rather than a continent hierarchy.
/// To disambiguate it from hierarchical providers, regions are addressed with a
/// `bbbike/<City>` prefix, e.g. `bbbike/Berlin`, resolving to
/// `…/bbbike/Berlin/Berlin.osm.pbf`.
class BBBikeSource extends OsmPatternDownloadSource {
  static const String defaultBaseUrl =
      'https://download.bbbike.org/osm/bbbike/';
  static const String prefix = 'bbbike/';

  BBBikeSource({super.baseUrls = const [defaultBaseUrl]});

  @override
  String get id => 'bbbike';

  @override
  bool supportsRegion(String region) {
    if (!region.startsWith(prefix)) return false;
    final city = region.substring(prefix.length);
    // A single city segment, no further nesting and not empty.
    return city.isNotEmpty && !city.contains('/');
  }

  @override
  Uri buildUri(String base, String region) {
    final city = region.substring(prefix.length);
    return Uri.parse('$base$city/$city.osm.pbf');
  }
}
