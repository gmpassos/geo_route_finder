import '../graph/graph_types.dart';
import '../spatial/kd_tree.dart';
import 'geo_storage.dart';

/// Metadata describing a stored, compiled graph artifact.
class GraphMeta {
  /// On-disk format version, bumped on any breaking layout change.
  final int formatVersion;
  final int nodeCount;
  final int edgeCount;

  /// CRC32 of the `.graph` payload, for integrity verification on load.
  final int graphChecksum;

  /// CRC32 of the `.index` payload.
  final int indexChecksum;

  /// When the artifact was produced.
  final DateTime createdAt;

  const GraphMeta({
    required this.formatVersion,
    required this.nodeCount,
    required this.edgeCount,
    required this.graphChecksum,
    required this.indexChecksum,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'formatVersion': formatVersion,
    'nodeCount': nodeCount,
    'edgeCount': edgeCount,
    'graphChecksum': graphChecksum,
    'indexChecksum': indexChecksum,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory GraphMeta.fromJson(Map<String, dynamic> j) => GraphMeta(
    formatVersion: j['formatVersion'] as int,
    nodeCount: j['nodeCount'] as int,
    edgeCount: j['edgeCount'] as int,
    graphChecksum: j['graphChecksum'] as int,
    indexChecksum: j['indexChecksum'] as int,
    createdAt: DateTime.parse(j['createdAt'] as String),
  );
}

/// A fully compiled, ready-to-route bundle: the CSR [RoutingGraph], its spatial
/// [KdTree], and descriptive [meta]. This is what fast storage backends persist
/// and return so that routers can start answering queries without re-building
/// anything.
class CompiledGraph {
  final RoutingGraph graph;
  final KdTree tree;
  final GraphMeta meta;

  const CompiledGraph({
    required this.graph,
    required this.tree,
    required this.meta,
  });
}

/// An optional capability that a [GeoStorage] may also implement to persist and
/// return the *compiled* artifact (CSR graph + KD-tree) directly, bypassing the
/// lossy generic [GeoGraph] round-trip.
///
/// Routers and the converter feature-detect this interface: when a storage
/// backend supports it, the fast path is used; otherwise they fall back to the
/// plain [GeoStorage] API. This keeps the simple contract intact while letting
/// the bundled [LocalFileStorage] hit the package's performance targets.
abstract interface class CompiledGraphStorage implements GeoStorage {
  /// Persists a compiled artifact under [id].
  Future<void> saveCompiled(String id, CompiledGraph compiled);

  /// Loads the compiled artifact under [id], or `null` if absent.
  Future<CompiledGraph?> loadCompiled(String id);
}
