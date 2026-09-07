## 1.1.0

- **OSM acquisition and decoding moved to the new `geo_osm_pbf` package**, so
  that the same extract can also feed `geo_tile_builder` without either package
  depending on the other. **Not a breaking change:** the moved types are
  re-exported from `package:geo_route_finder/geo_route_finder.dart` and are the
  same types, not wrappers, so existing imports are unaffected. The full test
  suite passes unchanged.
  - Moved: `OsmPbfParser`, `GeoCoordinate` (with `haversineMeters`,
    `equirectSquared`, `earthRadiusMeters`), `GeoNode`, `GeoWay`,
    `OsmDownloader`, `OsmDownloadSource`, `OsmMirroredSource`,
    `OsmSourceResolver`, `OsmDownloadSourceRegistry`, `MirrorBenchmark`,
    `OsmPatternDownloadSource`, and the Geofabrik, OSM France, BBBike and
    Planet sources.
  - Stayed: everything routing-specific — `GeoEdge`, `GeoGraph`, `GeoRoute`,
    `GeoDataSource`, `OsmConverter`, `OsmDataSource`, `VehicleProfile`,
    `Crc32`, and all of `graph/`, `spatial/`, `routing/`, `storage/`.
  - `geo_osm_pbf` additionally decodes node tags, relations, sparse nodes and
    the `OSMHeader` block, none of which this package reads. Turn restrictions
    are now available to build on.
- Dependencies:
  - Added `geo_osm_pbf: ^1.0.0`.
- Tests:
  - `osm_download_source_test.dart` and `osm_downloader_resume_test.dart` moved
    to `geo_osm_pbf` with the code they cover. Every remaining test is
    untouched.

## 1.0.3

- Routing:
  - `GraphRouteFinder`:
    - Added `profile` field to select transport mode for routing.
    - Updated graph loading and existence checks to use `(graphId, profile)` keys.
  - `AStarRouter`, `DijkstraRouter`, `ContractionHierarchyRouter`:
    - Added optional `profile` parameter to constructors.
- OSM Conversion:
  - `OsmConverter`:
    - Updated `convert` method to store graphs scoped by `profile`.
- Storage:
  - `GeoStorage` interface:
    - Added `profile` parameter to all methods to key graphs by `(id, profile)`.
  - `CompiledGraphStorage` interface:
    - Added `profile` parameter to `saveCompiled` and `loadCompiled`.
  - `LocalFileStorage`:
    - Updated file naming to include `profile` (e.g. `<id>_<profile>.graph`).
    - Updated all storage methods to accept and use `profile`.
    - Added checksum verification and metadata recording per profile.
- Example:
  - `geo_route_finder_example.dart`:
    - Simplified graph id usage to exclude profile suffix.
    - Updated router instantiation to pass `profile` explicitly.
- Model:
  - `GraphMeta`:
    - Added `profileName` field to record transport mode.
- Tests:
  - `serialization_test.dart`:
    - Updated tests to verify profile-specific storage keys and independent graphs per profile.
  - `support.dart`:
    - Updated `MemoryStorage` to key graphs by `(id, profile)`.
- Misc:
  - Added `profile` parameter propagation throughout routing and storage layers to support multiple transport modes stored under the same graph id.

## 1.0.2

- Multi-profile routing (car, motorcycle, bicycle) and toll avoidance.

- `lib/src/osm/vehicle_profile.dart` (new):
  - Added `VehicleProfile`, controlling how source tags (routable highway classes,
    access, speed, one-way) are interpreted per transport mode.
  - Bundled `VehicleProfile.car`, `.motorcycle`, and `.bicycle`. Bicycles route over
    cycleways/paths, exclude motorways/trunks, ignore motor-vehicle one-way rules
    (but honor `oneway:bicycle`), and travel at a flat, capped speed.

- `lib/src/osm/osm_converter.dart`:
  - `OsmConverter` now takes a `profile` (default `VehicleProfile.car`); routability,
    access, speed and one-way interpretation are driven by it. Build one graph per
    profile and store each under a profile-scoped id.
  - Parses the `toll` tag and flags toll segments on emitted edges.

- `lib/src/routing/route_finder.dart`:
  - Added `avoidTolls` to `findRoute`/`findRoutes`. Toll roads are heavily (but
    finitely) penalized via the uniform penalty-Dijkstra, so toll-free routes are
    preferred while a tolled route is still returned when unavoidable.

