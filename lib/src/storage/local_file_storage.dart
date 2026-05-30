import 'dart:convert';
import 'dart:io';

import '../graph/graph_builder.dart';
import '../model/geo_edge.dart';
import '../model/geo_graph.dart';
import '../model/geo_node.dart';
import '../serialization/checksum.dart';
import '../serialization/graph_deserializer.dart';
import '../serialization/graph_serializer.dart';
import '../spatial/kd_tree.dart';
import 'compiled_graph.dart';

/// Filesystem-backed storage that persists compiled graphs in the package's
/// compact binary format.
///
/// Each graph id maps to three files in [directory]:
///
/// * `<id>.graph` — the CSR routing graph,
/// * `<id>.index` — the KD-tree spatial index,
/// * `<id>.meta`  — JSON metadata (versions, counts, CRC-32 checksums, date).
///
/// Loading reads each payload once and exposes the CSR arrays as zero-copy views
/// over the file bytes (the closest pure-Dart equivalent to memory mapping,
/// which the SDK does not expose). Checksums are verified on every load.
///
/// Because each graph id is an independent triple of files, datasets can be
/// updated incrementally — re-converting one region replaces only that region's
/// files and leaves every other stored graph untouched.
class LocalFileStorage implements CompiledGraphStorage {
  /// Directory under which graph files are written. Created on first save.
  final String directory;

  final GraphSerializer _serializer;
  final GraphDeserializer _deserializer;

  LocalFileStorage({
    required this.directory,
    GraphSerializer serializer = const GraphSerializer(),
    GraphDeserializer deserializer = const GraphDeserializer(),
  }) : _serializer = serializer,
       _deserializer = deserializer;

  String _safe(String id) => id.replaceAll(RegExp(r'[\\/]'), '_');
  String _graphPath(String id) => '$directory/${_safe(id)}.graph';
  String _indexPath(String id) => '$directory/${_safe(id)}.index';
  String _metaPath(String id) => '$directory/${_safe(id)}.meta';

  @override
  Future<void> saveCompiled(String id, CompiledGraph compiled) async {
    await Directory(directory).create(recursive: true);

    final graphBytes = _serializer.serializeGraph(compiled.graph);
    final indexBytes = _serializer.serializeIndex(compiled.tree);
    final graphCrc = Crc32.compute(graphBytes);
    final indexCrc = Crc32.compute(indexBytes);

    final meta = GraphMeta(
      formatVersion: kGraphFormatVersion,
      nodeCount: compiled.graph.nodeCount,
      edgeCount: compiled.graph.edgeCount,
      graphChecksum: graphCrc,
      indexChecksum: indexCrc,
      createdAt: DateTime.now(),
    );

    await File(_graphPath(id)).writeAsBytes(graphBytes, flush: true);
    await File(_indexPath(id)).writeAsBytes(indexBytes, flush: true);
    await File(
      _metaPath(id),
    ).writeAsString(jsonEncode(meta.toJson()), flush: true);
  }

  @override
  Future<CompiledGraph?> loadCompiled(String id) async {
    final metaFile = File(_metaPath(id));
    if (!await metaFile.exists()) return null;

    final meta = GraphMeta.fromJson(
      jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>,
    );
    if (meta.formatVersion != kGraphFormatVersion) {
      throw GraphFormatException(
        'stored graph "$id" uses format version ${meta.formatVersion}, '
        'this build expects $kGraphFormatVersion',
      );
    }

    final graphBytes = await File(_graphPath(id)).readAsBytes();
    if (Crc32.compute(graphBytes) != meta.graphChecksum) {
      throw GraphFormatException(
        'checksum mismatch for "$id" (.graph corrupt)',
      );
    }
    final indexBytes = await File(_indexPath(id)).readAsBytes();
    if (Crc32.compute(indexBytes) != meta.indexChecksum) {
      throw GraphFormatException(
        'checksum mismatch for "$id" (.index corrupt)',
      );
    }

    final graph = _deserializer.deserializeGraph(graphBytes);
    final tree = _deserializer.deserializeIndex(indexBytes, graph);
    return CompiledGraph(graph: graph, tree: tree, meta: meta);
  }

  @override
  Future<void> saveGraph(String id, GeoGraph graph) async {
    final routing = const GraphBuilder().build(graph);
    final tree = KdTree.build(routing);
    final meta = GraphMeta(
      formatVersion: kGraphFormatVersion,
      nodeCount: routing.nodeCount,
      edgeCount: routing.edgeCount,
      graphChecksum: 0,
      indexChecksum: 0,
      createdAt: DateTime.now(),
    );
    await saveCompiled(
      id,
      CompiledGraph(graph: routing, tree: tree, meta: meta),
    );
  }

  @override
  Future<GeoGraph?> loadGraph(String id) async {
    final compiled = await loadCompiled(id);
    if (compiled == null) return null;
    final g = compiled.graph;
    final nodes = <GeoNode>[
      for (var v = 0; v < g.nodeCount; v++)
        GeoNode(id: g.originalId[v], lat: g.lat[v], lon: g.lon[v]),
    ];
    final edges = <GeoEdge>[];
    for (var u = 0; u < g.nodeCount; u++) {
      for (var e = g.adjOffset[u]; e < g.adjOffset[u + 1]; e++) {
        final v = g.adjTarget[e];
        final dist = g.adjDist[e];
        final time = g.adjTime[e];
        final speed = time > 0 ? dist / time * 3.6 : 0.0;
        edges.add(
          GeoEdge(
            sourceId: g.originalId[u],
            targetId: g.originalId[v],
            distanceMeters: dist,
            speedKmh: speed,
            oneWay: true,
          ),
        );
      }
    }
    return GeoGraph(nodes: nodes, edges: edges);
  }

  @override
  Future<bool> exists(String id) => File(_metaPath(id)).exists();

  @override
  Future<void> delete(String id) async {
    for (final path in [_graphPath(id), _indexPath(id), _metaPath(id)]) {
      final f = File(path);
      if (await f.exists()) await f.delete();
    }
  }
}
