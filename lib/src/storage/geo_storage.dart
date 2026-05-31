import '../model/geo_graph.dart';
import '../osm/vehicle_profile.dart';

/// Persistence abstraction for compiled routing graphs.
///
/// The routing engine never touches the filesystem (or any other medium)
/// directly; it always goes through a [GeoStorage]. This keeps the engine
/// portable across server, desktop, mobile and Flutter, and lets callers swap in
/// alternative backends (an encrypted store, an in-memory cache for tests, a
/// remote blob store, …) without changing routing code.
///
/// A stored graph is keyed by **both** an opaque, filesystem-safe [id] and a
/// [VehicleProfile]: the same logical dataset (e.g. `florianopolis`) holds an
/// independent graph per transport mode, since each profile routes over a
/// different network. Implementations resolve the storage location from the
/// `(id, profile)` pair, so callers pass the bare id and the profile rather than
/// pre-encoding the mode into the id.
abstract interface class GeoStorage {
  /// Persists [graph] under [id] for [profile], overwriting any existing entry.
  Future<void> saveGraph(
    String id,
    GeoGraph graph, {
    required VehicleProfile profile,
  });

  /// Loads the graph stored under [id] for [profile], or `null` if none exists.
  Future<GeoGraph?> loadGraph(String id, {required VehicleProfile profile});

  /// Whether a graph is stored under [id] for [profile].
  Future<bool> exists(String id, {VehicleProfile profile = VehicleProfile.car});

  /// Removes the graph stored under [id] for [profile]. A no-op if absent.
  Future<void> delete(String id, {VehicleProfile profile = VehicleProfile.car});
}
