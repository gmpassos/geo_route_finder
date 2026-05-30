import 'dart:typed_data';

import 'priority_queue.dart';
import 'route_finder.dart';

/// A single edge in the contraction-hierarchy edge table — either an original
/// road edge or a generated shortcut.
class _ChEdge {
  final int from;
  final int to;
  final double weight; // travel time, seconds
  final double dist; // meters
  final int orig; // routing-graph edge index, or -1 for a shortcut
  final int childA; // CH edge id (from -> middle), or -1
  final int childB; // CH edge id (middle -> to), or -1
  const _ChEdge(
    this.from,
    this.to,
    this.weight,
    this.dist,
    this.orig,
    this.childA,
    this.childB,
  );
}

class _Neighbour {
  final double w;
  final double dist;
  final int eid;
  const _Neighbour(this.w, this.dist, this.eid);
}

class _Shortcut {
  final int u;
  final int w;
  final double weight;
  final double dist;
  final int inEid;
  final int outEid;
  const _Shortcut(
    this.u,
    this.w,
    this.weight,
    this.dist,
    this.inEid,
    this.outEid,
  );
}

/// Contraction-Hierarchies router: optional preprocessing that yields
/// dramatically faster queries than plain Dijkstra/A* on the same graph.
///
/// **Preprocessing** ([prepare]) assigns every vertex an importance-based
/// *rank* and contracts vertices from least to most important. Contracting a
/// vertex `v` inserts *shortcut* edges between its neighbours wherever the only
/// shortest path between them went through `v`, so that `v` can be skipped at
/// query time. A local "witness" Dijkstra avoids inserting unnecessary
/// shortcuts.
///
/// **Querying** ([search]) runs a bidirectional Dijkstra that, from each side,
/// only ever moves to *higher-ranked* vertices. Because the hierarchy guarantees
/// every shortest path is an up-down sequence of ranks, the two searches meet
/// after touching only a tiny fraction of the graph. Shortcuts are then unpacked
/// back into the original edges so the returned route keeps full geometry.
///
/// The router is a drop-in replacement for [AStarRouter] — identical public API.
class ContractionHierarchyRouter extends GraphRouteFinder {
  /// Caps each witness search; on overflow a shortcut is added conservatively
  /// (never affects correctness, only graph size).
  final int witnessSettleLimit;

  ContractionHierarchyRouter({
    required super.storage,
    required super.graphId,
    super.maxSnapMeters,
    this.witnessSettleLimit = 1000,
  });

  static const double _eps = 1e-7;

  // Mutable preprocessing state.
  late List<_ChEdge> _edges;
  late List<List<int>> _outE;
  late List<List<int>> _inE;
  late Uint8List _contracted;
  late Int32List _rank;
  late Int32List _deletedNeighbours;
  int _nextRank = 0;

  // Query-time upward/downward adjacency (CSR over CH edge ids).
  late Int32List _fOff;
  late Int32List _fEid;
  late Int32List _bOff;
  late Int32List _bEid;

  @override
  Future<void> prepare() async {
    _build();
  }

  void _build() {
    final g = graph;
    final n = g.nodeCount;
    _edges = <_ChEdge>[];
    _outE = List.generate(n, (_) => <int>[]);
    _inE = List.generate(n, (_) => <int>[]);
    _contracted = Uint8List(n);
    _rank = Int32List(n)..fillRange(0, n, -1);
    _deletedNeighbours = Int32List(n);

    for (var e = 0; e < g.edgeCount; e++) {
      final id = _edges.length;
      final from = _sourceOfEdge(e);
      final to = g.adjTarget[e];
      _edges.add(_ChEdge(from, to, g.adjTime[e], g.adjDist[e], e, -1, -1));
      _outE[from].add(id);
      _inE[to].add(id);
    }

    // Initial importance priority queue (lazy updates on pop).
    final pq = MinHeap(n + 1);
    for (var v = 0; v < n; v++) {
      pq.push(_importance(v).toDouble(), v);
    }

    while (pq.isNotEmpty) {
      final v = pq.pop();
      if (_contracted[v] == 1) continue;
      final imp = _importance(v);
      if (pq.isNotEmpty && imp > pq.peekKey) {
        pq.push(imp.toDouble(), v); // stale: defer
        continue;
      }
      _contract(v);
    }

    _buildQueryGraph(n);
  }

