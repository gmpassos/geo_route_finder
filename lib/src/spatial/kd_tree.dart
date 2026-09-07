import 'dart:math' as math;
import 'dart:typed_data';

import 'package:geo_osm_pbf/geo_osm_pbf.dart';

import '../graph/graph_types.dart';

/// Result of a nearest-neighbour query: the matched vertex and its great-circle
/// distance from the query point in meters.
class NearestResult {
  final int node;
  final double distanceMeters;
  const NearestResult(this.node, this.distanceMeters);

  bool get found => node >= 0;
  static const NearestResult none = NearestResult(-1, double.infinity);
}

/// A balanced, array-backed 2-D KD-tree over the vertices of a [RoutingGraph].
///
/// The tree is *implicit*: the only state is a permutation [order] of vertex
/// indices in which the element at the middle of every sub-range is that
/// sub-tree's splitting node. This makes the tree trivially serializable — store
/// [order] and [cosRef], and reconstruction is O(n) with no re-sorting (see
/// [KdTree.fromOrder]).
///
/// Coordinates are compared in a local equirectangular projection (meters)
/// using a fixed reference latitude, so query radii and distances are expressed
/// directly in meters and match haversine closely at the scales relevant to
/// road routing.
class KdTree {
  /// Meters per degree of latitude.
  static final double _mPerDeg = math.pi / 180.0 * earthRadiusMeters;

  final RoutingGraph _g;

  /// The implicit-tree permutation of vertex indices.
  final Int32List order;

  /// Cosine of the reference latitude used to project longitudes.
  final double cosRef;

  /// Projected vertex coordinates in meters (equirectangular), indexed by vertex
  /// index. Precomputing the projection once avoids repeating the multiply on
  /// every comparison during the build and on every distance test during a
  /// query, which is the dominant cost when indexing a regional graph.
  final Float64List _px;
  final Float64List _py;

  KdTree._(this._g, this.order, this.cosRef)
    : _px = _project(_g.lon, _mPerDeg * cosRef),
      _py = _project(_g.lat, _mPerDeg);

  static Float64List _project(Float64List src, double scale) {
    final out = Float64List(src.length);
    for (var i = 0; i < src.length; i++) {
      out[i] = src[i] * scale;
    }
    return out;
  }

  /// Builds a balanced KD-tree over every vertex of [g].
  factory KdTree.build(RoutingGraph g) {
    final n = g.nodeCount;
    final order = Int32List(n);
    for (var i = 0; i < n; i++) {
      order[i] = i;
    }
    var sumLat = 0.0;
    for (var i = 0; i < n; i++) {
      sumLat += g.lat[i];
    }
    final meanLat = n == 0 ? 0.0 : sumLat / n;
    final cosRef = math.cos(meanLat * math.pi / 180.0);
    final tree = KdTree._(g, order, cosRef);
    tree._build(0, n, 0);
    return tree;
  }

  /// Reconstructs a tree from a previously persisted [order] permutation.
  /// No median selection is performed, so this is O(n).
  factory KdTree.fromOrder(RoutingGraph g, Int32List order, double cosRef) =>
      KdTree._(g, order, cosRef);

  double _x(int i) => _px[i];
  double _y(int i) => _py[i];

  void _build(int lo, int hi, int depth) {
    if (hi - lo <= 1) return;
    final m = (lo + hi) >> 1;
    _nthElement(lo, hi, m, depth & 1);
    _build(lo, m, depth + 1);
    _build(m + 1, hi, depth + 1);
  }

