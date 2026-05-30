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
