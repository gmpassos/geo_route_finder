import 'package:geo_osm_pbf/geo_osm_pbf.dart';

import '../graph/graph_builder.dart';
import '../graph/graph_compressor.dart';
import '../model/geo_edge.dart';
import '../model/geo_graph.dart';
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

  OsmConverter({
    this.parser = const OsmPbfParser(),
    this.builder = const GraphBuilder(),
    GraphCompressor? compressor,
    this.profile = VehicleProfile.car,
    this.compress = true,
    this.readSignals = true,
  }) : compressor = compressor ?? GraphCompressor();

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
    final keptWays = <GeoWay>[];
    final neededNodes = <int>{};
    await parser.parse(
      inputFile,
      readNodes: false,
      onWay: (way) {
        if (!_isRoutable(way)) return;
        keptWays.add(way);
        neededNodes.addAll(way.nodeIds);
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

    return GeoGraph(
      nodes: nodes,
      edges: edges,
      // Narrowed to nodes that survived: a light referenced by a way whose
      // coordinates the extract does not contain is not a junction this graph
      // can route through.
      signalNodeIds: signalNodes.where(coords.containsKey).toSet(),
    );
  }

  /// Compiles [inputFile] into a [CompiledGraph] (CSR + KD-tree + metadata).
  Future<CompiledGraph> compile(String inputFile) async {
    final geo = await toGeoGraph(inputFile);
    var routing = builder.build(geo);
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
