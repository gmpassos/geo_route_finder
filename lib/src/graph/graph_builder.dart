import 'dart:typed_data';

import '../model/geo_edge.dart';
import '../model/geo_graph.dart';
import 'graph_types.dart';

/// Compiles a generic [GeoGraph] into the search-optimized [RoutingGraph].
///
/// The build is **deterministic**: given identical input it always produces
/// byte-identical output. Vertices are assigned dense indices in ascending
/// order of their original id, and edges are emitted in a stable order. This is
/// essential so that serialized graphs are reproducible and cacheable.
///
/// Only nodes that are an endpoint of at least one edge become routing
/// vertices; nodes that appear solely as intermediate shape points are resolved
/// to coordinates and folded into edge geometry. This alone removes the bulk of
/// OSM's vertices (most OSM nodes only describe road curvature).
class GraphBuilder {
  const GraphBuilder();

  /// Builds a [RoutingGraph] from [graph].
  RoutingGraph build(GeoGraph graph) {
    // 1. Index node coordinates by original id.
    final coordOf = <int, _LatLon>{};
    for (final n in graph.nodes) {
      coordOf[n.id] = _LatLon(n.lat, n.lon);
    }

    // 2. Collect the set of endpoint ids (the actual routing vertices) and
    //    assign dense indices in ascending id order for determinism.
    final endpointIds = <int>{};
    for (final e in graph.edges) {
      if (coordOf.containsKey(e.sourceId) && coordOf.containsKey(e.targetId)) {
        endpointIds.add(e.sourceId);
        endpointIds.add(e.targetId);
      }
    }
    final sortedIds = endpointIds.toList()..sort();
    final indexOf = <int, int>{};
    for (var i = 0; i < sortedIds.length; i++) {
      indexOf[sortedIds[i]] = i;
    }
    final n = sortedIds.length;

    final lat = Float64List(n);
    final lon = Float64List(n);
    final originalId = Int64List(n);
    for (var i = 0; i < n; i++) {
      final id = sortedIds[i];
      final c = coordOf[id]!;
      lat[i] = c.lat;
      lon[i] = c.lon;
      originalId[i] = id;
    }

    // 3. Expand every GeoEdge into one or two directed edges.
    final dir = <_DirEdge>[];
    for (final e in graph.edges) {
      final s = indexOf[e.sourceId];
      final t = indexOf[e.targetId];
      if (s == null || t == null) continue; // dangling endpoint
      final geom = _resolveGeometry(e, coordOf);
      dir.add(_DirEdge(s, t, e.distanceMeters, e.travelTimeSeconds, geom));
      if (!e.oneWay) {
        dir.add(
          _DirEdge(
            t,
            s,
            e.distanceMeters,
            e.travelTimeSeconds,
            geom.reversed.toList(),
          ),
        );
      }
    }

    // 4. Stable ordering so the CSR layout is deterministic.
    dir.sort((a, b) {
      if (a.source != b.source) return a.source - b.source;
      if (a.target != b.target) return a.target - b.target;
      return a.distance.compareTo(b.distance);
    });

    // 5. Build CSR offsets and edge arrays.
    final m = dir.length;
    final adjOffset = Int32List(n + 1);
    for (final d in dir) {
      adjOffset[d.source + 1]++;
    }
    for (var i = 0; i < n; i++) {
      adjOffset[i + 1] += adjOffset[i];
    }

    final adjTarget = Int32List(m);
    final adjTime = Float64List(m);
    final adjDist = Float64List(m);
    final geomOffset = Int32List(m + 1);

    // Geometry is laid out in edge order, so we can fill it in the same pass.
    final geomBuilder = <double>[];
    for (var i = 0; i < m; i++) {
      final d = dir[i];
      adjTarget[i] = d.target;
      adjTime[i] = d.time;
      adjDist[i] = d.distance;
      geomOffset[i] = geomBuilder.length ~/ 2;
      for (final c in d.geometry) {
        geomBuilder.add(c.lat);
        geomBuilder.add(c.lon);
      }
    }
    geomOffset[m] = geomBuilder.length ~/ 2;

    return RoutingGraph(
      lat: lat,
      lon: lon,
      originalId: originalId,
      adjOffset: adjOffset,
      adjTarget: adjTarget,
      adjTime: adjTime,
      adjDist: adjDist,
      geomCoords: Float64List.fromList(geomBuilder),
      geomOffset: geomOffset,
    );
  }

  List<_LatLon> _resolveGeometry(GeoEdge e, Map<int, _LatLon> coordOf) {
    if (e.shapePoints.isEmpty) return const [];
    final out = <_LatLon>[];
    for (final id in e.shapePoints) {
      final c = coordOf[id];
      if (c != null) out.add(c);
    }
    return out;
  }
}

class _LatLon {
  final double lat;
  final double lon;
  const _LatLon(this.lat, this.lon);
}

class _DirEdge {
  final int source;
  final int target;
  final double distance;
  final double time;
  final List<_LatLon> geometry;
  const _DirEdge(
    this.source,
    this.target,
    this.distance,
    this.time,
    this.geometry,
  );
}
