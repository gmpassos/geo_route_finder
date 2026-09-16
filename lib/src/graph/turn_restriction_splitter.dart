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
    if (restrictions.isEmpty) {
      lastStats = const TurnRestrictionSplitStats();
      return g;
    }

    final vertexOf = <int, int>{};
    for (var v = 0; v < g.nodeCount; v++) {
      vertexOf[g.originalId[v]] = v;
    }

    // Group by the approach, not by the restriction. Several signs can govern
    // one approach — "no left turn" and "no U-turn" on the same arm — and they
    // have to be resolved together into a single permitted set.
    final byApproach = <(int via, int inEdge), List<GeoTurnRestriction>>{};
    var unresolved = 0;

    for (final r in restrictions) {
      final via = vertexOf[r.viaNodeId];
      final from = vertexOf[r.fromNodeId];
      final to = vertexOf[r.toNodeId];
      if (via == null || from == null || to == null) {
        // A node the profile's filtering removed. Counted rather than dropped
        // in silence: the restriction was read, resolved, and is not enforced,
        // which is the number a build report exists to state.
        unresolved++;
        continue;
      }

      final inEdge = _edgeBetween(g, from, via);
      if (inEdge < 0) {
        // The approach itself is not traversable — a one-way pointing the other
        // way, or a way this profile cannot use. The restriction is moot, but
        // it is still one that was read and not applied.
        unresolved++;
        continue;
      }

      byApproach.putIfAbsent((via, inEdge), () => []).add(r);
    }

    // One copy per (junction, approach), never shared between approaches even
    // when their permitted sets happen to match. A shared copy would have two
    // approaches and two exits, which is exactly the degree-2 shape the chain
    // compressor contracts — and contracting it splices the first approach to
    // the second's exit, fabricating a turn neither sign allowed.
    final copies = <_Copy>[];
    var applied = 0;
    var contradictory = 0;
    var inert = 0;

    for (final entry in byApproach.entries) {
      final (via, inEdge) = entry.key;

      final exits = g.adjOffset[via + 1] - g.adjOffset[via];
      final allowed = _permittedExits(g, via, entry.value, vertexOf);

      if (allowed == null) {
        // Two `only_*` signs with no exit in common, or a `no` and an `only`
        // naming the same one. The source contradicts itself and honouring it
        // would strand the approach entirely.
        //
        // Counted in restrictions rather than in copies, like every other
        // number here, so that a report adds up against what was read. One
        // approach can carry several signs, and saying "1 contradictory" for
        // three of them understates the data problem it is there to surface.
        contradictory += entry.value.length;
        continue;
      }

      // A copy that permits exactly what its parent does restricts nothing.
      //
      // It happens whenever a restriction's `to` matches no exit — a way this
      // profile filtered out, or a first segment the converter dropped — and
      // for an `only_*` it is doubly wasteful: the restriction has no effect
      // *and* the copy still costs a vertex, a duplicate of every exit edge,
      // and a pin that keeps the parent from ever compressing away.
      if (allowed.length == exits && !allowed.values.any((c) => c != null)) {
        inert += entry.value.length;
        continue;
      }

      applied += entry.value.length;
      copies.add(_Copy(via: via, inEdge: inEdge, allowed: allowed));
    }

    // Assigned on every path, including the ones that return early. It is
    // static, so a stale value from the previous build is not an absence — it
    // is a wrong number attributed to this one.
    lastStats = TurnRestrictionSplitStats(
      applied: applied,
      unresolved: unresolved,
      contradictory: contradictory,
      inert: inert,
      copies: copies.length,
      orphanedExits: copies.isEmpty ? const [] : _orphanedExits(g, copies),
    );

    if (copies.isEmpty) return g;

    return _rebuild(g, copies);
  }

  /// What the most recent [split] did, or null.
  ///
  /// Not on the instance by accident: the splitter is stateless and shared as
  /// a `const`, so this is deliberately the one mutable thing about it — the
  /// alternative is a return type nobody downstream wants to unwrap.
  static TurnRestrictionSplitStats? lastStats;

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

  /// Exits that no approach is permitted to take.
  ///
  /// A restriction removes a movement; between them, several can remove a
  /// *road*. When every way into a junction is restricted and none of the
  /// restrictions permits a particular way out, that exit is dead: no through
  /// route can enter it, only one that happens to start on the junction itself.
  ///
  /// The graph is right to refuse it — the source said so — which is exactly
  /// why this is worth reporting. A signed movement being unavailable is
  /// ordinary; a carriageway no vehicle may enter is almost always a mapping
  /// mistake, and the cheapest place to catch one is here, where the data has
  /// just been read, rather than from a rider watching the route take a detour.
  ///
  /// The classic shape is an `only_*` written where a `no_*` was meant:
  /// `only_left_turn` forbids everything it does not name, so one relation on
  /// the last unrestricted approach can sever a road that every other tag on it
  /// says runs straight through.
  ///
  /// **A clipped extract produces false positives.** Approaches outside the box
  /// are missing, so a junction can look wholly restricted when it is not.
  /// That is tolerable for something whose only effect is a line in a build
  /// report — and the reason this reports rather than repairs. Overriding the
  /// source here would mean inventing a movement no sign allows, which is the
  /// failure this package exists to prevent.
  List<OrphanedExit> _orphanedExits(RoutingGraph g, List<_Copy> copies) {
    // Per junction: which approaches a sign governs, and what they jointly
    // leave open. A conditionally forbidden exit counts as open — the edge is
    // still in the graph, and whether it may be used is a question for the
    // clock, not for this.
    final restricted = <int, Set<int>>{};
    final permitted = <int, Set<int>>{};
    for (final c in copies) {
      (restricted[c.via] ??= <int>{}).add(c.inEdge);
      (permitted[c.via] ??= <int>{}).addAll(c.allowed.keys);
    }

    // In-degree of just those junctions, in one pass over the edge array rather
    // than a scan per junction.
    final inDegree = {for (final via in restricted.keys) via: 0};
    for (var e = 0; e < g.adjTarget.length; e++) {
      final t = g.adjTarget[e];
      if (inDegree.containsKey(t)) inDegree[t] = inDegree[t]! + 1;
    }

    final found = <OrphanedExit>[];
    for (final via in restricted.keys) {
      // One unrestricted approach reaches every exit, so nothing here is
      // orphaned however severe the other signs are.
      if (restricted[via]!.length < inDegree[via]!) continue;

      final open = permitted[via]!;
      for (var e = g.adjOffset[via]; e < g.adjOffset[via + 1]; e++) {
        if (open.contains(e)) continue;
        found.add(
          OrphanedExit(
            viaNodeId: g.originalId[via],
            toNodeId: g.originalId[g.adjTarget[e]],
          ),
        );
      }
    }

    // Sorted so a build report reads the same twice, the way the rest of this
    // package's output does.
    found.sort((a, b) {
      final byVia = a.viaNodeId.compareTo(b.viaNodeId);
      return byVia != 0 ? byVia : a.toNodeId.compareTo(b.toNodeId);
    });
    return List.unmodifiable(found);
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

    /// A 1-based index into [conditions], saturating at the byte's ceiling.
    ///
    /// Past 255 distinct expressions the index would wrap, and a wrapped value
    /// is still in range — so one edge would lose its condition entirely and
    /// others would be judged against a different junction's timetable, with
    /// nothing to catch either. The overflow slot is a sentinel no parser can
    /// read, which is therefore always in force.
    int conditionIndex(String? condition) {
      if (condition == null) return 0;

      final at = conditions.indexOf(condition);
      if (at >= 0) return at + 1;

      if (conditions.length + 1 >= RoutingGraph.conditionOverflowIndex) {
        // Pad up to the sentinel slot so that index 255 has an entry behind it
        // — the table is 1-based, so the sentinel is the 255th element.
        while (conditions.length < RoutingGraph.conditionOverflowIndex) {
          conditions.add(RoutingGraph.overflowCondition);
        }
        return RoutingGraph.conditionOverflowIndex;
      }

      conditions.add(condition);
      return conditions.length;
    }

    final adjOffset = Int32List(total + 1);
    final adjTarget = <int>[];
    final adjTime = <double>[];
    final adjDist = <double>[];
    final adjToll = <int>[];
    final adjSignal = <int>[];
    final adjAccess = <int>[];
    final adjCond = <int>[];
    final geom = <double>[];
    final geomOffset = <int>[0];

    void copyEdge(int e, {int? target, String? condition}) {
      adjTarget.add(target ?? g.adjTarget[e]);
      adjTime.add(g.adjTime[e]);
      adjDist.add(g.adjDist[e]);
      adjToll.add(g.adjToll[e]);
      adjSignal.add(g.adjSignal[e]);
      adjAccess.add(g.adjAccess[e]);
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
      //
      // **`retarget` applies here too, and leaving it out was a real bug.** An
      // exit of this copy may itself be the approach of *another* restriction
      // — junctions in series, which a one-way grid with a `no_left_turn` on
      // consecutive blocks produces immediately. Without the retarget that
      // exit still points at the next junction's *original* vertex, so leaving
      // this junction hands the rider a clean entry into the next one and the
      // second sign is not enforced for anyone who came this way.
      for (var e = g.adjOffset[copy.via]; e < g.adjOffset[copy.via + 1]; e++) {
        if (!copy.allowed.containsKey(e)) continue;
        copyEdge(e, target: retarget[e], condition: copy.allowed[e]);
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
      adjAccess: Uint8List.fromList(adjAccess),
      geomCoords: Float64List.fromList(geom),
      geomOffset: Int32List.fromList(geomOffset),
      splitParent: splitParent,
      adjCond: adjCond.any((c) => c != 0) ? Uint8List.fromList(adjCond) : null,
      conditions: conditions,
    );
  }
}

