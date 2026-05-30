import '../model/geo_graph.dart';

/// Persistence abstraction for compiled routing graphs.
///
/// The routing engine never touches the filesystem (or any other medium)
/// directly; it always goes through a [GeoStorage]. This keeps the engine
/// portable across server, desktop, mobile and Flutter, and lets callers swap in
/// alternative backends (an encrypted store, an in-memory cache for tests, a
/// remote blob store, …) without changing routing code.
///
/// Implementations should treat [id] as an opaque, filesystem-safe key.
abstract interface class GeoStorage {
  /// Persists [graph] under [id], overwriting any existing entry.
  Future<void> saveGraph(String id, GeoGraph graph);

  /// Loads the graph stored under [id], or `null` if none exists.
  Future<GeoGraph?> loadGraph(String id);

  /// Whether a graph is stored under [id].
  Future<bool> exists(String id);

  /// Removes the graph stored under [id]. A no-op if it does not exist.
  Future<void> delete(String id);
}
