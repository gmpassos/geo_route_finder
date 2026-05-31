import 'dart:io';

import 'package:geo_route_finder/geo_route_finder.dart';

/// Examples for `geo_route_finder`.
///
/// Two flows are bundled:
///
/// * **Synthetic grid** (default) — needs no network access. Builds a small
///   road grid, stores it, and routes across it with Dijkstra, A* and
///   Contraction Hierarchies, comparing the work each algorithm does and
///   listing alternative routes.
///
/// * **Real OpenStreetMap** — downloads a region extract, converts it into a
///   routing graph and routes across it. Because it hits the network it only
///   runs when you ask for it:
///
///   ```sh
///   dart run example/geo_route_finder_example.dart \
///     south-america/brazil/sao-paulo \
///     -23.5505 -46.6333 -23.9608 -46.3336
///   ```
///
///   The four trailing numbers (start lat/lon, end lat/lon) are optional and
///   default to São Paulo → Santos.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    await runGridExample();
    print(
      '\nTip: pass an OSM region to route over real roads, e.g.\n'
      '  dart run example/geo_route_finder_example.dart '
      'south-america/brazil/sao-paulo',
    );
  } else {
    await runOsmExample(args);
  }
}

/// Offline demo over a synthetic 10x10 road grid.
Future<void> runGridExample() async {
  final dir = Directory.systemTemp.createTempSync('grf_example_');
  try {
    final storage = LocalFileStorage(directory: dir.path);
    final graph = buildGridGraph();
    await storage.saveGraph('grid', graph);
    print('Saved ${graph.nodes.length}-node grid graph to ${dir.path}');

    // Routers take coordinates, not node ids: each endpoint is snapped to the
    // nearest graph node via the spatial index before the search runs.
    final start = graph.nodes.first.coordinate; // top-left corner
    final end = graph.nodes.last.coordinate; // bottom-right corner

    // The same query answered by three exact shortest-path algorithms. They are
    // guaranteed to return the same optimal distance; what differs is how many
    // nodes each expands to get there (lower = less work):
    //
    //   * Dijkstra explores outward blindly in every direction.
    //   * A* adds a straight-line distance heuristic that pulls the search
    //     toward the destination, so it usually expands fewer nodes.
    //   * Contraction Hierarchies pays a one-off preprocessing cost to insert
    //     "shortcut" edges, after which queries skip over most of the graph.
    final dijkstra = DijkstraRouter(storage: storage, graphId: 'grid');
    final dRoute = await dijkstra.findRoute(start, end);
    printRoute('Dijkstra', dRoute, dijkstra.lastExpandedNodes);

    final astar = AStarRouter(storage: storage, graphId: 'grid');
    final aRoute = await astar.findRoute(start, end);
    printRoute('A*', aRoute, astar.lastExpandedNodes);

    final ch = ContractionHierarchyRouter(storage: storage, graphId: 'grid');
    final chRoute = await ch.findRoute(start, end);
    printRoute(
      'CH',
      chRoute,
      ch.lastExpandedNodes,
      extra: '${ch.shortcutCount} shortcuts',
    );

    // Cross-check the three agree on distance (within floating-point noise).
    // Asserts are only active under `dart run --enable-asserts` / in tests.
    assert((dRoute.distanceMeters - aRoute.distanceMeters).abs() < 1e-6);
    assert((aRoute.distanceMeters - chRoute.distanceMeters).abs() < 1e-6);

    // Ask for more than one route. `findRoutes` returns the fastest route first,
    // then up to `maxRoutes - 1` alternatives, each found by penalising edges
    // already used so the detours are genuinely different roads rather than
    // trivial variations. `maxExtraRatio: 0.5` drops any alternative more than
    // 50% longer than the optimum.
    print('\nAlternative routes:');
    final routes = await astar.findRoutes(
      start,
      end,
      maxRoutes: 3,
      maxExtraRatio: 0.5,
    );
    for (final (i, r) in routes.indexed) {
      final label = i == 0 ? 'fastest' : 'alt #$i';
      print(
        '  $label: ${(r.distanceMeters / 1000).toStringAsFixed(2)} km, '
        '${r.duration}',
      );
    }
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Live demo: downloads an OSM region, converts it and routes across it.
///
/// [args] is `<region> [startLat startLon endLat endLon]`.
Future<void> runOsmExample(List<String> args) async {
  final region = args.first;
  // Endpoints default to São Paulo (Sé) → Santos; override by passing four
  // numbers after the region: startLat startLon endLat endLon.
  var start = const GeoCoordinate(lat: -23.5505, lon: -46.6333);
  var end = const GeoCoordinate(lat: -23.9608, lon: -46.3336);
  if (args.length >= 5) {
    start = GeoCoordinate(
      lat: double.parse(args[1]),
      lon: double.parse(args[2]),
    );
    end = GeoCoordinate(lat: double.parse(args[3]), lon: double.parse(args[4]));
  }

  // Everything is written under ./maps: the downloaded extract and the compiled
  // graph both live here, so re-runs skip the download and conversion.
  final storage = LocalFileStorage(directory: './maps');

  // 1. Download the region extract. The download is resumable and revalidated
  //    with the server (ETag), so a second run reuses the cached file.
  final downloader = OsmDownloader(outputDirectory: Directory('./maps'));
  print('Downloading "$region" …');
  final pbf = await downloader.downloadRegion(
    region: region,
    onProgress: (received, total, url) {
      final mb = (received / 1e6).toStringAsFixed(1);
      final pct = total != null
          ? ' (${(received / total * 100).round()}%)'
          : '';
      stdout.write('\r  $mb MB$pct');
    },
  );
  stdout.writeln();

  // 2. Convert the raw OSM PBF into a routing graph: select routable ways,
  //    infer speeds, build the topology and spatial index, then store it
  //    compressed under `graphId`. Each vehicle profile routes over a different
  //    network (a bicycle uses cycleways but not motorways, ignores car one-way
  //    rules, …), so we build and store one graph per profile.
  final base = region.split('/').last; // e.g. "sao-paulo"
  for (final profile in [VehicleProfile.car, VehicleProfile.bicycle]) {
    final graphId = '${base}_${profile.name}';
    print('Converting to graph "$graphId" (${profile.name}) …');
    await OsmConverter(
      profile: profile,
    ).convert(inputFile: pbf, storage: storage, graphId: graphId);
  }

  // 3. Route across each stored graph, exactly as in the grid demo above.
  final carRouter = AStarRouter(storage: storage, graphId: '${base}_car');
  printRoute(
    'car',
    await carRouter.findRoute(start, end),
    carRouter.lastExpandedNodes,
  );

  // The same car query, but avoiding toll roads. Toll segments are heavily
  // penalized, so a toll-free route is preferred; a tolled route is still
  // returned when the destination cannot be reached any other way.
  printRoute(
    'car (no toll)',
    await carRouter.findRoute(start, end, avoidTolls: true),
    carRouter.lastExpandedNodes,
  );

  final bikeRouter = AStarRouter(storage: storage, graphId: '${base}_bicycle');
  printRoute(
    'bicycle',
    await bikeRouter.findRoute(start, end),
    bikeRouter.lastExpandedNodes,
  );
}

/// Builds a 10x10 lat/lon grid of intersections joined by 50 km/h roads,
/// standing in for a real road network so the demo needs no data download.
GeoGraph buildGridGraph() {
  const n = 10; // grid is n x n intersections
  const step = 0.01; // ~1.1 km between neighbours in latitude/longitude
  final nodes = <GeoNode>[];
  final edges = <GeoEdge>[];
  // Map a (row, column) cell to a unique, contiguous node id.
  int id(int r, int c) => r * n + c;
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      nodes.add(
        GeoNode(id: id(r, c), lat: -23.5 + r * step, lon: -46.7 + c * step),
      );
    }
  }
  // A road between two nodes. `oneWay` defaults to false, so the graph builder
  // automatically materialises the reverse direction too.
  GeoEdge road(int a, int b) {
    final na = nodes[a];
    final nb = nodes[b];
    return GeoEdge(
      sourceId: a,
      targetId: b,
      distanceMeters: na.coordinate.distanceTo(nb.coordinate),
      speedKmh: 50,
    );
  }

  // Connect each intersection to its right and bottom neighbour; together these
  // cover every grid edge exactly once.
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if (c + 1 < n) edges.add(road(id(r, c), id(r, c + 1)));
      if (r + 1 < n) edges.add(road(id(r, c), id(r + 1, c)));
    }
  }
  return GeoGraph(nodes: nodes, edges: edges);
}

/// Prints a route as `distance, duration, points (work done)`, where "work" is
/// how many graph nodes the router expanded — the comparable cost metric.
void printRoute(String name, GeoRoute route, int expanded, {String? extra}) {
  final tail = extra != null ? ', $extra' : '';
  print(
    '${name.padRight(8)}: ${(route.distanceMeters / 1000).toStringAsFixed(2)} km, '
    '${route.duration}, ${route.geometry.length} points '
    '(expanded $expanded nodes$tail)',
  );
}
