/// One movement a vehicle may not make at a junction.
///
/// OSM records these as relations — `type=restriction`, with members roled
/// `from`, `via` and `to` — and they are the difference between a route that
/// is merely short and one a rider can legally follow. A left turn the sign
/// forbids is not a detour, it is a route the rider discovers is wrong while
/// sitting at the junction.
///
/// Held as three OSM node ids rather than as edges, because that is the only
/// form that survives the journey from the extract to a compiled graph: edge
/// indices are assigned by [GraphBuilder] and reassigned again by
/// [GraphCompressor], while node ids are the one identifier both ends agree
/// on. `TurnRestrictionSplitter` resolves them to edges at the single moment
/// both the ids and the dense indices exist.
class GeoTurnRestriction {
  /// The last node of the `from` way before [viaNodeId] — so `from → via` names
  /// a directed edge without needing the way itself.
  final int fromNodeId;

  /// The junction the restriction applies at.
  final int viaNodeId;

  /// The first node of the `to` way after [viaNodeId].
  final int toNodeId;

  /// Whether this is an `only_*` restriction rather than a `no_*` one.
  ///
  /// The two are opposites and the difference is not cosmetic: `no_left_turn`
  /// removes one movement, `only_straight_on` removes every movement *except*
  /// one. Getting it backwards produces a graph that forbids exactly what it
  /// should allow, which is why it is a boolean on the record rather than
  /// something inferred later from the tag.
  final bool isOnly;

  /// The raw `restriction:conditional` expression, or null when the
  /// restriction always applies.
  ///
  /// Kept as written — `Mo-Fr 07:00-09:00` and the rest — because a condition
  /// cannot be resolved at build time. The same graph has to answer both
  /// "restricted now" and "not restricted now", so this survives into the
  /// compiled graph and is evaluated against the clock a query supplies.
  final String? condition;

  const GeoTurnRestriction({
    required this.fromNodeId,
    required this.viaNodeId,
    required this.toNodeId,
    required this.isOnly,
    this.condition,
  });

  /// Whether this restriction depends on the time of day.
  bool get isConditional => condition != null;

  /// A U-turn: the movement returns the way it came.
  ///
  /// Needs no special handling anywhere — the `to` is simply the reverse of
  /// the `from`, and the ordinary rules remove it. Worth naming because it is
  /// invisible in the code that implements it, and because it is the one
  /// restriction type this package honours *only* where OSM says so, rather
  /// than forbidding U-turns generally.
  bool get isUTurn => fromNodeId == toNodeId;

  @override
  String toString() =>
      'GeoTurnRestriction(${isOnly ? 'only' : 'no'} '
      '$fromNodeId -> $viaNodeId -> $toNodeId'
      '${condition == null ? '' : ' @ $condition'})';
}

/// A road no vehicle may legally enter.
///
/// Every approach to the junction is governed by a restriction, and none of
/// them permits this way out — so no through route can take it, and the only
/// journeys that use it are ones starting on the junction itself.
///
/// Named by OSM node ids rather than by way, because ids are what survives into
/// the graph, and because the pair is what someone needs to find the place in
/// an editor: [viaNodeId] is the junction, [toNodeId] the first node along the
/// exit nothing may reach.
///
/// **A clipped extract produces false positives.** Approaches outside the box
/// are absent, so a junction can look wholly restricted when it is not. That is
/// acceptable for something whose only effect is a line in a build report, and
/// it is the reason this is reported rather than repaired — overriding the
/// source would mean inventing a movement no sign allows.
class OrphanedExit {
  /// The junction, as an OSM node id.
  final int viaNodeId;

  /// The first node along the unreachable exit, as an OSM node id.
  final int toNodeId;

  const OrphanedExit({required this.viaNodeId, required this.toNodeId});

  @override
  bool operator ==(Object other) =>
      other is OrphanedExit &&
      other.viaNodeId == viaNodeId &&
      other.toNodeId == toNodeId;

  @override
  int get hashCode => Object.hash(viaNodeId, toNodeId);

  @override
  String toString() => 'node $viaNodeId has no permitted entry to $toNodeId';
}

/// Why turn restrictions were dropped while reading an extract.
///
/// Every counter here is a restriction that exists in the source and is *not*
/// being honoured, so the totals are the honest measure of how complete the
/// answer is. A build that reports thousands accepted and thousands skipped is
/// telling you something a build that reports only the accepted number cannot.
class TurnRestrictionStats {
  /// Resolved to a from/via/to triple and carried into the graph.
  final int accepted;

  /// `via` was a way rather than a node.
  ///
  /// The other shape of restriction, used where a divided road forces traffic
  /// through a short connector. Out of scope for now, and counted rather than
  /// silently ignored so the decision can be revisited against a real number.
  final int skippedViaWay;

  /// A `from`, `via` or `to` member this graph does not contain — a way the
  /// profile cannot use, or geometry outside the extract.
  final int unresolvedMember;

  /// The `from` or `to` way passes *through* the via node rather than ending
  /// at it, so which segment the restriction names is ambiguous.
  final int ambiguousMember;

  /// Several `only_*` restrictions on one approach with no movement in common.
  /// The source contradicts itself; honouring it would strand the approach.
  final int contradictory;

  /// `except=` named this profile, so the restriction does not apply to it.
  final int excepted;

  /// Distinct `restriction:conditional` expressions kept.
  final int conditions;

  /// Roads that ended up with no permitted entry at all.
  ///
  /// The odd one out here, and deliberately so: these restrictions *were*
  /// honoured. Between them they leave a way that no through route can enter,
  /// which is a legitimate thing to map — a service road reached only from a
  /// forecourt — and far more often a mistake, an `only_*` written where a
  /// `no_*` was meant. It sits beside the skipped counters because it belongs
  /// to the same question: what in this extract should someone look at.
  ///
  /// See [OrphanedExit] for the caveat about clipped extracts.
  final List<OrphanedExit> orphanedExits;

  const TurnRestrictionStats({
    this.accepted = 0,
    this.skippedViaWay = 0,
    this.unresolvedMember = 0,
    this.ambiguousMember = 0,
    this.contradictory = 0,
    this.excepted = 0,
    this.conditions = 0,
    this.orphanedExits = const [],
  });

  /// Restrictions seen in the source and not honoured.
  int get skipped =>
      skippedViaWay +
      unresolvedMember +
      ambiguousMember +
      contradictory +
      excepted;

  @override
  String toString() =>
      'TurnRestrictionStats($accepted accepted, $skipped skipped: '
      '$skippedViaWay via-way, $unresolvedMember unresolved, '
      '$ambiguousMember ambiguous, $contradictory contradictory, '
      '$excepted excepted; $conditions conditional'
      '${orphanedExits.isEmpty ? '' : '; '
                '${orphanedExits.length} orphaned exits'})';
}
