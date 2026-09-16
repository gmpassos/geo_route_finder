import 'package:geo_osm_pbf/geo_osm_pbf.dart';

import '../graph/graph_builder.dart';
import '../graph/graph_compressor.dart';
import '../graph/turn_restriction_splitter.dart';
import '../model/geo_edge.dart';
import '../model/geo_graph.dart';
import '../model/geo_turn_restriction.dart';
import '../serialization/graph_serializer.dart';
import '../spatial/kd_tree.dart';
import '../storage/compiled_graph.dart';
import '../storage/geo_storage.dart';
import 'vehicle_profile.dart';

/// Converts an OpenStreetMap `.osm.pbf` extract into a routable graph.
///
/// Responsibilities:
///
/// * select routable ways by `highway` class and `access` for the chosen
///   [profile] (car, motorcycle, bicycle, …),
/// * apply one-way restrictions (`oneway`, implicit motorway/roundabout) when
///   the profile honors them,
/// * compute per-segment ground distance (haversine),
/// * infer speed limits from `maxspeed` or the profile's per-class defaults,
/// * flag toll segments (`toll`) so queries can avoid them,
/// * emit a normalized [GeoGraph], then optionally compile and store it.
///
/// Each [VehicleProfile] routes over a different network, so a converter
/// produces one graph per profile; store each under a profile-scoped graph id.
///
/// Parsing is a memory-bounded two-pass scan: ways first (to learn which node
/// ids are referenced), then nodes (keeping only referenced coordinates).
class OsmConverter {
  final OsmPbfParser parser;
  final GraphBuilder builder;
  final GraphCompressor compressor;

  /// Transport mode whose tag interpretation (routable classes, access, speed,
  /// one-way) drives the conversion. Defaults to [VehicleProfile.car].
  final VehicleProfile profile;

  /// Whether to compress the compiled graph before storing. Strongly
  /// recommended; reduces size and speeds up routing.
  final bool compress;

  /// Whether to count signalised junctions, so routing can prefer the way
  /// round them.
  ///
  /// A route through fifteen sets of lights is genuinely slower than one
  /// through three, and a router that cannot see them will keep choosing the
  /// straight run down the arterial over the quiet parallel street that is
  /// actually quicker. Counting them is what lets the cost say so — see
  /// `GraphBuilder.signalDelaySeconds`.
  ///
  /// The cost of `true` is decoding the node tag stream during the pass that
  /// already reads node coordinates. That stream is otherwise skipped whole,
  /// and it is mostly untagged shape points, so this is a real addition to
  /// build time — paid once per graph, never at query time.
  final bool readSignals;

  /// Whether to read turn restrictions, so a route is one a rider may legally
  /// follow.
  ///
  /// A left turn the sign forbids is not a longer route, it is a wrong one —
  /// and the rider finds out while sitting at the junction.
  ///
  /// The cost of `true` is decoding relations during the pass that already
  /// reads ways. Relations are a fraction of a percent of an extract's
  /// entities, so this is far cheaper than [readSignals]; it is a flag at all
  /// because a caller with no use for restrictions should not pay for them.
  final bool readTurnRestrictions;

  OsmConverter({
    this.parser = const OsmPbfParser(),
    this.builder = const GraphBuilder(),
    GraphCompressor? compressor,
    this.profile = VehicleProfile.car,
    this.compress = true,
    this.readSignals = true,
    this.readTurnRestrictions = true,
  }) : compressor = compressor ?? GraphCompressor();

  /// Why restrictions were dropped on the most recent [toGeoGraph], or null.
  ///
  /// Mirrors `GraphCompressor.lastStats`. Exposed because the skipped counts
  /// are the honest measure of how complete the answer is: a build reporting
  /// only what it accepted cannot be judged.
  TurnRestrictionStats? get lastRestrictionStats => _lastRestrictionStats;
  TurnRestrictionStats? _lastRestrictionStats;