/// What a [TurnRestrictionSplitter.split] actually did.
///
/// The counts that are *not* `applied` are the point. A restriction the graph
/// does not enforce is a turn the router may still propose, and until now
/// those two cases vanished without trace — `TurnRestrictionStats` even
/// declared a `contradictory` field that nothing ever assigned, so it read
/// zero on every build no matter what the data held.
/// Every count except [copies] is in *restrictions*, so that a build report adds
/// up against the number the reader handed over. One approach often carries
/// several signs, and counting approaches instead would report "1 contradictory"
/// for three unenforced restrictions.
class TurnRestrictionSplitStats {
  /// Restrictions the graph now enforces as topology.
  final int applied;

  /// Restrictions whose junction, approach or exit is not in this graph —
  /// filtered out by the profile, or on the far side of the extract's edge.
  final int unresolved;

  /// Restrictions on an approach whose signs cannot all be obeyed at once, so
  /// none of them were.
  final int contradictory;

  /// Restrictions that named an exit the junction does not have, so the copy
  /// would have permitted exactly what its parent does.
  final int inert;

  /// Junction copies made — one per (junction, restricted approach), which is
  /// the cost in vertices rather than a count of restrictions.
  final int copies;

  /// Ways left with no permitted entry, because every approach to their
  /// junction is restricted and none of the restrictions names them.
  ///
  /// Unlike every other field here these are *enforced* restrictions, not
  /// dropped ones — the graph is doing what the source asked. They are reported
  /// because the source asking for it is nearly always the mistake.
  final List<OrphanedExit> orphanedExits;

  const TurnRestrictionSplitStats({
    this.applied = 0,
    this.unresolved = 0,
    this.contradictory = 0,
    this.inert = 0,
    this.copies = 0,
    this.orphanedExits = const [],
  });

  @override
  String toString() =>
      'TurnRestrictionSplitStats($applied applied in $copies copies, '
      '$unresolved unresolved, $contradictory contradictory, $inert inert, '
      '${orphanedExits.length} orphaned)';
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
