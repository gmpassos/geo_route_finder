# geo_route_finder

A high-performance, **data-source-agnostic**, **offline-first** routing engine
written in **pure Dart**. It computes routes between geographic coordinates over
road graphs that can come from any data source and be persisted in any storage
backend. OpenStreetMap is the bundled reference adapter — the engine itself is
not coupled to it.

Runs anywhere Dart runs (server, CLI, desktop, mobile, Flutter — any non-web
target, since it uses `dart:io` for files and networking). **No runtime
dependencies.**

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
import 'package:geo_route_finder/geo_route_finder.dart';

Future<void> main() async {
  final storage = LocalFileStorage(directory: './maps');

  // 1. Download an extract (resumable, cache-aware).
  final downloader = OsmDownloader(outputDirectory: './maps');
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

## License

[Apache License - Version 2.0][apache_license]

[apache_license]: https://www.apache.org/licenses/LICENSE-2.0.txt