  /// Whether a node's tags describe a junction that stops traffic.
  ///
  /// Traffic lights only, and that is narrower than what a map *draws*.
  /// `DeliverySchema` in `geo_tile_builder` also renders stop and give-way
  /// signs, because a driver wants to see them; they are left out of the cost
  /// because the graph carries a count rather than a per-class delay, and a
  /// stop sign is a few seconds against a light's tens. Folding them in at the
  /// same weight would say a street of stop signs costs as much as a street of
  /// lights, which is worse than saying nothing.
  ///
  /// A signalised pedestrian crossing is a set of lights and counts. An
  /// unsignalised one does not stop traffic and does not.
  static bool isSignalNode(Map<String, String> tags) {
    final highway = tags['highway'];

    if (highway == 'traffic_signals') return true;

    if (highway == 'crossing') {
      return tags['crossing'] == 'traffic_signals' ||
          tags['crossing:signals'] == 'yes';
    }

    return false;
  }

  /// Routable highway classes for the default car profile (after stripping any
  /// `_link` suffix). Retained for backward compatibility; prefer
  /// [VehicleProfile.routableHighways].
  static const Set<String> supportedHighways = VehicleProfile.motorHighways;

  /// Default car speeds in km/h per (normalized) highway class. Retained for
  /// backward compatibility; prefer [VehicleProfile.defaultSpeedKmh].
  static const Map<String, double> defaultSpeedKmh =
      VehicleProfile.motorSpeedKmh;

  /// Parses [inputFile] and returns the normalized (uncompiled) [GeoGraph].
  Future<GeoGraph> toGeoGraph(String inputFile) async {
    // Pass 1: ways. Keep routable ways and collect referenced node ids.
    //
    // Relations ride along on this pass rather than getting one of their own.
    // They are a fraction of a percent of an extract's entities, so collecting
    // every candidate unfiltered costs almost nothing — and filtering here
    // would be wrong anyway, because whether a restriction can be resolved
    // depends on ways this pass has not finished seeing.
    final keptWays = <GeoWay>[];
    final neededNodes = <int>{};
    final restrictionRelations = <GeoRelation>[];

    await parser.parse(
      inputFile,
      readNodes: false,
      readRelations: readTurnRestrictions,
      onWay: (way) {
        if (!_isRoutable(way)) return;
        keptWays.add(way);
        neededNodes.addAll(way.nodeIds);
      },
      onRelation: !readTurnRestrictions
          ? null
          : (relation) {
              // `startsWith` rather than equality: `type=restriction:bus` and
              // friends are the same shape with a mode attached.
              if (relation.type?.startsWith('restriction') ?? false) {
                restrictionRelations.add(relation);
              }
            },
    );

    // Pass 2: nodes. Keep only coordinates referenced by a kept way, and note
    // which of them are signalised junctions.
    //
    // `onTaggedNode` rides along with a pass that is already reading nodes, so
    // the extra work is decoding the tag stream rather than a third scan over
    // the extract — which is the cost [readSignals] exists to let a caller
    // decline.
    final coords = <int, GeoNode>{};
    final signalNodes = <int>{};

    await parser.parse(
      inputFile,
      readWays: false,
      onNode: (node) {
        if (neededNodes.contains(node.id)) coords[node.id] = node;
      },
      onTaggedNode: !readSignals
          ? null
          : (node) {
              // Only junctions this profile's network actually reaches. A
              // light on a street a car may not use is not a delay a car will
              // ever pay.
              if (!neededNodes.contains(node.id)) return;
              if (isSignalNode(node.tags)) signalNodes.add(node.id);
            },
    );

    // Assemble the generic graph: one edge per consecutive node pair.
    final edges = <GeoEdge>[];
    for (final way in keptWays) {
      final speed = _speedFor(way);
      final dir = _onewayOf(way);
      final tolls = _tollOf(way) ? 1 : 0;
      final ids = way.nodeIds;
      for (var i = 0; i + 1 < ids.length; i++) {
        final a = coords[ids[i]];
        final b = coords[ids[i + 1]];
        if (a == null || b == null) continue;
        final dist = haversineMeters(a.lat, a.lon, b.lat, b.lon);
        if (dist <= 0) continue;
        if (dir == _OneWay.backward) {
          edges.add(
            GeoEdge(
              sourceId: b.id,
              targetId: a.id,
              distanceMeters: dist,
              speedKmh: speed,
              oneWay: true,
              tolls: tolls,
            ),
          );
        } else {
          edges.add(
            GeoEdge(
              sourceId: a.id,
              targetId: b.id,
              distanceMeters: dist,
              speedKmh: speed,
              oneWay: dir == _OneWay.forward,
              tolls: tolls,
            ),
          );
        }
      }
    }

    final nodes = coords.values.toList();

    final restrictions = _resolveRestrictions(
      restrictionRelations,
      keptWays,
      coords,
    );

    return GeoGraph(
      nodes: nodes,
      edges: edges,
      // Narrowed to nodes that survived: a light referenced by a way whose
      // coordinates the extract does not contain is not a junction this graph
      // can route through.
      signalNodeIds: signalNodes.where(coords.containsKey).toSet(),
      turnRestrictions: restrictions,
    );
  }

