/// Controls how raw source tags (highway class, access, speed, one-way) are
/// interpreted when an OSM extract is converted into a routable graph.
///
/// Different modes of transport route over *different* networks: a bicycle may
/// use a `cycleway` but not a `motorway`, ignores motor-vehicle one-way
/// restrictions, and travels at a flat speed unrelated to the road's posted
/// `maxspeed`; a car does the opposite. Because the engine bakes a single
/// travel-time weight per edge at build time (and the Contraction-Hierarchies
/// router precomputes shortcuts from those weights), each profile produces its
/// own compiled graph rather than being selected at query time.
///
/// Pass a profile to [OsmConverter] and store the result under a profile-scoped
/// graph id (e.g. `city_car`, `city_bicycle`).
class VehicleProfile {
  /// Short identifier, e.g. `car`, `motorcycle`, `bicycle`.
  final String name;

  /// Routable highway classes, compared after stripping any `_link` suffix.
  final Set<String> routableHighways;

  /// Fallback speed in km/h per (normalized) highway class.
  final Map<String, double> defaultSpeedKmh;

  /// Upper bound applied to the final per-edge speed, in km/h. Caps unrealistic
  /// posted limits for the mode (e.g. a bicycle on a 120 km/h road).
  final double maxSpeedKmh;

  /// When `true`, the road's posted `maxspeed` is ignored and the per-class
  /// [defaultSpeedKmh] is always used. Appropriate for human-powered modes whose
  /// speed is unrelated to the legal limit.
  final bool ignoreWayMaxspeed;

  /// Access tag keys to consult, ordered most-specific first. The first key
  /// present on a way decides access; e.g. `motorcar` overrides a generic
  /// `vehicle`/`access`.
  final List<String> accessKeys;

  /// Whether motor-vehicle one-way restrictions (`oneway`, implicit
  /// motorway/roundabout) apply. Bicycles set this to `false` but still honor an
  /// explicit `oneway:bicycle`.
  final bool honorOneway;

  const VehicleProfile({
    required this.name,
    required this.routableHighways,
    required this.defaultSpeedKmh,
    required this.maxSpeedKmh,
    required this.accessKeys,
    required this.honorOneway,
    this.ignoreWayMaxspeed = false,
  });

  /// Highway classes drivable by motor vehicles. Shared by [car] and
  /// [motorcycle].
  static const Set<String> motorHighways = {
    'motorway',
    'trunk',
    'primary',
    'secondary',
    'tertiary',
    'residential',
    'service',
    'living_street',
    'unclassified',
  };

  /// Default motor-vehicle speeds in km/h per (normalized) highway class.
  static const Map<String, double> motorSpeedKmh = {
    'motorway': 110,
    'trunk': 90,
    'primary': 80,
    'secondary': 60,
    'tertiary': 50,
    'residential': 40,
    'service': 20,
    'living_street': 10,
    'unclassified': 40,
  };

  /// Private cars.
  static const VehicleProfile car = VehicleProfile(
    name: 'car',
    routableHighways: motorHighways,
    defaultSpeedKmh: motorSpeedKmh,
    maxSpeedKmh: 130,
    accessKeys: ['motorcar', 'motor_vehicle', 'vehicle', 'access'],
    honorOneway: true,
  );

  /// Motorcycles. Same network and speeds as a car, but access is decided by
  /// motorcycle-specific tags first.
  static const VehicleProfile motorcycle = VehicleProfile(
    name: 'motorcycle',
    routableHighways: motorHighways,
    defaultSpeedKmh: motorSpeedKmh,
    maxSpeedKmh: 130,
    accessKeys: ['motorcycle', 'motor_vehicle', 'vehicle', 'access'],
    honorOneway: true,
  );

  /// Bicycles. Routes over cycle infrastructure and minor roads, excludes
  /// motorways/trunks, ignores motor-vehicle one-way rules, and travels at a
  /// flat speed independent of the posted limit.
  static const VehicleProfile bicycle = VehicleProfile(
    name: 'bicycle',
    routableHighways: {
      'primary',
      'secondary',
      'tertiary',
      'residential',
      'unclassified',
      'service',
      'living_street',
      'cycleway',
      'path',
      'track',
      'footway',
      'bridleway',
      'pedestrian',
    },
    defaultSpeedKmh: {
      'primary': 15,
      'secondary': 15,
      'tertiary': 15,
      'residential': 15,
      'unclassified': 15,
      'service': 12,
      'living_street': 10,
      'cycleway': 16,
      'path': 12,
      'track': 12,
      'footway': 8,
      'bridleway': 8,
      'pedestrian': 8,
    },
    maxSpeedKmh: 25,
    ignoreWayMaxspeed: true,
    accessKeys: ['bicycle', 'vehicle', 'access'],
    honorOneway: false,
  );

  /// The bundled profiles, keyed by [name].
  static const Map<String, VehicleProfile> all = {
    'car': car,
    'motorcycle': motorcycle,
    'bicycle': bicycle,
  };

  @override
  String toString() => 'VehicleProfile($name)';
}