  /// Recovers the source vertex of routing edge [e] via the CSR offsets.
  int _sourceOfEdge(int e) {
    final g = graph;
    // Binary search adjOffset for the row containing e.
    var lo = 0;
    var hi = g.nodeCount;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (g.adjOffset[mid] <= e) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo - 1;
  }

  Map<int, _Neighbour> _inNeighbours(int v) {
    final m = <int, _Neighbour>{};
    for (final eid in _inE[v]) {
      final e = _edges[eid];
      if (_contracted[e.from] == 1) continue;
      final existing = m[e.from];
      if (existing == null || e.weight < existing.w) {
        m[e.from] = _Neighbour(e.weight, e.dist, eid);
      }
    }
    return m;
  }

  Map<int, _Neighbour> _outNeighbours(int v) {
    final m = <int, _Neighbour>{};
    for (final eid in _outE[v]) {
      final e = _edges[eid];
      if (_contracted[e.to] == 1) continue;
      final existing = m[e.to];
      if (existing == null || e.weight < existing.w) {
        m[e.to] = _Neighbour(e.weight, e.dist, eid);
      }
    }
    return m;
  }

  List<_Shortcut> _shortcutsFor(int v) {
    final inN = _inNeighbours(v);
    final outN = _outNeighbours(v);
    final res = <_Shortcut>[];
    if (inN.isEmpty || outN.isEmpty) return res;
    var maxOut = 0.0;
    for (final o in outN.values) {
      if (o.w > maxOut) maxOut = o.w;
    }
    for (final entry in inN.entries) {
      final u = entry.key;
      final iu = entry.value;
      final witness = _witness(u, v, iu.w + maxOut);
      for (final oe in outN.entries) {
        final w = oe.key;
        if (w == u) continue;
        final ow = oe.value;
        final needed = iu.w + ow.w;
        final wd = witness[w];
        if (wd == null || wd > needed + _eps) {
          res.add(
            _Shortcut(u, w, needed, iu.dist + ow.dist, iu.eid, oe.value.eid),
          );
        }
      }
    }
    return res;
  }

  /// Local Dijkstra from [src] over non-contracted vertices, excluding
  /// [exclude], bounded by [maxDist] cost and [witnessSettleLimit] settles.
  Map<int, double> _witness(int src, int exclude, double maxDist) {
    final dist = <int, double>{src: 0.0};
    final heap = MinHeap(64);
    heap.push(0, src);
    var settled = 0;
    while (heap.isNotEmpty) {
      final d = heap.peekKey;
      final u = heap.pop();
      final cur = dist[u];
      if (cur == null || d > cur) continue;
      if (d > maxDist) break;
      if (++settled > witnessSettleLimit) break;
      for (final eid in _outE[u]) {
        final e = _edges[eid];
        final to = e.to;
        if (to == exclude || _contracted[to] == 1) continue;
        final nd = d + e.weight;
        if (nd > maxDist) continue;
        final old = dist[to];
        if (old == null || nd < old) {
          dist[to] = nd;
          heap.push(nd, to);
        }
      }
    }
    return dist;
  }

  int _importance(int v) {
    final inN = _inNeighbours(v);
    final outN = _outNeighbours(v);
    final shortcuts = _shortcutsFor(v).length;
    final degree = inN.length + outN.length;
    return (shortcuts - degree) + _deletedNeighbours[v];
  }

  void _contract(int v) {
    final shortcuts = _shortcutsFor(v);
    for (final sc in shortcuts) {
      final id = _edges.length;
      _edges.add(
        _ChEdge(sc.u, sc.w, sc.weight, sc.dist, -1, sc.inEid, sc.outEid),
      );
      _outE[sc.u].add(id);
      _inE[sc.w].add(id);
    }
    final neighbours = <int>{
      ..._inNeighbours(v).keys,
      ..._outNeighbours(v).keys,
    };
    _contracted[v] = 1;
    _rank[v] = _nextRank++;
    for (final u in neighbours) {
      _deletedNeighbours[u]++;
    }
  }

  void _buildQueryGraph(int n) {
    final fCount = Int32List(n);
    final bCount = Int32List(n);
    for (final e in _edges) {
      if (_rank[e.from] < _rank[e.to]) {
        fCount[e.from]++;
      } else {
        bCount[e.to]++;
      }
    }
    _fOff = Int32List(n + 1);
    _bOff = Int32List(n + 1);
    for (var i = 0; i < n; i++) {
      _fOff[i + 1] = _fOff[i] + fCount[i];
      _bOff[i + 1] = _bOff[i] + bCount[i];
    }
    _fEid = Int32List(_fOff[n]);
    _bEid = Int32List(_bOff[n]);
    final fCur = Int32List.fromList(_fOff);
    final bCur = Int32List.fromList(_bOff);
    for (var id = 0; id < _edges.length; id++) {
      final e = _edges[id];
      if (_rank[e.from] < _rank[e.to]) {
        _fEid[fCur[e.from]++] = id;
      } else {
        _bEid[bCur[e.to]++] = id;
      }
    }
  }