  /// Turns `type=restriction` relations into from/via/to node triples.
  ///
  /// The relation names *ways*; routing needs the single segment on each side
  /// of the junction. That resolution is done here, against the ways this
  /// profile kept, because this is the only point where both the relation and
  /// the way geometry are in hand.
  ///
  /// Every rejection is counted rather than dropped quietly — see
  /// [TurnRestrictionStats]. A restriction the router does not honour is a
  /// route it may propose illegally, so the number that is *not* handled is
  /// the one worth reporting.
  List<GeoTurnRestriction> _resolveRestrictions(
    List<GeoRelation> relations,
    List<GeoWay> keptWays,
    Map<int, GeoNode> coords,
  ) {
    final waysById = {for (final w in keptWays) w.id: w};

    final out = <GeoTurnRestriction>[];
    final conditions = <String>{};

    var skippedViaWay = 0;
    var unresolvedMember = 0;
    var ambiguousMember = 0;
    var excepted = 0;

    for (final relation in relations) {
      final tags = relation.tags;

      // `except=psv;bicycle` lists the modes the sign does not apply to.
      // Honouring it matters: without it a bus lane's restrictions are applied
      // to bicycles, which systematically over-restricts the very profiles
      // that have the fewest alternatives.
      final except = tags['except'];
      if (except != null && _exceptedByProfile(except)) {
        excepted++;
        continue;
      }

      final kind = tags['restriction'] ?? tags['restriction:conditional'];
      if (kind == null) {
        unresolvedMember++;
        continue;
      }

      final isOnly = kind.trimLeft().startsWith('only');
      if (!isOnly && !kind.trimLeft().startsWith('no')) {
        unresolvedMember++;
        continue;
      }

      final via = relation.members
          .where((m) => m.role == 'via')
          .toList(growable: false);

      if (via.any((m) => m.type == GeoMemberType.way)) {
        skippedViaWay++;
        continue;
      }

      if (via.length != 1 || via.single.type != GeoMemberType.node) {
        unresolvedMember++;
        continue;
      }

      final viaNodeId = via.single.ref;
      if (!coords.containsKey(viaNodeId)) {
        unresolvedMember++;
        continue;
      }

      final from = _neighbourAcross(relation, 'from', viaNodeId, waysById);
      final to = _neighbourAcross(relation, 'to', viaNodeId, waysById);

      if (from == _memberUnresolved || to == _memberUnresolved) {
        unresolvedMember++;
        continue;
      }
      if (from == _memberAmbiguous || to == _memberAmbiguous) {
        ambiguousMember++;
        continue;
      }

      final condition = tags['restriction:conditional'];
      if (condition != null) conditions.add(condition);

      out.add(
        GeoTurnRestriction(
          fromNodeId: from,
          viaNodeId: viaNodeId,
          toNodeId: to,
          isOnly: isOnly,
          condition: condition,
        ),
      );
    }

    _lastRestrictionStats = TurnRestrictionStats(
      accepted: out.length,
      skippedViaWay: skippedViaWay,
      unresolvedMember: unresolvedMember,
      ambiguousMember: ambiguousMember,
      excepted: excepted,
      conditions: conditions.length,
    );

    return out;
  }

