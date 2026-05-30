/// A raw, source-level polyline of nodes plus its tags.
///
/// This mirrors the OpenStreetMap notion of a "way" but is deliberately generic:
/// it is simply an ordered list of node ids with an associated string→string tag
/// map. Data-source adapters emit [GeoWay]s, and a converter turns them into the
/// directed [GeoEdge]s of the routing graph by interpreting the tags (highway
/// class, one-way restrictions, speed limits, access, …).
class GeoWay {
  /// Source identifier of the way.
  final int id;

  /// Ordered node ids that make up the way's polyline.
  final List<int> nodeIds;

  /// Arbitrary key/value metadata describing the way.
  final Map<String, String> tags;

  const GeoWay({required this.id, required this.nodeIds, required this.tags});

  @override
  String toString() => 'GeoWay($id, ${nodeIds.length} nodes, $tags)';
}
