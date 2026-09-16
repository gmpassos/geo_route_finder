import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

/// Which ways a profile may use, and for what.
///
/// The middle answer is the one that matters. A driveway is not unusable — a
/// rider has to reach the address on it — but it is not a road anyone may cut
/// through either, and a router that cannot tell those apart sends someone
/// across a supermarket car park to save thirty metres.

void main() {
  WayAccess carAccess(Map<String, String> tags) =>
      WayAccessRules.of(tags, VehicleProfile.car);

  WayAccess bikeAccess(Map<String, String> tags) =>
      WayAccessRules.of(tags, VehicleProfile.bicycle);

  double? carSpeed(Map<String, String> tags) =>
      WayAccessRules.speedKmh(tags, VehicleProfile.car);

  group('service subtypes', () {
    test('a plain service road is an ordinary road', () {
      expect(carAccess({'highway': 'service'}), WayAccess.open);
      expect(carSpeed({'highway': 'service'}), isNull, reason: 'class default');
    });

    test('a driveway is reachable, never a through-route', () {
      const tags = {'highway': 'service', 'service': 'driveway'};
      expect(carAccess(tags), WayAccess.accessOnly);
      expect(carSpeed(tags), 10);
    });

    test('a parking aisle is reachable, never a through-route', () {
      const tags = {'highway': 'service', 'service': 'parking_aisle'};
      expect(carAccess(tags), WayAccess.accessOnly);
      expect(
        carSpeed(tags),
        10,
        reason:
            '20 km/h is a fiction, and the fiction is what makes cutting '
            'through a car park look cheap',
      );
    });

    test('an alley stays a through-route, just a slow one', () {
      // Often *the* delivery access behind a row of shops, so closing it would
      // cost exactly the deliveries this package exists for.
      const tags = {'highway': 'service', 'service': 'alley'};
      expect(carAccess(tags), WayAccess.open);
      expect(carSpeed(tags), 15);
    });

    for (final service in const [
      'drive-through',
      'drive_through',
      'emergency_access',
      'bus',
      'slipway',
    ]) {
      test('service=$service is not a road', () {
        expect(
          carAccess({'highway': 'service', 'service': service}),
          WayAccess.blocked,
        );
      });
    }

    test('an unknown subtype is left as an ordinary service road', () {
      // `service=yard`, `service=spur` and friends. Blocking every value not
      // in the table would drop real connectors over an unsurveyed detail.
      expect(
        carAccess({'highway': 'service', 'service': 'yard'}),
        WayAccess.open,
      );
    });
  });

  group('access values', () {
    test('destination is reachable, not through-routable', () {
      // The tag that literally means "no through traffic", and the one this
      // package read as a plain yes until now.
      expect(
        carAccess({'highway': 'residential', 'access': 'destination'}),
        WayAccess.accessOnly,
      );
    });

    for (final value in const [
      'customers',
      'delivery',
      'permit',
      'discouraged',
    ]) {
      test('access=$value is reachable, not through-routable', () {
        expect(
          carAccess({'highway': 'residential', 'access': value}),
          WayAccess.accessOnly,
        );
      });
    }

    for (final value in const ['no', 'private', 'military', 'emergency']) {
      test('access=$value closes the way', () {
        expect(
          carAccess({'highway': 'residential', 'access': value}),
          WayAccess.blocked,
        );
      });
    }

    test('agricultural and forestry close it to motors only', () {
      for (final value in const ['agricultural', 'forestry']) {
        expect(
          carAccess({'highway': 'track', 'access': value}),
          WayAccess.blocked,
          reason: 'a scooter is not a tractor',
        );
        expect(
          bikeAccess({'highway': 'track', 'access': value}),
          isNot(WayAccess.blocked),
          reason: 'a bicycle on a farm track is unaffected',
        );
      }
    });

    test('the most specific key wins', () {
      // `motorcar=yes` over `access=no` is the whole reason the keys are
      // ordered, and it is how a road closed to lorries stays open to us.
      expect(
        carAccess({
          'highway': 'residential',
          'access': 'no',
          'motorcar': 'yes',
        }),
        WayAccess.open,
      );
    });

    test('an unreadable value is no opinion, not a restriction', () {
      // One typo must not quietly demote an arterial to an approach road.
      expect(
        carAccess({'highway': 'primary', 'access': 'sim'}),
        WayAccess.open,
      );
    });

    test('values are read case-insensitively', () {
      expect(
        carAccess({'highway': 'residential', 'access': 'Private'}),
        WayAccess.blocked,
      );
    });
  });

  group('precedence when the class and the access value disagree', () {
    test('the stricter of the two wins', () {
      // An alley is through-routable and `permit` is not, so the pair is not.
      expect(
        carAccess({
          'highway': 'service',
          'service': 'alley',
          'access': 'permit',
        }),
        WayAccess.accessOnly,
      );
    });

    test('an explicit yes may loosen a category default', () {
      // A mapper writing `access=yes` on a driveway is asserting something
      // specific, and that beats a default drawn from the subtype alone.
      expect(
        carAccess({
          'highway': 'service',
          'service': 'driveway',
          'access': 'yes',
        }),
        WayAccess.open,
      );
    });

    test('but it can never reopen an excluded subtype', () {
      expect(
        carAccess({
          'highway': 'service',
          'service': 'emergency_access',
          'access': 'yes',
        }),
        WayAccess.blocked,
        reason: 'access=yes on a fire lane is still a fire lane',
      );
    });
  });

  group('tracks', () {
    test('a motor vehicle may reach one but not cross it', () {
      expect(carAccess({'highway': 'track'}), WayAccess.accessOnly);
    });

    test('speed comes from the tracktype', () {
      expect(carSpeed({'highway': 'track', 'tracktype': 'grade1'}), 25);
      expect(carSpeed({'highway': 'track', 'tracktype': 'grade3'}), 10);
      expect(carSpeed({'highway': 'track', 'tracktype': 'grade5'}), 5);
    });

    test('an unsurveyed track is assumed rough, not smooth', () {
      expect(carSpeed({'highway': 'track'}), 10);
    });

    test('a bicycle treats a track as an ordinary minor way', () {
      expect(bikeAccess({'highway': 'track'}), WayAccess.open);
      expect(
        WayAccessRules.speedKmh({'highway': 'track'}, VehicleProfile.bicycle),
        isNull,
        reason: 'the class default applies; tracktype is a motor concern',
      );
    });
  });

  group('what a bicycle may ride on', () {
    for (final highway in const ['footway', 'pedestrian', 'bridleway']) {
      test('$highway needs an invitation', () {
        // These routed at 8 km/h with no check at all — the same shape of bug
        // as ignoring `service=`: a tag that decides the answer was never read.
        expect(bikeAccess({'highway': highway}), WayAccess.blocked);

        expect(
          bikeAccess({'highway': highway, 'bicycle': 'yes'}),
          WayAccess.open,
        );
        expect(
          bikeAccess({'highway': highway, 'bicycle': 'designated'}),
          WayAccess.open,
        );
      });
    }

    test('a path is open by default, and closed when it says so', () {
      expect(bikeAccess({'highway': 'path'}), WayAccess.open);
      expect(
        bikeAccess({'highway': 'path', 'bicycle': 'no'}),
        WayAccess.blocked,
      );
    });

    test('a cycleway needs no invitation', () {
      expect(bikeAccess({'highway': 'cycleway'}), WayAccess.open);
    });
  });

  group('the ways that prompted all this', () {
    test('a permit-only paved parking aisle', () {
      // Both the subtype and the access value say the same thing, and until
      // now neither was read: this was a 20 km/h public shortcut.
      expect(
        carAccess(const {
          'access': 'permit',
          'highway': 'service',
          'service': 'parking_aisle',
          'surface': 'paved',
        }),
        WayAccess.accessOnly,
      );
    });

    test('surface is not read, and does not change the answer', () {
      // Stated so that adding it later is a decision rather than a surprise.
      expect(
        carSpeed(const {
          'highway': 'service',
          'service': 'parking_aisle',
          'surface': 'paved',
        }),
        carSpeed(const {'highway': 'service', 'service': 'parking_aisle'}),
      );
    });
  });
}