  /// Sentinel: the member names a way this graph does not carry.
  static const _memberUnresolved = -1;

  /// Sentinel: the way passes *through* the via node, so which of its two
  /// neighbours the restriction means is not decidable from the relation.
  static const _memberAmbiguous = -2;

  /// The node id one step along [role]'s way from [viaNodeId].
  ///
  /// A `from` way should end at the via node and a `to` way should start
  /// there, which makes the neighbouring node unambiguous. Real data mostly
  /// complies; where it does not — the way runs straight through the junction
  /// — both neighbours are candidates and the relation does not say which.
  ///
  /// Guessing there is worse than skipping. For a `no_*` restriction, banning
  /// both branches forbids a movement that is legal; for an `only_*`, allowing
  /// both permits one that is not. Either way the graph would state something
  /// the source never said.
  int _neighbourAcross(
    GeoRelation relation,
    String role,
    int viaNodeId,
    Map<int, GeoWay> waysById,
  ) {
    final members = relation.members.where(
      (m) => m.role == role && m.type == GeoMemberType.way,
    );

    for (final member in members) {
      final way = waysById[member.ref];
      if (way == null) continue;

      final ids = way.nodeIds;
      final at = ids.indexOf(viaNodeId);
      if (at < 0) continue;

      // Appears more than once: a loop through the junction, same problem.
      if (ids.indexOf(viaNodeId, at + 1) >= 0) return _memberAmbiguous;

      final first = at == 0;
      final last = at == ids.length - 1;

      if (last && !first) return ids[at - 1];
      if (first && !last) return ids[at + 1];

      // Interior: two candidates and nothing to choose between them.
      if (!first && !last) return _memberAmbiguous;

      // A way of one node, which is not geometry.
      return _memberUnresolved;
    }

    return _memberUnresolved;
  }

  /// Whether `except=` exempts this profile from a restriction.
  bool _exceptedByProfile(String except) {
    final listed = except
        .split(';')
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty);