- `lib/src/model/geo_route.dart`:
  - `GeoRoute` now reports `tollCount` (toll sections crossed) and a `hasTolls`
    getter, so the `findRoutes` result can be filtered into toll-free vs tolled
    routes.
  - `GeoRoute` implements `Comparable`: sorting a route list orders it by fewest
    tolls first, then shortest distance (not-found routes sort last).

- Model/graph/serialization:
  - `GeoEdge.tolls` (an `int` count, with a `hasToll` getter), `RoutingGraph.adjToll`
    (+ `isToll`/`tollsOf`), propagated through `GraphBuilder` and `GraphCompressor`
    (a merged chain sums the toll counts of its collapsed segments).
  - **Breaking on-disk change:** graph format bumped to v2 to store `adjToll`; graphs
    written by earlier versions must be rebuilt.

## 1.0.1

- Added `bump.sh` script to run `dart_bump` with API key and arguments.

- `example/geo_route_finder_example.dart`:
  - Added comprehensive example supporting two flows:
    - Synthetic 10x10 grid routing demo with Dijkstra, A*, and Contraction Hierarchies.
    - Real OpenStreetMap routing demo triggered by command-line arguments.
  - Added detailed printing of route distances, durations, and expanded nodes.
  - Added `buildGridGraph` helper to create synthetic grid graph.
  - Improved example structure and output formatting.

- `lib/src/graph/graph_builder.dart`:
  - Rewrote `GraphBuilder` to use flat primitive arrays and stable sorting for deterministic CSR graph building.
  - Added efficient geometry resolution and edge permutation sorting by source, target, and distance.
  - Removed object allocations for edges and coordinates during build.

- `lib/src/osm/osm_downloader.dart`:
  - Added deterministic, collision-free file naming for downloaded OSM regions based on region and source id.
  - Improved download caching and file naming logic.

- `lib/src/routing/astar_router.dart`:
  - Added tracking and reporting of expanded nodes count during A* search.

- `lib/src/routing/contraction_hierarchy.dart`:
  - Added tracking and reporting of expanded nodes count during bidirectional CH search.

- `lib/src/routing/dijkstra_router.dart`:
  - Added tracking and reporting of expanded nodes count during Dijkstra search.

- `lib/src/routing/route_finder.dart`:
  - Added `findRoutes` method to compute multiple alternative routes with parameters:
    - `maxRoutes`, `maxExtraRatio`, `maxExtraMeters`, `maxSharing`.
  - Implemented iterative penalty-based alternative route search using Dijkstra on penalized edge weights.
  - Added `lastExpandedNodes` property reporting number of expanded vertices in last search.
  - Added internal `_penalizedSearch` method for alternative route discovery.
  - Added route building from raw paths with geometry stitching.
  - Added graph compression on generic load path to reduce degree-2 chains.

- `lib/src/spatial/kd_tree.dart`:
  - Precompute projected vertex coordinates in meters for faster KD-tree build and queries.
  - Use cached projected coordinates in comparisons and distance calculations.

- `test/osm_route_finder_test.dart`:
  - Updated test step numbering to reflect added load step.
  - Added output of nodes analyzed during routing.
  - Improved test output formatting.

- `test/routing_test.dart`:
  - Added comprehensive tests exercising all three router algorithms (Dijkstra, A*, CH) across generic and compiled storage backends.
  - Verified identical optimal distances and durations across algorithms and backends.
  - Tested route geometry continuity and correctness.
  - Tested reporting of expanded nodes count.
  - Added tests for alternative routes with parameters and distinctness.
  - Tested unreachable targets and one-way restrictions across all algorithms.
  - Verified graph compression behavior and equivalence of compressed vs uncompressed compiled graphs.
  - Verified equivalence of generic and compiled load paths routing between surviving vertices.

## 1.0.0

- Pluggable OSM download-source architecture:
  - New `OsmDownloadSource` abstraction (region identifier -> downloadable URL)
    with built-in `GeofabrikSource`, `OsmFranceSource`, `BBBikeSource` and
    `PlanetSource` providers.
  - `OsmDownloadSourceRegistry` selects the best provider by priority, supports
    custom registration and enable/disable, automatic fallback, and optional
    mirror benchmarking (HEAD latency + throughput, cached) via `MirrorBenchmark`.
  - `OsmDownloader` is now fully source-agnostic: it resolves regions through an
    injected `OsmSourceResolver` (defaults to a registry of all built-ins) and
    falls back across candidates on failure. The Geofabrik-specific `baseUrl`
    constructor argument has been removed in favor of pluggable sources.

## 0.0.1

- Initial version.
