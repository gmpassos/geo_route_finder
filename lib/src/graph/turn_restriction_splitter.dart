import 'dart:typed_data';

import '../model/geo_turn_restriction.dart';
import 'graph_types.dart';

/// Makes forbidden turns impossible to express, rather than expensive to take.
///
/// At a junction with a restriction, the approach that may not turn is
/// retargeted to a **copy** of the junction whose outgoing edges are the
/// permitted ones. The forbidden movement then has no edge at all.
///
/// **This is what keeps the routers untouched.** Dijkstra, A* and the
/// contraction hierarchy all keep one scalar cost per vertex, which cannot
/// express "you may not leave by Y if you arrived by X" — the cheapest way to
/// reach a junction may be the one approach that is forbidden onward, and a
/// search that has collapsed both approaches into a single label can no longer
/// tell them apart. Encoding the restriction in the shape of the graph sides
/// around that entirely: an illegal turn is not costly, it is absent. It also
/// means a CH shortcut can never bake one in, because the movement was never
/// there to be shortcut.
///
/// Only the junction is copied — never the approach edge, which is retargeted
/// in place — so the cost is a handful of vertices and edges per restricted
/// junction, and the compressor takes most of it straight back (see below).
///
/// Runs between `GraphBuilder` and `GraphCompressor`, and the order is
/// load-bearing:
///
/// * **After the builder**, because the builder needs unique OSM ids — its
///   node maps are keyed by them — and because by then the from/to ways are
///   resolved to dense directed edges, which is the only unambiguous way to
///   name "the approach". Splitting earlier would also drop the signal delay
///   already folded into the approach's travel time.
/// * **Before the compressor**, because compression destroys the identity of
///   the approach edge by merging it into a chain.
class TurnRestrictionSplitter {
  const TurnRestrictionSplitter();

  /// Returns [g] with restricted junctions split, or [g] itself when there is
  /// nothing to do.
  RoutingGraph split(RoutingGraph g, List<GeoTurnRestriction> restrictions) {
    if (restrictions.isEmpty) return g;

    final vertexOf = <int, int>{};
    for (var v = 0; v < g.nodeCount; v++) {
      vertexOf[g.originalId[v]] = v;
    }

    // Group by the approach, not by the restriction. Several signs can govern
    // one approach — "no left turn" and "no U-turn" on the same arm — and they
    // have to be resolved together into a single permitted set.
    final byApproach = <(int via, int inEdge), List<GeoTurnRestriction>>{};

    for (final r in restrictions) {
      final via = vertexOf[r.viaNodeId];
      final from = vertexOf[r.fromNodeId];
      final to = vertexOf[r.toNodeId];
      if (via == null || from == null || to == null) continue;

      final inEdge = _edgeBetween(g, from, via);
      if (inEdge < 0) continue;

      byApproach.putIfAbsent((via, inEdge), () => []).add(r);
    }

    if (byApproach.isEmpty) return g;

    // One copy per (junction, approach), never shared between approaches even
    // when their permitted sets happen to match. A shared copy would have two
    // approaches and two exits, which is exactly the degree-2 shape the chain
    // compressor contracts — and contracting it splices the first approach to
    // the second's exit, fabricating a turn neither sign allowed.
    final copies = <_Copy>[];

    for (final entry in byApproach.entries) {
      final (via, inEdge) = entry.key;

      final allowed = _permittedExits(g, via, entry.value, vertexOf);
      if (allowed == null) continue;

      copies.add(_Copy(via: via, inEdge: inEdge, allowed: allowed));
    }

    if (copies.isEmpty) return g;

    return _rebuild(g, copies);
  }

  /// Which of [via]'s outgoing edges an approach may still take, or null when
  /// the restrictions leave nothing to keep.
  ///
  /// `no_*` removes the named exits; `only_*` keeps only them. Several of each
  /// intersect, which is how one approach carrying both kinds resolves. An
  /// empty result means the source contradicts itself — two `only_*` signs
  /// with no exit in common — and honouring it would strand the approach, so
  /// the caller drops the restriction instead.
  Map<int, String?>? _permittedExits(
    RoutingGraph g,
    int via,
    List<GeoTurnRestriction> restrictions,
    Map<int, int> vertexOf,
  ) {
    final exits = <int>[
      for (var e = g.adjOffset[via]; e < g.adjOffset[via + 1]; e++) e,
    ];

    // Value is the condition that forbids the exit, or null for "permitted
    // outright". A conditionally forbidden exit stays in the graph — the same
    // graph has to answer for both states — and carries its condition.
    final permitted = <int, String?>{for (final e in exits) e: null};

    for (final r in restrictions) {
      final to = vertexOf[r.toNodeId];
      if (to == null) continue;

      final named = exits.where((e) => g.adjTarget[e] == to).toSet();
      if (named.isEmpty) continue;

      final banned = r.isOnly ? exits.where((e) => !named.contains(e)) : named;

      for (final e in banned) {
        if (!permitted.containsKey(e)) continue;

        if (r.condition == null) {
          permitted.remove(e);
        } else if (permitted[e] == null) {
          // Only the first condition on an exit is recorded. A second one is
          // vanishingly rare, and "restricted under either" would need a
          // boolean expression the format does not carry — so the earlier one
          // stands, and the exit stays restricted at least as often as it
          // should be.
          permitted[e] = r.condition;
        }
      }
    }

    return permitted.isEmpty ? null : permitted;
  }