  /// Quickselect: partitions `order[lo..hi)` so that the element at [k] is the
  /// one that would be there if the range were sorted by the given [axis].
  void _nthElement(int lo, int hi, int k, int axis) {
    var l = lo;
    var r = hi - 1;
    while (l < r) {
      final pivot = _coord(order[(l + r) >> 1], axis);
      var i = l;
      var j = r;
      while (i <= j) {
        while (_coord(order[i], axis) < pivot) {
          i++;
        }
        while (_coord(order[j], axis) > pivot) {
          j--;
        }
        if (i <= j) {
          final t = order[i];
          order[i] = order[j];
          order[j] = t;
          i++;
          j--;
        }
      }
      if (k <= j) {
        r = j;
      } else if (k >= i) {
        l = i;
      } else {
        break;
      }
    }
  }

  double _coord(int node, int axis) => axis == 0 ? _x(node) : _y(node);

  /// Finds the vertex nearest to (`lat`, `lon`).
  NearestResult findNearest(double lat, double lon) {
    if (_g.nodeCount == 0) return NearestResult.none;
    final qx = lon * _mPerDeg * cosRef;
    final qy = lat * _mPerDeg;
    final best = _Best();
    _nearest(0, _g.nodeCount, 0, qx, qy, best);
    if (best.node < 0) return NearestResult.none;
    // Refine with an exact haversine distance for the winning vertex.
    final d = haversineMeters(lat, lon, _g.lat[best.node], _g.lon[best.node]);
    return NearestResult(best.node, d);
  }

  void _nearest(int lo, int hi, int depth, double qx, double qy, _Best best) {
    if (lo >= hi) return;
    final m = (lo + hi) >> 1;
    final node = order[m];
    final dx = qx - _x(node);
    final dy = qy - _y(node);
    final d2 = dx * dx + dy * dy;
    if (d2 < best.dist2) {
      best.dist2 = d2;
      best.node = node;
    }
    final axis = depth & 1;
    final diff = axis == 0 ? dx : dy;
    if (diff < 0) {
      _nearest(lo, m, depth + 1, qx, qy, best);
      if (diff * diff < best.dist2) {
        _nearest(m + 1, hi, depth + 1, qx, qy, best);
      }
    } else {
      _nearest(m + 1, hi, depth + 1, qx, qy, best);
      if (diff * diff < best.dist2) _nearest(lo, m, depth + 1, qx, qy, best);
    }
  }

  /// Returns the vertices within [radiusMeters] of (`lat`, `lon`), nearest
  /// first. The radius test uses the projected metric, which is accurate to a
  /// fraction of a percent at city/regional scales.
  List<NearestResult> findWithinRadius(
    double lat,
    double lon,
    double radiusMeters,
  ) {
    final out = <NearestResult>[];
    if (_g.nodeCount == 0) return out;
    final qx = lon * _mPerDeg * cosRef;
    final qy = lat * _mPerDeg;
    final r2 = radiusMeters * radiusMeters;
    _within(0, _g.nodeCount, 0, qx, qy, r2, out);
    out.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    return out;
  }

  void _within(
    int lo,
    int hi,
    int depth,
    double qx,
    double qy,
    double r2,
    List<NearestResult> out,
  ) {
    if (lo >= hi) return;
    final m = (lo + hi) >> 1;
    final node = order[m];
    final dx = qx - _x(node);
    final dy = qy - _y(node);
    final d2 = dx * dx + dy * dy;
    if (d2 <= r2) out.add(NearestResult(node, math.sqrt(d2)));
    final axis = depth & 1;
    final diff = axis == 0 ? dx : dy;
    if (diff < 0) {
      _within(lo, m, depth + 1, qx, qy, r2, out);
      if (diff * diff <= r2) _within(m + 1, hi, depth + 1, qx, qy, r2, out);
    } else {
      _within(m + 1, hi, depth + 1, qx, qy, r2, out);
      if (diff * diff <= r2) _within(lo, m, depth + 1, qx, qy, r2, out);
    }
  }

  /// Convenience overload taking a [GeoCoordinate].
  NearestResult nearestTo(GeoCoordinate c) => findNearest(c.lat, c.lon);
}

class _Best {
  int node = -1;
  double dist2 = double.infinity;
}
