import 'dart:io';

import 'package:geo_route_finder/geo_route_finder.dart';

/// Synthetic routing benchmark. Builds an `n x n` grid (configurable via the
/// first CLI argument, default 200 → 40,000 nodes / ~160k directed edges),
/// compiles it, and measures load, nearest-node, and per-router query times.
///
/// Run with: `dart run benchmark/route_benchmark.dart [gridSize]`.
Future<void> main(List<String> args) async {
  final n = args.isNotEmpty ? int.parse(args.first) : 200;
  const step = 0.001; // ~111 m spacing

  final dir = Directory.systemTemp.createTempSync('grf_bench_');
  final storage = LocalFileStorage(directory: dir.path);

  stdout.writeln('Building ${n}x$n grid (${n * n} nodes)...');
  final buildSw = Stopwatch()..start();
  final nodes = <GeoNode>[];
  final edges = <GeoEdge>[];
  int id(int r, int c) => r * n + c;
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      nodes.add(
        GeoNode(id: id(r, c), lat: -23.5 + r * step, lon: -46.7 + c * step),
      );
    }
  }
  GeoEdge road(int a, int b) => GeoEdge(
    sourceId: a,
    targetId: b,
    distanceMeters: nodes[a].coordinate.distanceTo(nodes[b].coordinate),
    speedKmh: 50,
  );
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if (c + 1 < n) edges.add(road(id(r, c), id(r, c + 1)));
      if (r + 1 < n) edges.add(road(id(r, c), id(r + 1, c)));
    }
  }
  buildSw.stop();
  stdout.writeln('  graph assembled in ${buildSw.elapsedMilliseconds} ms');

  final saveSw = Stopwatch()..start();
  await storage.saveGraph('bench', GeoGraph(nodes: nodes, edges: edges));
  saveSw.stop();
  final graphFile = File('${dir.path}/bench.graph');
  stdout.writeln(
    '  compiled + saved in ${saveSw.elapsedMilliseconds} ms '
    '(${(graphFile.lengthSync() / 1e6).toStringAsFixed(1)} MB on disk)',
  );

  // Load time.
  final loadSw = Stopwatch()..start();
  final compiled = await storage.loadCompiled('bench');
  loadSw.stop();
  stdout.writeln('Load: ${loadSw.elapsedMilliseconds} ms');

  // Nearest-node search.
  final tree = compiled!.tree;
  const probes = 100000;
  final nnSw = Stopwatch()..start();
  for (var i = 0; i < probes; i++) {
    tree.findNearest(-23.5 + (i % n) * step, -46.7 + (i % n) * step);
  }
  nnSw.stop();
  stdout.writeln(
    'Nearest-node: ${(nnSw.elapsedMicroseconds / probes).toStringAsFixed(3)} us/query',
  );

  final start = const GeoCoordinate(lat: -23.5, lon: -46.7);
  final end = GeoCoordinate(
    lat: -23.5 + (n - 1) * step,
    lon: -46.7 + (n - 1) * step,
  );

  await _bench(
    'A*',
    AStarRouter(storage: storage, graphId: 'bench'),
    start,
    end,
  );
  await _bench(
    'Dijkstra',
    DijkstraRouter(storage: storage, graphId: 'bench'),
    start,
    end,
  );
  await _benchCh(storage, start, end);

  dir.deleteSync(recursive: true);
}

Future<void> _bench(
  String name,
  GraphRouteFinder router,
  GeoCoordinate start,
  GeoCoordinate end,
) async {
  // Warm up (loads + prepares).
  await router.findRoute(start, end);
  const runs = 20;
  final sw = Stopwatch()..start();
  late GeoRoute route;
  for (var i = 0; i < runs; i++) {
    route = await router.findRoute(start, end);
  }
  sw.stop();
  stdout.writeln(
    '$name: ${(sw.elapsedMicroseconds / runs / 1000).toStringAsFixed(2)} ms/query '
    '(${(route.distanceMeters / 1000).toStringAsFixed(1)} km)',
  );
}

Future<void> _benchCh(
  GeoStorage storage,
  GeoCoordinate start,
  GeoCoordinate end,
) async {
  final ch = ContractionHierarchyRouter(storage: storage, graphId: 'bench');
  final prepSw = Stopwatch()..start();
  await ch.findRoute(start, end); // triggers preprocessing
  prepSw.stop();
  stdout.writeln(
    'CH preprocessing + first query: ${prepSw.elapsedMilliseconds} ms '
    '(${ch.shortcutCount} shortcuts)',
  );
  await _bench('CH', ch, start, end);
}
