import 'dart:io';

import 'package:geo_route_finder/geo_route_finder.dart';

/// End-to-end example that needs no network access: it builds a small synthetic
/// road grid, stores it, and routes across it with both A* and Contraction
/// Hierarchies.
///
/// For the real OpenStreetMap flow, see the commented block at the bottom.
Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('grf_example_');
  final storage = LocalFileStorage(directory: dir.path);

  // Build a 10x10 lat/lon grid where neighbouring intersections are connected
  // by bidirectional 50 km/h roads.
  const n = 10;
  const step = 0.01; // ~1.1 km between intersections
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

  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if (c + 1 < n) edges.add(road(id(r, c), id(r, c + 1)));
      if (r + 1 < n) edges.add(road(id(r, c), id(r + 1, c)));
    }
  }

  await storage.saveGraph('grid', GeoGraph(nodes: nodes, edges: edges));
  print('Saved grid graph to ${dir.path}');

  final start = nodes.first.coordinate; // top-left
  final end = nodes.last.coordinate; // bottom-right

  final astar = AStarRouter(storage: storage, graphId: 'grid');
  final aRoute = await astar.findRoute(start, end);
  print('A*   : $aRoute');

  final ch = ContractionHierarchyRouter(storage: storage, graphId: 'grid');
  final chRoute = await ch.findRoute(start, end);
  print('CH   : $chRoute');
  print('CH shortcuts created: ${ch.shortcutCount}');

  dir.deleteSync(recursive: true);

  // ---------------------------------------------------------------------------
  // Real OpenStreetMap flow:
  //
  //   final maps = LocalFileStorage(directory: './maps');
  //   final downloader = OsmDownloader(outputDirectory: './maps');
  //   final pbf = await downloader.downloadRegion(
  //     region: 'south-america/brazil/sao-paulo',
  //     onProgress: (got, total) => stdout.write(
  //       '\r${(got / 1e6).toStringAsFixed(1)} MB'),
  //   );
  //   await OsmConverter().convert(
  //     inputFile: pbf, storage: maps, graphId: 'sao_paulo');
  //   final router = AStarRouter(storage: maps, graphId: 'sao_paulo');
  //   final route = await router.findRoute(
  //     const GeoCoordinate(lat: -23.5505, lon: -46.6333),
  //     const GeoCoordinate(lat: -23.9608, lon: -46.3336),
  //   );
  //   print(route);
  // ---------------------------------------------------------------------------
}
