/// This package's version, as `pubspec.yaml` declares it.
///
/// Dart cannot read `pubspec.yaml` at runtime — it is not an asset, and a
/// compiled executable has no pubspec beside it at all — so a tool that wants
/// to record which version of this package produced an artefact has to be told
/// in code.
///
/// **That is the whole point of it.** A compiled graph carries the builder
/// version that produced it, and until now that string was typed by hand on a
/// command line: optional, defaulted to empty, and free to disagree with the
/// package that actually did the work. It matters more here than it looks —
/// the on-disk graph format has a version of its own, and "which release
/// wrote this" is the first question asked when one will not load.
///
/// Keep it in step with `pubspec.yaml`. `test/version_test.dart` is what stops
/// you forgetting: it reads the pubspec and compares.
library;

/// The version in `pubspec.yaml`, repeated for the code to read.
const geoRouteFinderVersion = '1.4.0';

/// This package, named and versioned the way an artefact records it.
const geoRouteFinderId = 'geo_route_finder/$geoRouteFinderVersion';
