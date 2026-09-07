import 'package:geo_osm_pbf/geo_osm_pbf.dart';

import '../graph/graph_types.dart';
import 'kd_tree.dart';

/// High-level snapping service that maps free-form geographic coordinates onto
/// the nearest routable vertex of a [RoutingGraph].
///
/// This is the bridge between the user-facing coordinate space and the graph's
/// vertex space: every routing query begins by snapping the origin and
/// destination to vertices via this class.
class NearestNodeSearch {
  final RoutingGraph graph;
  final KdTree tree;

  NearestNodeSearch(this.graph, this.tree);

  /// Builds the search over [graph], constructing a fresh KD-tree.
  factory NearestNodeSearch.build(RoutingGraph graph) =>
      NearestNodeSearch(graph, KdTree.build(graph));

  /// Snaps [c] to the nearest vertex. Returns [NearestResult.none] if the graph
  /// is empty or no vertex lies within [maxSnapMeters] (when provided).
  NearestResult snap(GeoCoordinate c, {double? maxSnapMeters}) {
    final r = tree.findNearest(c.lat, c.lon);
    if (!r.found) return NearestResult.none;
    if (maxSnapMeters != null && r.distanceMeters > maxSnapMeters) {
      return NearestResult.none;
    }
    return r;
  }

  /// All vertices within [radiusMeters] of [c], nearest first.
  List<NearestResult> within(GeoCoordinate c, double radiusMeters) =>
      tree.findWithinRadius(c.lat, c.lon, radiusMeters);
}
