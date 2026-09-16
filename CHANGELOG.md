## 1.4.0

- **A driveway is somewhere to arrive, not somewhere to cut through.** A car
  park that saves thirty metres was a legal shortcut, because nothing told the
  router otherwise. New `WayAccess` distinguishes three answers where there
  were two: usable by anyone, usable only to reach something on it, and not
  usable at all.

  A vertex counts as *inside* a private area when every edge leaving it may
  only be used for access — the junction where a driveway meets the street is
  not one, which is exactly where the private area ends. A route may drive out
  of the area it starts in and into the one it is going to, and use no such
  edge anywhere else.

  "A run of access-only edges at each end" sounds like the same rule and is
  not: a route starting on a street beside a car park can open with a run
  straight across it and still satisfy that wording. Keying on where the
  endpoints *are* is what closes it.

- **`service=` is read at last.** It decided nothing before: a driveway, a
  parking aisle, an alley, a fire lane, a drive-through queue and a bus-only
  road were one bucket at 20 km/h, every one of them a through-route.

  Now `driveway` and `parking_aisle` are access-only at 10 km/h — 20 was a
  fiction, and the fiction is what made cutting through a car park look cheap.
  `alley` stays a through-route at 15, because it is often *the* delivery
  access behind a row of shops. `drive-through`, `emergency_access`, `bus` and
  `slipway` are not roads at all.

- **`access=` recognised two values and now reads the rest.** `destination` —
  the tag that literally means no through traffic — was read as a plain yes,
  and so were `customers`, `delivery`, `permit`, `agricultural` and
  `forestry`. The first four are access-only now; the last two close a way to
  motor vehicles only, because a scooter is not a tractor.

  Where the class and the access value disagree the stricter wins, an explicit
  `yes` may loosen a category default, and nothing reopens an excluded
  subtype: `access=yes` on a fire lane is still a fire lane. A value none of
  the tables name is read as *no opinion* rather than as a restriction —
  treating the unknown as restrictive would let one typo quietly demote an
  arterial to an approach road.

- **Barriers and gates stop a route.** They are node tags on a way's vertices
  and nothing read them, so a bollard, a locked gate and a fire barrier were
  plain vertices that every route drove straight through. That is not a slower
  route; it is a rider arriving at something they cannot pass.

  A gate takes its default from the road it sits on — a property boundary on a
  service road or a track, a feature that usually stands open on a public
  street. Most mappers leave a passable gate untagged and put `access=private`
  on the shut ones, so blocking every bare gate would cut public streets on a
  guess and passing every bare gate would route through condominiums.

  Bollards, blocks and bus traps stop a car and let a bicycle past, which is
  their whole purpose. An unrecognised barrier stops everyone — the opposite
  of how an unreadable access value is treated, and deliberately: an unknown
  `barrier=` is a mapper saying a physical thing stands in the road.

  Where one blocks, the way is severed and the node becomes **two vertices at
  one coordinate**, one per side. Nothing passes through, and both sides still
  route right up to it — which for a delivery is usually the address itself.

- **Tracks join the motor network as approaches**, with a speed from their
  `tracktype`: `grade1` 25 km/h down to `grade5` 5, and an unsurveyed one
  assumed rough at 10. A rural address on one is reachable now; no route
  crosses one to save time. Bicycles treat a track as the ordinary minor way
  it is for them.

- **A bicycle no longer rides over every pavement.** `footway`, `pedestrian`
  and `bridleway` were routable at 8 km/h with no check at all; they need
  `bicycle=yes|designated` now. The same shape of bug as ignoring `service=`:
  a tag that decides the answer was never read.

- **Graph format v4 → v5**, and **every pack must be rebuilt**. `adjAccess`
  joins `adjToll` and `adjSignal`, one byte per directed edge.

  Refusing a v4 graph is the point rather than a formality. A v4 graph was
  built before any of the above was read, so its edges are not merely
  unflagged — a permit-only car park is in there as a 20 km/h public road, and
  reading one as v5 would say every way in the city is open, confidently.

  Unlike a turn restriction, this could not become topology. A forbidden turn
  is forbidden for everyone always, so deleting the edge states it exactly;
  whether a driveway may be used depends on where the route starts and ends,
  which is not known until someone asks.

