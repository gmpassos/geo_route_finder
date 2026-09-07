# geo_route_finder

[![pub package](https://img.shields.io/pub/v/geo_route_finder.svg?logo=dart&logoColor=00b9fc)](https://pub.dev/packages/geo_route_finder)
[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![Dart CI](https://github.com/gmpassos/geo_route_finder/actions/workflows/dart.yml/badge.svg?branch=master)](https://github.com/gmpassos/geo_route_finder/actions/workflows/dart.yml)
[![GitHub Tag](https://img.shields.io/github/v/tag/gmpassos/geo_route_finder?logo=git&logoColor=white)](https://github.com/gmpassos/geo_route_finder/releases)
[![New Commits](https://img.shields.io/github/commits-since/gmpassos/geo_route_finder/latest?logo=git&logoColor=white)](https://github.com/gmpassos/geo_route_finder/network)
[![Last Commits](https://img.shields.io/github/last-commit/gmpassos/geo_route_finder?logo=git&logoColor=white)](https://github.com/gmpassos/geo_route_finder/commits/master)
[![Pull Requests](https://img.shields.io/github/issues-pr/gmpassos/geo_route_finder?logo=github&logoColor=white)](https://github.com/gmpassos/geo_route_finder/pulls)
[![Code size](https://img.shields.io/github/languages/code-size/gmpassos/geo_route_finder?logo=github&logoColor=white)](https://github.com/gmpassos/geo_route_finder)
[![License](https://img.shields.io/github/license/gmpassos/geo_route_finder?logo=open-source-initiative&logoColor=green)](https://github.com/gmpassos/geo_route_finder/blob/master/LICENSE)

A high-performance, **data-source-agnostic**, **offline-first** routing engine
written in **pure Dart**. It computes routes between geographic coordinates over
road graphs that can come from any data source and be persisted in any storage
backend. OpenStreetMap is the bundled reference adapter — the engine itself is
not coupled to it.

Runs anywhere Dart runs (server, CLI, desktop, mobile, Flutter — any non-web
target, since it uses `dart:io` for files and networking).

OpenStreetMap acquisition and decoding live in the sibling package
[`geo_osm_pbf`][osm_pbf], which is shared with [`geo_tile_builder`][tiler] so
that one downloaded extract yields both a routing graph and the map tiles it is
drawn on. Its types — `OsmPbfParser`, `GeoCoordinate`, `GeoNode`, `GeoWay`,
`OsmDownloader` and the download sources — are **re-exported here**, so they are
imported from this library exactly as before.

[osm_pbf]: https://pub.dev/packages/geo_osm_pbf
[tiler]: https://pub.dev/packages/geo_tile_builder

## API Documentation

See the [API Documentation][api_doc] for a full list of functions, classes and extensions.

[api_doc]: https://pub.dev/documentation/geo_route_finder/latest/

## Features

- **Data-source agnostic.** Implement `GeoDataSource` to plug in OSM, HERE,
  TomTom, or a bespoke dataset. Routing code only ever sees the normalized model.
- **Storage agnostic.** Implement `GeoStorage` to persist graphs anywhere. A
  compact, versioned, checksummed `LocalFileStorage` is included.
- **Three routers, one API.** `AStarRouter`, `DijkstraRouter` and
  `ContractionHierarchyRouter` are interchangeable behind `RouteFinder`.
- **Memory efficient.** Graphs are stored as flat, primitive CSR arrays and
  loaded zero-copy. Degree-2 chain compression typically removes 80–95% of
  vertices while preserving exact geometry.
- **Fast spatial lookup.** A balanced, serializable KD-tree gives sub-millisecond
  nearest-node search on city graphs.
- **Offline first.** Download once, compile once, route forever — no network at
  query time.

## Architecture

```
geo_osm_pbf  (download, stream-decode .osm.pbf)
     │
     ▼
GeoDataSource  ──►  GeoGraph  ──►  GraphBuilder  ──►  RoutingGraph (CSR)
 (OSM, HERE…)      (normalized)                      │
                                                     ├─► GraphCompressor (shrink)
                                                     ├─► KdTree (spatial index)
                                                     └─► GraphSerializer ──► GeoStorage
                                                                               │
RouteFinder (A* / Dijkstra / CH)  ◄────────────────── loadCompiled  ◄─────────┘
```

The routing engine operates **only** on the generic model — no routing code
depends on OSM (or any vendor) structures.

## Getting started

```yaml
dependencies:
  geo_route_finder: ^0.1.0
```

## Usage

### Build and route from OpenStreetMap

```dart
import 'dart:io';

import 'package:geo_route_finder/geo_route_finder.dart';

Future<void> main() async {
  final storage = LocalFileStorage(directory: './maps');

  // 1. Download an extract (resumable, cache-aware).
  final downloader = OsmDownloader(outputDirectory: Directory('./maps'));
  final pbf = await downloader.downloadRegion(
    region: 'south-america/brazil/sao-paulo',
    onProgress: (got, total, url) =>
        print('$url: ${(got / 1e6).toStringAsFixed(1)} MB'),
  );

  // 2. Compile it into fast, compressed storage.
  await OsmConverter().convert(
    inputFile: pbf,
    storage: storage,
    graphId: 'sao_paulo',
  );

  // 3. Route.
  final router = AStarRouter(storage: storage, graphId: 'sao_paulo');
  final route = await router.findRoute(
    const GeoCoordinate(lat: -23.5505, lon: -46.6333),
    const GeoCoordinate(lat: -23.9608, lon: -46.3336),
  );

  print(route.distanceMeters);
  print(route.duration);
  print(route.geometry.length);
}
```

### Switch routers without changing anything else

```dart
// Drop-in replacement; identical API and results.
final router = ContractionHierarchyRouter(storage: storage, graphId: 'sao_paulo');
```

### Pluggable download sources (auto provider & mirror selection)

`OsmDownloader` is source-agnostic: it never contains provider-specific URL
logic. Region → URL mapping lives behind `OsmDownloadSource` implementations,
selected by an `OsmDownloadSourceRegistry`. Built-in providers: **Geofabrik**,
**OSM France**, **BBBike** and **OpenStreetMap Planet**.

```dart
// Registry preloaded with all built-in providers, in priority order.
final registry = OsmDownloadSourceRegistry.withDefaults(benchmarkByDefault: true);

// Add a private/enterprise mirror at the highest priority.
registry.register(
  GeofabrikSource(baseUrls: ['https://maps.corp.example/geofabrik/']),
  priority: 0,
);
registry.setEnabled('planet', false); // opt out of the whole-planet fallback

// The downloader just gets a region; the registry finds a provider, benchmarks
// mirrors (HEAD latency + throughput, cached), and falls back on failure.
final downloader = OsmDownloader(sourceResolver: registry);
final pbf = await downloader.downloadRegion(
  region: 'south-america/brazil/santa-catarina',
);
```

Implement `OsmDownloadSource` (or `OsmMirroredSource`) to add new providers,
cloud buckets, `.osm.bz2` dumps or local mirrors — no downloader changes.

### Plug in a custom data source

```dart
class MyDataSource implements GeoDataSource {
  @override
  Future<GeoGraph> loadGraph() async =>
      GeoGraph(nodes: [...], edges: [...]);
}

final graph = await MyDataSource().loadGraph();
await storage.saveGraph('custom', graph);
```

### Plug in a custom storage backend

```dart
class MyStorage implements GeoStorage {
  @override
  Future<void> saveGraph(String id, GeoGraph graph) async { /* ... */ }
  @override
  Future<GeoGraph?> loadGraph(String id) async { /* ... */ }
  @override
  Future<bool> exists(String id) async { /* ... */ }
  @override
  Future<void> delete(String id) async { /* ... */ }
}
```

Backends may additionally implement `CompiledGraphStorage` to persist the
compiled CSR + KD-tree directly (the fast path used by `LocalFileStorage`);
routers feature-detect it and fall back to the generic API otherwise.

## How it works

### Graph compression

A road between two intersections is digitised as many degree-2 vertices that only
describe its curvature. The compressor collapses each such chain into a single
edge whose weight is the sum of its segments, keeping the removed vertices as the
edge's geometry. Disconnected fragments below a threshold are dropped. Routing
then runs on a graph an order of magnitude smaller, while returned routes still
trace the exact road shape.

### Routers

- **Dijkstra** — exact baseline, `O(E log V)` with a binary heap.
- **A\*** — Dijkstra guided by an admissible haversine/​max-speed heuristic;
  same optimal cost, far fewer expansions. Recommended default.
- **Contraction Hierarchies** — optional preprocessing (node contraction +
  shortcuts) enabling bidirectional search that touches a tiny fraction of the
  graph for the fastest queries.

### Storage format

Three files per graph id: `.graph` (CSR arrays), `.index` (KD-tree), `.meta`
(JSON metadata with CRC-32 checksums). The binary layout is 8-byte aligned so the
arrays load as zero-copy views over the file bytes.

## Performance targets

City-scale dataset: `< 500 MB` storage, `< 1 s` load, `< 1 ms` nearest-node
search, `< 50 ms` A\* routing, `< 10 ms` with Contraction Hierarchies. Regional
datasets with millions of nodes/edges remain practical on desktop and server
hardware.

## Running the example, tests and benchmark

```sh
dart run example/geo_route_finder_example.dart
dart test
dart run benchmark/route_benchmark.dart
```

## Source

The official source code is [hosted @ GitHub][github_repo]:

- https://github.com/gmpassos/geo_route_finder

[github_repo]: https://github.com/gmpassos/geo_route_finder

# Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

# Contribution

Any help from the open-source community is always welcome and needed:

- Found an issue?
    - Please fill a bug report with details.
- Wish a feature?
    - Open a feature request with use cases.
- Are you using and liking the project?
    - Promote the project: create an article, do a post or make a donation.
- Are you a developer?
    - Fix a bug and send a pull request.
    - Implement a new feature.
    - Improve the Unit Tests.
- Have you already helped in any way?
    - **Many thanks from me, the contributors and everybody that uses this project!**

*If you donate 1 hour of your time, you can contribute a lot,
because others will do the same, just be part and start with your 1 hour.*

[tracker]: https://github.com/gmpassos/geo_route_finder/issues

# Author

Graciliano M. Passos: [gmpassos@GitHub][github].

[github]: https://github.com/gmpassos

## License

[Apache License - Version 2.0][apache_license]

[apache_license]: https://www.apache.org/licenses/LICENSE-2.0.txt
