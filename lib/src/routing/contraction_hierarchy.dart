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

/// One end of a route, inside a private area.
///
/// The cheapest access-only path from a source out to each junction where its
/// private area meets the public network, or — walked the other way — from
/// each such junction in to a destination. Empty of everything but the
/// endpoint itself when that endpoint is on a public road, which is the
/// ordinary case.
class _PrivateWalk {
  final ContractionHierarchyRouter _router;

  /// The vertex the walk started from: the source, or the target.
  final int origin;

  /// Whether the walk followed edges outward from [origin] or backward to it.
  final bool outward;

  /// Cost in seconds between [origin] and each vertex reached.
  final cost = <int, double>{};

  /// The next vertex back toward [origin], per vertex reached.
  final step = <int, int>{};

  /// The routing edge taken to get there.
  final stepEdge = <int, int>{};

  _PrivateWalk(this._router, this.origin, this.outward);

  /// The routing edges from [origin] to [v], in travel order.
  ///
  /// Only meaningful on an outward walk, where [origin] is the source.
  List<int> edgesTo(int v) {
    if (!outward || v == origin) return const [];

    final reversed = <int>[];
    var cur = v;
    while (cur != origin) {
      final e = stepEdge[cur];
      final prev = step[cur];
      if (e == null || prev == null) return const [];
      reversed.add(e);
      cur = prev;
    }
    return reversed.reversed.toList();
  }

  /// The routing edges from [v] to [origin], in travel order.
  ///
  /// Only meaningful on a backward walk, where [origin] is the target.
  List<int> edgesFrom(int v) {
    if (outward || v == origin) return const [];

    final edges = <int>[];
    var cur = v;
    while (cur != origin) {
      final e = stepEdge[cur];
      final next = step[cur];
      if (e == null || next == null) return const [];
      edges.add(e);
      cur = next;
    }
    return edges;
  }

  @override
  String toString() =>
      '_PrivateWalk(${outward ? 'out of' : 'into'} $origin, '
      '${cost.length} vertices, router: ${_router.runtimeType})';
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
    super.profile,
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

    final adjCond = g.adjCond;