- **`ContractionHierarchyRouter` keeps its hierarchy.** Access-only edges are
  left out of it entirely, which is exact rather than a compromise: in the
  *middle* of a route such an edge is never usable, whoever is asking, so a
  hierarchy over the public network answers the middle exactly. Leaving them
  in would have been unsound, not merely wasteful — contraction hides edges
  inside shortcuts, and a shortcut spanning a parking aisle would be carried
  into every query where no check could see it.

  The ends are a different question, so the query walks the private area
  around the source and around the destination separately — a handful of edges
  each — seeds the bidirectional search from every junction where those areas
  meet the public network, and stitches the three pieces back together. A
  route wholly inside one private area, two flats in the same condominium,
  never touches the hierarchy at all.

  A clocked query still falls back to the plain search, as it did before: the
  backward half of a bidirectional search has no clock to evaluate against.

## 1.3.0

- **Turn restrictions are honoured, so a route is one a rider may legally
  follow.** A left turn the sign forbids is not a longer route, it is a wrong
  one — and the rider finds out while sitting at the junction. `OsmConverter`
  now reads `type=restriction` relations, which it previously skipped
  entirely: it passed no `onRelation`, so the data never entered the pipeline.

- **A forbidden turn is absent, not expensive.** At a restricted junction the
  approach that may not turn is retargeted to a *copy* of the junction whose
  exits are the permitted ones. The movement then has no edge at all.

  This is what keeps the routers untouched. Dijkstra, A* and the contraction
  hierarchy each hold one scalar cost per vertex, which cannot express "you may
  not leave by Y if you arrived by X" — the cheapest way to reach a junction
  may be the very approach that is forbidden onward, and a search that has
  collapsed both approaches into one label can no longer tell them apart.
  Encoding the restriction in the *shape* of the graph sidesteps that, and it
  means a CH shortcut can never bake in an illegal turn, because the movement
  was never there to shortcut.

  The compressor takes most of the cost straight back: an `only_*` copy has one
  way in and one out, so the chain walk merges approach and exit into a single
  edge that says "arriving this way, you continue that way" — which *is* the
  restriction, at no cost in vertices.

- **What is refused is as deliberate as what is accepted**, and every refusal
  is counted in `TurnRestrictionStats` rather than dropped quietly. A
  restriction not honoured is a route that may be proposed illegally, so the
  number that is *not* handled is the one worth reporting. Via-way restrictions
  (the other shape, where a divided road forces traffic through a connector)
  are out of scope and counted. A `from`/`to` way running *through* the via
  node is ambiguous and skipped: for a `no_*` banning both branches forbids a
  legal movement, for an `only_*` allowing both permits an illegal one, and the
  relation does not say which is meant.

- **`except=` is honoured**, via `VehicleProfile.restrictionExceptions`.
  Ignoring it applies bus-lane restrictions to bicycles — over-restriction that
  lands hardest on the mode with the fewest alternatives.

- **U-turns change only where OSM says so.** `no_u_turn` needs no special
  handling: the `to` is the reverse of the `from`, so the ordinary rule removes
  it. U-turns everywhere else behave exactly as before.

- **Conditional restrictions are evaluated against a clock.**
  `findRoute`/`findRoutes` take an optional `at`, and a turn barred only on
  weekday mornings is open on a Sunday. A `restriction:conditional` cannot be
  topology — one graph has to answer both "restricted now" and "not restricted
  now" — so the edge stays and `adjCond` flags it.

  **With no clock, every condition applies**, and so does anything the
  expression parser cannot read. A turn wrongly left open sends a rider into a
  manoeuvre the sign forbids at exactly the hour the sign exists for; a turn
  wrongly left closed costs a detour. Those are not symmetric mistakes, and the
  defaults are not symmetric about them.

  The condition is evaluated at the moment the rider *arrives*,
  `at + secondsSoFar`, not at departure — a restriction ending at nine does not
  bind someone reaching the junction at five past. That stays sound for
  Dijkstra without making the weights time-dependent: `dist[u]` is final when
  `u` settles, so the predicate is asked once per edge at a fixed instant.

  **Waiting is not modelled**, which is a statement about the answer rather
  than the algorithm. A turn barred until half past nine is treated as barred
  for the whole query, and a longer path that would arrive after it opens is
  never preferred on those grounds. That is what a rider wants — nobody wants
  advice to idle at a junction for an hour — but it is not the true
  time-dependent optimum and is not described as one.

  `ContractionHierarchyRouter` falls back to a plain search for a clocked
  query. Its hierarchy is built with conditional edges removed, which is exact
  for the unclocked case but leaves no way to re-admit an edge a clock says is
  open. `avoidTolls` already takes the same way out, for the same reason.

  One byte per edge is *exact* only because of the split: the movement is
  already isolated onto a copy, so "this edge, from this approach" is
  determined by the edge alone. Without the split this would need a table keyed
  by edge pairs and a search state per incoming edge.

