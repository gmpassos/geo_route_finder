import '../graph/graph_builder.dart';
import '../graph/graph_compressor.dart';
import '../model/geo_coordinate.dart';
import '../model/geo_edge.dart';
import '../model/geo_graph.dart';
import '../model/geo_node.dart';
import '../model/geo_way.dart';
import '../serialization/graph_serializer.dart';
import '../spatial/kd_tree.dart';
import '../storage/compiled_graph.dart';
import '../storage/geo_storage.dart';
import 'osm_pbf_parser.dart';

/// Converts an OpenStreetMap `.osm.pbf` extract into a routable graph.
///
/// Responsibilities:
///
/// * select routable ways by `highway` class and `access`,
/// * apply one-way restrictions (`oneway`, implicit motorway/roundabout),
/// * compute per-segment ground distance (haversine),
/// * infer speed limits from `maxspeed` or sensible per-class defaults,
/// * emit a normalized [GeoGraph], then optionally compile and store it.
///
/// Parsing is a memory-bounded two-pass scan: ways first (to learn which node
/// ids are referenced), then nodes (keeping only referenced coordinates).
class OsmConverter {
  final OsmPbfParser parser;
  final GraphBuilder builder;
  final GraphCompressor compressor;

  /// Whether to compress the compiled graph before storing. Strongly
  /// recommended; reduces size and speeds up routing.
  final bool compress;

  OsmConverter({
    this.parser = const OsmPbfParser(),
    this.builder = const GraphBuilder(),
    GraphCompressor? compressor,
    this.compress = true,
  }) : compressor = compressor ?? GraphCompressor();

  /// Routable highway classes (after stripping any `_link` suffix).
  static const Set<String> supportedHighways = {
    'motorway',
    'trunk',
    'primary',
    'secondary',
    'tertiary',
    'residential',
    'service',
    'living_street',
    'unclassified',
  };

  /// Default speeds in km/h per (normalized) highway class.
  static const Map<String, double> defaultSpeedKmh = {
    'motorway': 110,
    'trunk': 90,
    'primary': 80,
    'secondary': 60,
    'tertiary': 50,
    'residential': 40,
    'service': 20,
    'living_street': 10,
    'unclassified': 40,
  };

  /// Parses [inputFile] and returns the normalized (uncompiled) [GeoGraph].
  Future<GeoGraph> toGeoGraph(String inputFile) async {
    // Pass 1: ways. Keep routable ways and collect referenced node ids.
    final keptWays = <GeoWay>[];
    final neededNodes = <int>{};
    await parser.parse(
      inputFile,
      readNodes: false,
      onWay: (way) {
        if (!_isRoutable(way)) return;
        keptWays.add(way);
        neededNodes.addAll(way.nodeIds);
      },
    );

    // Pass 2: nodes. Keep only coordinates referenced by a kept way.
    final coords = <int, GeoNode>{};
    await parser.parse(
      inputFile,
      readWays: false,
      onNode: (node) {
        if (neededNodes.contains(node.id)) coords[node.id] = node;
      },
    );

    // Assemble the generic graph: one edge per consecutive node pair.
    final edges = <GeoEdge>[];
    for (final way in keptWays) {
      final speed = _speedFor(way);
      final dir = _onewayOf(way);
      final ids = way.nodeIds;
      for (var i = 0; i + 1 < ids.length; i++) {
        final a = coords[ids[i]];
        final b = coords[ids[i + 1]];
        if (a == null || b == null) continue;
        final dist = haversineMeters(a.lat, a.lon, b.lat, b.lon);
        if (dist <= 0) continue;
        if (dir == _OneWay.backward) {
          edges.add(
            GeoEdge(
              sourceId: b.id,
              targetId: a.id,
              distanceMeters: dist,
              speedKmh: speed,
              oneWay: true,
            ),
          );
        } else {
          edges.add(
            GeoEdge(
              sourceId: a.id,
              targetId: b.id,
              distanceMeters: dist,
              speedKmh: speed,
              oneWay: dir == _OneWay.forward,
            ),
          );
        }
      }
    }

    final nodes = coords.values.toList();
    return GeoGraph(nodes: nodes, edges: edges);
  }

  /// Compiles [inputFile] into a [CompiledGraph] (CSR + KD-tree + metadata).
  Future<CompiledGraph> compile(String inputFile) async {
    final geo = await toGeoGraph(inputFile);
    var routing = builder.build(geo);
    if (compress) routing = compressor.compress(routing);
    final tree = KdTree.build(routing);
    final meta = GraphMeta(
      formatVersion: kGraphFormatVersion,
      nodeCount: routing.nodeCount,
      edgeCount: routing.edgeCount,
      graphChecksum: 0,
      indexChecksum: 0,
      createdAt: DateTime.now(),
    );
    return CompiledGraph(graph: routing, tree: tree, meta: meta);
  }

  /// Converts [inputFile] and stores the result under [graphId] in [storage].
  ///
  /// When [storage] supports the compiled fast path, the compressed CSR + KD-tree
  /// are written directly; otherwise the generic [GeoGraph] is stored via
  /// [GeoStorage.saveGraph].
  Future<void> convert({
    required String inputFile,
    required GeoStorage storage,
    required String graphId,
  }) async {
    if (storage is CompiledGraphStorage) {
      final compiled = await compile(inputFile);
      await storage.saveCompiled(graphId, compiled);
    } else {
      await storage.saveGraph(graphId, await toGeoGraph(inputFile));
    }
  }

  bool _isRoutable(GeoWay way) {
    final highway = way.tags['highway'];
    if (highway == null) return false;
    if (_normalizeHighway(highway) == null) return false;
    if (way.tags['area'] == 'yes') return false;
    final access = way.tags['access'];
    if (access == 'no' || access == 'private') return false;
    return way.nodeIds.length >= 2;
  }

  String? _normalizeHighway(String highway) {
    final base = highway.endsWith('_link')
        ? highway.substring(0, highway.length - 5)
        : highway;
    return supportedHighways.contains(base) ? base : null;
  }

  double _speedFor(GeoWay way) {
    final parsed = _parseMaxspeed(way.tags['maxspeed']);
    if (parsed != null) return parsed;
    final base = _normalizeHighway(way.tags['highway']!)!;
    return defaultSpeedKmh[base] ?? 40;
  }

  double? _parseMaxspeed(String? raw) {
    if (raw == null) return null;
    final s = raw.trim().toLowerCase();
    // Leading number, e.g. "50", "50 km/h", "30mph", "60kph".
    final m = RegExp(r'^(\d+(?:\.\d+)?)').firstMatch(s);
    if (m == null) return null; // non-numeric e.g. "RO:urban", "walk"
    final n = double.tryParse(m.group(1)!);
    if (n == null) return null;
    if (s.contains('mph')) return n * 1.609344;
    return n;
  }

  _OneWay _onewayOf(GeoWay way) {
    final v = way.tags['oneway'];
    if (v == 'yes' || v == 'true' || v == '1') return _OneWay.forward;
    if (v == '-1' || v == 'reverse') return _OneWay.backward;
    if (v == 'no' || v == 'false' || v == '0') return _OneWay.none;
    // Implicit one-way: motorways and roundabouts.
    final highway = way.tags['highway'];
    if (highway == 'motorway' || highway == 'motorway_link') {
      return _OneWay.forward;
    }
    final junction = way.tags['junction'];
    if (junction == 'roundabout' || junction == 'circular') {
      return _OneWay.forward;
    }
    return _OneWay.none;
  }
}

enum _OneWay { none, forward, backward }
