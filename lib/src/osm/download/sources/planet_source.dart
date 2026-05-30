import 'pattern_download_source.dart';

/// [OpenStreetMap Planet](https://planet.openstreetmap.org/) — the full planet
/// dump.
///
/// It serves exactly one "region": the whole planet, addressed as `planet`,
/// resolving to `…/pbf/planet-latest.osm.pbf`. As a multi-hundred-gigabyte
/// download it is the last-resort source and is registered at lowest priority.
class PlanetSource extends OsmPatternDownloadSource {
  static const String defaultBaseUrl = 'https://planet.openstreetmap.org/pbf/';
  static const String regionId = 'planet';

  PlanetSource({super.baseUrls = const [defaultBaseUrl]});

  @override
  String get id => 'planet';

  @override
  bool supportsRegion(String region) => region == regionId;

  @override
  Uri buildUri(String base, String region) =>
      Uri.parse('${base}planet-latest.osm.pbf');
}