- **⚠️ Graph format v4 — every stored graph must be rebuilt.** The header grew
  24 → 32 bytes (not 28: an extra `int32` would leave every `f64` behind it on
  a 4-byte boundary, where `asFloat64List` *throws*). `splitParent` joins the
  i32 block, `adjCond` the u8 tail, and the condition strings go last inside
  the payload so the existing CRC covers them. A graph with no restrictions
  writes what it always wrote, plus eight bytes.

  **A v3 graph read as a v4 would be worse than refused**: it has no split
  junctions, so every restriction in the city silently would not apply, and the
  routes would look entirely reasonable while being illegal to follow. That is
  a harder failure to notice than the v2 → v3 case, where the cost at least
  disagreed.

- **Fixed: `KdTree` could throw `RangeError` on a subset index.** Excluding
  split copies makes the index cover fewer vertices than the graph — which the
  format already allowed, since the serializer writes `order.length` — but
  `findNearest` and `findWithinRadius` hardcoded `nodeCount` in four places. A
  latent bug, independent of this feature.

- **Fixed: `GraphCompressor` could renumber non-deterministically.** Its
  `originalId` sort had no tie-break and Dart's `List.sort` is not stable, so
  once split copies share their parent's id, two compilations of the same input
  could produce different bytes — breaking the package's byte-identical-output
  guarantee and the checksums built on it.

## 1.2.0

- **Traffic lights are part of the cost.** A route through fifteen signalised
  junctions is genuinely slower than one through three, and a router that
  cannot see them keeps choosing the straight run down the arterial over the
  quiet parallel street that is actually quicker. Now it can.

  `GeoGraph.signalNodeIds` carries the junctions; `GraphBuilder` charges
  `signalDelaySeconds` (20 s by default) to each traversal that *arrives* at
  one, folded into the time weight every router already minimises. Nothing in
  A*, Dijkstra or the contraction hierarchy had to learn about it.

- **Signals are a property of nodes, and that is not a detail.** A light delays
  whoever arrives at the junction, so the cost belongs to the traversal that
  ends there — and a two-way street is *one* `GeoEdge` from which the builder
  materialises both directions. Recorded per edge, the reverse direction would
  arrive at the far end and either miss its light or inherit one it never
  reaches. Recorded on the graph, each direction is charged for the junction it
  actually enters, and an adapter never has to split a street in two.

- **They survive compression.** A light on a degree-2 vertex — a signalised
  pedestrian crossing mid-block is the common case — loses its vertex to the
  chain compressor, and `adjSignal` accumulates through the merge exactly as
  `adjToll` does. Without that, a street full of crossings would compress into
  a street with none. The *delay* needs no special handling: it is already part
  of the merged time.

- **`GeoRoute.signalCount` reports what was passed**, so a caller can explain
  the answer. "Eleven sets of lights" is *why* the longer way round came out
  faster; without it that route just looks like a mistake. Reported and not
  charged — the waiting is already inside `duration`, and counting it twice
  would be the obvious bug here.

- **`OsmConverter` reads them from the extract**, on the pass that already
  reads node coordinates. `readSignals: false` declines the cost, which is
  decoding the node tag stream — otherwise skipped whole, and mostly untagged
  shape points. Paid once per graph, never at query time.

  Traffic lights only, which is narrower than what a map *draws*.
  `geo_tile_builder`'s `DeliverySchema` also renders stop and give-way signs
  because a driver wants to see them; they are left out of the cost because the
  graph carries a count rather than a per-class delay, and a stop sign is a few
  seconds against a light's tens. Folding them in at the same weight would say
  a street of stop signs costs as much as a street of lights, which is worse
  than saying nothing. A signalised pedestrian crossing *is* a set of lights
  and does count.

- **Graph format v3.** `adjSignal` sits beside `adjToll`, one byte per directed
  edge, after the 8- and 4-byte arrays so their alignment is untouched.
  **Every stored graph must be rebuilt.** A v2 graph's `adjTime` was computed
  without signal delay, so reading one as a v3 would give routes whose cost
  silently disagrees with every route planned since — a difference no field in
  the file would reveal.

- **`geoRouteFinderVersion` and `geoRouteFinderId`**, so a tool that compiles a
  graph can record which release compiled it. Dart cannot read `pubspec.yaml`
  at runtime and a compiled executable has none beside it, so the version has
  to be repeated in code; `test/version_test.dart` reads the pubspec and
  compares, which is what keeps the repetition honest.

  It earns its place in this release more than it would in another one.
  `kGraphFormatVersion` tells a reader *that* it is refusing a file; only the
  package version tells anyone *what wrote it*, and with v2 graphs now being
  refused that is the next question after the refusal.

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