    return listed.any(profile.restrictionExceptions.contains);
  }

  /// Compiles [inputFile] into a [CompiledGraph] (CSR + KD-tree + metadata).
  Future<CompiledGraph> compile(String inputFile) async {
    final geo = await toGeoGraph(inputFile);
    var routing = builder.build(geo);

    // Between the builder and the compressor, and it has to be both. The
    // builder resolves from/to to dense edge indices, which is the only
    // unambiguous way to name an approach; the compressor then merges that
    // approach into a chain and destroys its identity.
    routing = const TurnRestrictionSplitter().split(
      routing,
      geo.turnRestrictions,
    );

    if (compress) routing = compressor.compress(routing);
    final tree = KdTree.build(routing);
    final meta = GraphMeta(
      formatVersion: kGraphFormatVersion,
      nodeCount: routing.nodeCount,
      edgeCount: routing.edgeCount,
      graphChecksum: 0,
      indexChecksum: 0,
      createdAt: DateTime.now(),
    );
    return CompiledGraph(graph: routing, tree: tree, meta: meta);
  }

  /// Converts [inputFile] and stores the result under [graphId] in [storage],
  /// scoped to this converter's [profile] (so the same [graphId] can hold an
  /// independent graph per transport mode).
  ///
  /// When [storage] supports the compiled fast path, the compressed CSR + KD-tree
  /// are written directly; otherwise the generic [GeoGraph] is stored via
  /// [GeoStorage.saveGraph].
  Future<void> convert({
    required String inputFile,
    required GeoStorage storage,
    required String graphId,
  }) async {
    if (storage is CompiledGraphStorage) {
      final compiled = await compile(inputFile);
      await storage.saveCompiled(graphId, compiled, profile: profile);
    } else {
      await storage.saveGraph(
        graphId,
        await toGeoGraph(inputFile),
        profile: profile,
      );
    }
  }

  bool _isRoutable(GeoWay way) {
    final highway = way.tags['highway'];
    if (highway == null) return false;
    if (_normalizeHighway(highway) == null) return false;
    if (way.tags['area'] == 'yes') return false;
    if (!_accessAllowed(way)) return false;
    return way.nodeIds.length >= 2;
  }

  /// Resolves access for the profile: the most-specific access key present on
  /// the way decides. A value of `no`/`private` blocks; anything else (or the
  /// absence of every key) allows.
  bool _accessAllowed(GeoWay way) {
    for (final key in profile.accessKeys) {
      final v = way.tags[key];
      if (v == null) continue;
      return v != 'no' && v != 'private';
    }
    return true;
  }

  String? _normalizeHighway(String highway) {
    final base = highway.endsWith('_link')
        ? highway.substring(0, highway.length - 5)
        : highway;
    return profile.routableHighways.contains(base) ? base : null;
  }

  double _speedFor(GeoWay way) {
    final base = _normalizeHighway(way.tags['highway']!)!;
    final fallback = profile.defaultSpeedKmh[base] ?? 40;
    final speed = profile.ignoreWayMaxspeed
        ? fallback
        : (_parseMaxspeed(way.tags['maxspeed']) ?? fallback);
    return speed < profile.maxSpeedKmh ? speed : profile.maxSpeedKmh;
  }

  bool _tollOf(GeoWay way) {
    final v = way.tags['toll'];
    return v == 'yes' || v == 'true' || v == '1';
  }

  double? _parseMaxspeed(String? raw) {
    if (raw == null) return null;
    final s = raw.trim().toLowerCase();
    // Leading number, e.g. "50", "50 km/h", "30mph", "60kph".
    final m = RegExp(r'^(\d+(?:\.\d+)?)').firstMatch(s);
    if (m == null) return null; // non-numeric e.g. "RO:urban", "walk"
    final n = double.tryParse(m.group(1)!);
    if (n == null) return null;
    if (s.contains('mph')) return n * 1.609344;
    return n;
  }

  _OneWay _onewayOf(GeoWay way) {
    // A bicycle-specific one-way always applies (even when the profile ignores
    // motor-vehicle one-ways). When the profile does not honor general one-ways
    // and no bicycle-specific tag is present, the segment is bidirectional.
    final bike = way.tags['oneway:bicycle'];
    if (bike != null) {
      if (bike == 'yes' || bike == 'true' || bike == '1') {
        return _OneWay.forward;
      }
      if (bike == '-1' || bike == 'reverse') return _OneWay.backward;
      if (bike == 'no' || bike == 'false' || bike == '0') return _OneWay.none;
    }
    if (!profile.honorOneway) return _OneWay.none;

    final v = way.tags['oneway'];
    if (v == 'yes' || v == 'true' || v == '1') return _OneWay.forward;
    if (v == '-1' || v == 'reverse') return _OneWay.backward;
    if (v == 'no' || v == 'false' || v == '0') return _OneWay.none;
    // Implicit one-way: motorways and roundabouts.
    final highway = way.tags['highway'];
    if (highway == 'motorway' || highway == 'motorway_link') {
      return _OneWay.forward;
    }
    final junction = way.tags['junction'];
    if (junction == 'roundabout' || junction == 'circular') {
      return _OneWay.forward;
    }
    return _OneWay.none;
  }
}

enum _OneWay { none, forward, backward }