  @override
  RawPath search(int source, int target) {
    final n = graph.nodeCount;
    final distF = Float64List(n)..fillRange(0, n, double.infinity);
    final distB = Float64List(n)..fillRange(0, n, double.infinity);
    final peF = Int32List(n)..fillRange(0, n, -1);
    final pnF = Int32List(n)..fillRange(0, n, -1);
    final peB = Int32List(n)..fillRange(0, n, -1);
    final pnB = Int32List(n)..fillRange(0, n, -1);

    final heapF = MinHeap();
    final heapB = MinHeap();
    distF[source] = 0;
    distB[target] = 0;
    heapF.push(0, source);
    heapB.push(0, target);

    var mu = double.infinity;
    var meet = -1;

    while (heapF.isNotEmpty || heapB.isNotEmpty) {
      final fMin = heapF.isEmpty ? double.infinity : heapF.peekKey;
      final bMin = heapB.isEmpty ? double.infinity : heapB.peekKey;
      if (fMin >= mu && bMin >= mu) break;

      if (fMin <= bMin) {
        final d = heapF.peekKey;
        final u = heapF.pop();
        if (d > distF[u]) continue;
        for (var i = _fOff[u]; i < _fOff[u + 1]; i++) {
          final eid = _fEid[i];
          final e = _edges[eid];
          final v = e.to;
          final nd = d + e.weight;
          if (nd < distF[v]) {
            distF[v] = nd;
            peF[v] = eid;
            pnF[v] = u;
            heapF.push(nd, v);
            if (distB[v].isFinite && nd + distB[v] < mu) {
              mu = nd + distB[v];
              meet = v;
            }
          }
        }
      } else {
        final d = heapB.peekKey;
        final u = heapB.pop();
        if (d > distB[u]) continue;
        for (var i = _bOff[u]; i < _bOff[u + 1]; i++) {
          final eid = _bEid[i];
          final e = _edges[eid];
          final a = e.from; // edge a -> u, used backward
          final nd = d + e.weight;
          if (nd < distB[a]) {
            distB[a] = nd;
            peB[a] = eid;
            pnB[a] = u;
            heapB.push(nd, a);
            if (distF[a].isFinite && nd + distF[a] < mu) {
              mu = nd + distF[a];
              meet = a;
            }
          }
        }
      }
    }

    if (meet < 0) return RawPath.none;

    // Forward CH edges source -> meet.
    final fwdCh = <int>[];
    var cur = meet;
    while (cur != source) {
      final eid = peF[cur];
      if (eid < 0) return RawPath.none;
      fwdCh.add(eid);
      cur = pnF[cur];
    }
    final fwdOrdered = fwdCh.reversed.toList();

    // Backward CH edges meet -> target.
    final bwdCh = <int>[];
    cur = meet;
    while (cur != target) {
      final eid = peB[cur];
      if (eid < 0) return RawPath.none;
      bwdCh.add(eid);
      cur = pnB[cur];
    }

    // Unpack shortcuts into original routing edges, in path order.
    final origEdges = <int>[];
    for (final eid in fwdOrdered) {
      _unpack(eid, origEdges);
    }
    for (final eid in bwdCh) {
      _unpack(eid, origEdges);
    }

    final g = graph;
    final vertices = <int>[source];
    var distance = 0.0;
    for (final oid in origEdges) {
      distance += g.adjDist[oid];
      vertices.add(g.adjTarget[oid]);
    }

    return RawPath(
      vertices: vertices,
      edges: origEdges,
      distanceMeters: distance,
      timeSeconds: mu,
    );
  }

  void _unpack(int eid, List<int> out) {
    final e = _edges[eid];
    if (e.orig >= 0) {
      out.add(e.orig);
      return;
    }
    _unpack(e.childA, out);
    _unpack(e.childB, out);
  }

  /// Number of shortcuts created during preprocessing (diagnostic).
  int get shortcutCount {
    var c = 0;
    for (final e in _edges) {
      if (e.orig < 0) c++;
    }
    return c;
  }
}