    for (var e = 0; e < g.edgeCount; e++) {
      // A conditionally restricted edge is kept out of the hierarchy entirely.
      //
      // With no clock every condition applies, so the edge is closed to every
      // query this hierarchy will answer — which makes omitting it exact, and
      // free at query time. Checking it *during* the search instead would be
      // unsound: contraction builds shortcuts that span vertices, so an edge
      // the check would reject can end up hidden inside a shortcut where no
      // query-time check can see it.
      //
      // When a clock arrives, the honest move is to fall back to
      // `_penalizedSearch` for a clocked query, exactly as `avoidTolls`
      // already does — the backward search has no clock to evaluate against.
      if (adjCond != null && adjCond[e] != 0) continue;

      // An access-only edge is kept out for the same reason and a sharper one.
      //
      // In the *middle* of a route such an edge is never usable, whoever is
      // asking — that is what access-only means — so a hierarchy over the
      // public network alone answers the middle exactly. Leaving them in would
      // be unsound rather than merely wasteful: contraction hides edges inside
      // shortcuts, and a shortcut spanning a parking aisle would carry it into
      // every query, where no check can see it.
      //
      // The ends are a different question, and `search` answers it separately.
      if (g.isAccessOnly(e)) continue;

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
  RawPath search(int source, int target, {DateTime? at}) {
    // A clocked query cannot use the hierarchy.
    //
    // It was built with conditional edges removed, which is exactly right for
    // the unclocked case — with no clock every condition applies, so those
    // edges are closed to every query the hierarchy will answer. But it leaves
    // no way to *re-admit* an edge a clock says is open: the edge is not in
    // the hierarchy to be found, and the backward search has no clock to
    // evaluate one against even if it were.
    //
    // So a clocked query runs over the graph itself. `avoidTolls` already
    // takes the same way out, for the same underlying reason: baked shortcuts
    // cannot be re-weighted after the fact.
    if (at != null) return searchOverGraph(source, target, at);

    // The private ends of the route, walked over access-only edges alone.
    //
    // The hierarchy covers the public network and nothing else, which is exact
    // for the middle of a route — an access-only edge is never usable there.
    // What it cannot answer is the run out of the car park the rider is
    // standing in, or the run into the driveway they are going to. Those are a
    // handful of edges each, so they are walked directly and stitched on.
    //
    // Both collapse to a single entry when the endpoint sits on a public road,
    // which is the ordinary case and costs nothing.
    final out = _walkPrivate(source, outward: true);
    final into = _walkPrivate(target, outward: false);

    // Source and destination inside the same private area — two flats in one
    // condominium — so the route never touches the public network at all and
    // the hierarchy has nothing to say about it.
    final inside = out.cost.containsKey(target)
        ? _pathThroughPrivate(source, target, out)
        : null;

    final middle = _searchPublic(source, target, out, into);

    if (middle == null) return inside ?? RawPath.none;
    if (inside == null) return middle;
    return middle.timeSeconds <= inside.timeSeconds ? middle : inside;
  }

  /// The shortest path between the public ends of two private areas, using the
  /// hierarchy, then stitched back onto the private runs at each end.
  RawPath? _searchPublic(
    int source,
    int target,
    _PrivateWalk out,
    _PrivateWalk into,
  ) {
    final n = graph.nodeCount;
    final distF = Float64List(n)..fillRange(0, n, double.infinity);
    final distB = Float64List(n)..fillRange(0, n, double.infinity);
    final peF = Int32List(n)..fillRange(0, n, -1);
    final pnF = Int32List(n)..fillRange(0, n, -1);
    final peB = Int32List(n)..fillRange(0, n, -1);
    final pnB = Int32List(n)..fillRange(0, n, -1);

    final heapF = MinHeap();
    final heapB = MinHeap();

    // Seeded from every way out of the source's private area, and every way
    // into the target's, each carrying the cost of getting there. With no
    // private area at either end these are just the source and the target.
    for (final entry in out.cost.entries) {
      distF[entry.key] = entry.value;
      heapF.push(entry.value, entry.key);
    }
    for (final entry in into.cost.entries) {
      distB[entry.key] = entry.value;
      heapB.push(entry.value, entry.key);
    }

    var mu = double.infinity;
    var meet = -1;
    var expanded = 0;

    // A seed that is already on both sides: the two private areas touch the
    // public network at the same junction.
    for (final entry in out.cost.entries) {
      final both = into.cost[entry.key];
      if (both != null && entry.value + both < mu) {
        mu = entry.value + both;
        meet = entry.key;
      }
    }

    while (heapF.isNotEmpty || heapB.isNotEmpty) {
      final fMin = heapF.isEmpty ? double.infinity : heapF.peekKey;
      final bMin = heapB.isEmpty ? double.infinity : heapB.peekKey;
      if (fMin >= mu && bMin >= mu) break;

      if (fMin <= bMin) {
        final d = heapF.peekKey;
        final u = heapF.pop();
        if (d > distF[u]) continue;
        expanded++;
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
        expanded++;
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

    reportExpandedNodes(expanded);
    if (meet < 0) return null;

    // Forward CH edges, back to whichever seed this path actually started
    // from — not necessarily the source, which may be inside a car park.
    final fwdCh = <int>[];
    var cur = meet;
    while (peF[cur] >= 0) {
      fwdCh.add(peF[cur]);
      cur = pnF[cur];
    }
    final entered = cur;
    final fwdOrdered = fwdCh.reversed.toList();

    // Backward CH edges, out to the seed on the far side.
    final bwdCh = <int>[];
    cur = meet;
    while (peB[cur] >= 0) {
      bwdCh.add(peB[cur]);
      cur = pnB[cur];
    }
    final left = cur;

    // Unpack shortcuts into original routing edges, in path order.
    final origEdges = <int>[
      ...out.edgesTo(entered),
      for (final eid in fwdOrdered) ...[]..addAll(_unpacked(eid)),
      for (final eid in bwdCh) ...[]..addAll(_unpacked(eid)),
      ...into.edgesFrom(left),
    ];

    return _rawPath(source, origEdges);
  }

  List<int> _unpacked(int eid) {
    final out = <int>[];
    _unpack(eid, out);
    return out;
  }

  /// A route wholly inside one private area.
  RawPath _pathThroughPrivate(int source, int target, _PrivateWalk out) =>
      _rawPath(source, out.edgesTo(target));

  /// Builds the answer from the routing edges it is made of.
  ///
  /// The totals are summed here rather than taken from the search, because a
  /// stitched path's cost is spread over three pieces and `mu` only knows
  /// about the middle one.
  RawPath _rawPath(int source, List<int> edges) {
    final g = graph;
    final vertices = <int>[source];
    var distance = 0.0;
    var time = 0.0;
    for (final oid in edges) {
      distance += g.adjDist[oid];
      time += g.adjTime[oid];
      vertices.add(g.adjTarget[oid]);
    }

    return RawPath(
      vertices: vertices,
      edges: edges,
      distanceMeters: distance,
      timeSeconds: time,
    );
  }

  /// Walks the private area around [from] over access-only edges alone.
  ///
  /// [outward] follows edges out of the area, for a source inside one;
  /// otherwise it follows them backwards, for a destination inside one. The
  /// walk stops at the first public junction — that is where the private area
  /// ends — but keeps it, because it is where the hierarchy takes over.
  ///
  /// An endpoint that is not inside a private area yields just itself at zero
  /// cost, which makes every caller below the ordinary case with no branch.
  _PrivateWalk _walkPrivate(int from, {required bool outward}) {
    final walk = _PrivateWalk(this, from, outward);
    if (!isInsidePrivateArea(from)) {
      walk.cost[from] = 0;
      return walk;
    }

    final g = graph;
    final heap = MinHeap();
    walk.cost[from] = 0;
    heap.push(0, from);

    while (heap.isNotEmpty) {
      final d = heap.peekKey;
      final u = heap.pop();
      if (d > (walk.cost[u] ?? double.infinity)) continue;
      // Only keep walking while inside; a public junction is the boundary.
      if (u != from && !isInsidePrivateArea(u)) continue;

      if (outward) {
        for (var e = g.adjOffset[u]; e < g.adjOffset[u + 1]; e++) {
          if (!g.isAccessOnly(e)) continue;
          final v = g.adjTarget[e];
          final nd = d + g.adjTime[e];
          if (nd < (walk.cost[v] ?? double.infinity)) {
            walk.cost[v] = nd;
            walk.step[v] = u;
            walk.stepEdge[v] = e;
            heap.push(nd, v);
          }
        }
      } else {
        for (final p in accessOnlyInto(u)) {
          final e = accessOnlyEdgeBetween(p, u);
          if (e < 0) continue;
          final nd = d + g.adjTime[e];
          if (nd < (walk.cost[p] ?? double.infinity)) {
            walk.cost[p] = nd;
            walk.step[p] = u;
            walk.stepEdge[p] = e;
            heap.push(nd, p);
          }
        }
      }
    }

    return walk;
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
