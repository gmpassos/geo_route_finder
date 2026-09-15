import 'dart:io';

import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

/// The version constant against the pubspec.
///
/// Dart cannot read `pubspec.yaml` at runtime, so the version an artefact
/// records has to be repeated in code — and a repeated fact is one that
/// drifts. Bump the pubspec without bumping the constant and a compiled graph
/// claims to have been produced by the previous release, which is worse than
/// claiming nothing because it looks like an answer.

void main() {
  group('geoRouteFinderVersion', () {
    test('matches the version in pubspec.yaml', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();

      final declared = RegExp(
        r'^version:\s*(\S+)\s*$',
        multiLine: true,
      ).firstMatch(pubspec)?.group(1);

      expect(
        declared,
        isNotNull,
        reason: 'pubspec.yaml has no top-level `version:`',
      );

      expect(
        geoRouteFinderVersion,
        equals(declared),
        reason:
            'lib/src/version.dart says $geoRouteFinderVersion, '
            'pubspec.yaml says $declared',
      );
    });

    test('the artefact id names the package and that version', () {
      expect(
        geoRouteFinderId,
        equals('geo_route_finder/$geoRouteFinderVersion'),
      );
      expect(geoRouteFinderId, startsWith('geo_route_finder/'));
    });

    test('is the half of a graph diagnosis the format version is not', () {
      // A refused graph reports its format version, and alone that is a
      // shrug: `v3` says nothing about which release wrote it. Paired with
      // the package version it is a diagnosis. Deliberately not a coupling —
      // most releases change no format, and pinning the two together here
      // would fail on the next unrelated bump — so this only holds that both
      // halves exist and read as one line.
      expect(kGraphFormatVersion, greaterThan(0));
      expect(
        'graph v$kGraphFormatVersion written by $geoRouteFinderId',
        matches(RegExp(r'^graph v\d+ written by geo_route_finder/\S+$')),
      );
    });
  });
}
