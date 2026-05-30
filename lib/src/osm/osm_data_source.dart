import '../datasource/geo_data_source.dart';
import '../model/geo_graph.dart';
import 'osm_converter.dart';

/// The OpenStreetMap implementation of [GeoDataSource] — the first, reference
/// adapter. It reads a local `.osm.pbf` extract and converts it into the generic
/// [GeoGraph] via [OsmConverter].
///
/// Nothing in the routing engine depends on this class; it is one interchangeable
/// adapter among many (HERE, TomTom, bespoke datasets, …).
///
/// ```dart
/// final source = OsmDataSource(pbfFile: 'sao-paulo.osm.pbf');
/// final graph = await source.loadGraph();
/// ```
class OsmDataSource implements GeoDataSource {
  /// Path to the `.osm.pbf` extract.
  final String pbfFile;

  /// Converter controlling tag interpretation and compression.
  final OsmConverter converter;

  OsmDataSource({required this.pbfFile, OsmConverter? converter})
    : converter = converter ?? OsmConverter();

  @override
  Future<GeoGraph> loadGraph() => converter.toGeoGraph(pbfFile);
}
