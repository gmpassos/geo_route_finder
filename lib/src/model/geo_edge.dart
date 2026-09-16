/// A directed connection between two [GeoNode]s in the generic road graph.
///
/// An undirected road segment is represented either as a single edge with
/// [oneWay] set to `false` (the graph builder will materialise the reverse
/// direction), or as two opposing edges. Adapters should prefer the former.
class GeoEdge {
  /// Id of the node the edge starts at.
  final int sourceId;

  /// Id of the node the edge ends at.
  final int targetId;

  /// Length of the segment along the ground, in meters.
  final double distanceMeters;

  /// Permitted travel speed along the segment, in kilometres per hour. Used to
  /// derive the travel-time weight that the routers minimise.
  final double speedKmh;

  /// Whether travel is only permitted from [sourceId] to [targetId].
  final bool oneWay;

  /// Number of toll sections along the segment (`0` for a free road). Carried
  /// through to the routing graph and accumulated when degree-2 chains are
  /// collapsed, so a route can report and avoid tolls.
  final int tolls;

  /// Whether this segment may only be used to reach something on it.
  ///
  /// A driveway, a parking aisle, a track, a road signed `access=destination`.
  /// Not unusable — a rider has to be able to reach the address — but never a
  /// link in the middle of a route, which is what stops a router cutting
  /// across a supermarket car park to save thirty metres.
  ///
  /// Kept as a property of the edge rather than resolved at build time,
  /// because whether it may be used depends on where the route starts and
  /// ends. Turn restrictions could become topology; this cannot.
  final bool accessOnly;

  /// Optional intermediate geometry, expressed as node ids that lie between
  /// [sourceId] and [targetId]. Empty for a straight segment. These points are
  /// purely cosmetic for the routing graph (they are collapsed away) but are
  /// preserved so that the returned route geometry follows the real road shape.
  final List<int> shapePoints;

  const GeoEdge({
    required this.sourceId,
    required this.targetId,
    required this.distanceMeters,
    required this.speedKmh,
    this.oneWay = false,
    this.tolls = 0,
    this.accessOnly = false,
    this.shapePoints = const [],
  });

  /// Travel time across the edge in seconds, derived from [distanceMeters] and
  /// [speedKmh]. Returns [double.infinity] for a zero speed so that such edges
  /// are never selected by a shortest-path search.
  double get travelTimeSeconds {
    if (speedKmh <= 0) return double.infinity;
    return distanceMeters / (speedKmh * (1000.0 / 3600.0));
  }

  /// Whether the segment crosses at least one toll.
  bool get hasToll => tolls > 0;

  @override
  String toString() =>
      'GeoEdge($sourceId -> $targetId, ${distanceMeters.toStringAsFixed(1)}m, '
      '${speedKmh.toStringAsFixed(0)}km/h, oneWay: $oneWay, tolls: $tolls)';
}