  /// The directed edge `from -> to`, or `-1`.
  int _edgeBetween(RoutingGraph g, int from, int to) {
    for (var e = g.adjOffset[from]; e < g.adjOffset[from + 1]; e++) {
      if (g.adjTarget[e] == to) return e;
    }
    return -1;
  }

  /// Rebuilds the CSR with one extra vertex per copy.
  ///
  /// Copies are appended after every real vertex, so a parent always has a
  /// lower index than its copies. The compressor's renumbering relies on that
  /// to keep the parent as the first of each run of equal [originalId]s.
  RoutingGraph _rebuild(RoutingGraph g, List<_Copy> copies) {
    final n = g.nodeCount;
    final total = n + copies.length;

    final lat = Float64List(total)..setRange(0, n, g.lat);
    final lon = Float64List(total)..setRange(0, n, g.lon);
    final originalId = Int64List(total)..setRange(0, n, g.originalId);
    final splitParent = Int32List(total)..fillRange(0, total, -1);

    // Where each approach now lands. Applied while copying the edge arrays,
    // so the approach edge keeps its weights, geometry and signal count — it
    // is the same road, arriving at the same place under a different name.
    final retarget = <int, int>{};

    for (var i = 0; i < copies.length; i++) {
      final copy = copies[i];
      final v = n + i;

      lat[v] = g.lat[copy.via];
      lon[v] = g.lon[copy.via];
      // Deliberately the parent's id. These are the same junction, and a
      // synthetic id would break the round trip back to OSM for the sake of
      // uniqueness nothing needs.
      originalId[v] = g.originalId[copy.via];
      splitParent[v] = copy.via;

      retarget[copy.inEdge] = v;
    }

    final conditions = <String>[];
    int conditionIndex(String? condition) {
      if (condition == null) return 0;
      final at = conditions.indexOf(condition);
      return (at >= 0 ? at : (conditions..add(condition)).length - 1) + 1;
    }

    final adjOffset = Int32List(total + 1);
    final adjTarget = <int>[];
    final adjTime = <double>[];
    final adjDist = <double>[];
    final adjToll = <int>[];
    final adjSignal = <int>[];
    final adjCond = <int>[];
    final geom = <double>[];
    final geomOffset = <int>[0];

    void copyEdge(int e, {int? target, String? condition}) {
      adjTarget.add(target ?? g.adjTarget[e]);
      adjTime.add(g.adjTime[e]);
      adjDist.add(g.adjDist[e]);
      adjToll.add(g.adjToll[e]);
      adjSignal.add(g.adjSignal[e]);
      adjCond.add(conditionIndex(condition ?? g.conditionOf(e)));

      for (var p = g.geomOffset[e]; p < g.geomOffset[e + 1]; p++) {
        geom
          ..add(g.geomCoords[p * 2])
          ..add(g.geomCoords[p * 2 + 1]);
      }
      geomOffset.add(geom.length ~/ 2);
    }

    for (var v = 0; v < n; v++) {
      adjOffset[v] = adjTarget.length;
      for (var e = g.adjOffset[v]; e < g.adjOffset[v + 1]; e++) {
        copyEdge(e, target: retarget[e]);
      }
    }

    for (var i = 0; i < copies.length; i++) {
      final copy = copies[i];
      adjOffset[n + i] = adjTarget.length;

      // The copy's exits are the parent's, minus what the sign removed. A
      // conditionally forbidden one is kept and flagged.
      for (var e = g.adjOffset[copy.via]; e < g.adjOffset[copy.via + 1]; e++) {
        if (!copy.allowed.containsKey(e)) continue;
        copyEdge(e, condition: copy.allowed[e]);
      }
    }

    adjOffset[total] = adjTarget.length;

    return RoutingGraph(
      lat: lat,
      lon: lon,
      originalId: originalId,
      adjOffset: adjOffset,
      adjTarget: Int32List.fromList(adjTarget),
      adjTime: Float64List.fromList(adjTime),
      adjDist: Float64List.fromList(adjDist),
      adjToll: Uint8List.fromList(adjToll),
      adjSignal: Uint8List.fromList(adjSignal),
      geomCoords: Float64List.fromList(geom),
      geomOffset: Int32List.fromList(geomOffset),
      splitParent: splitParent,
      adjCond: adjCond.any((c) => c != 0) ? Uint8List.fromList(adjCond) : null,
      conditions: conditions,
    );
  }
}

/// One junction copy: the approach that lands on it, and the exits it keeps.
class _Copy {
  final int via;
  final int inEdge;

  /// Exit edge index of the *parent* to the condition restricting it, or null
  /// when it is permitted outright. Absent means removed.
  final Map<int, String?> allowed;

  _Copy({required this.via, required this.inEdge, required this.allowed});
}
