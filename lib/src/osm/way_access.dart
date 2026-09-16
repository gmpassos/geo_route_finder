import 'vehicle_profile.dart';

/// What a way may be used for.
///
/// The middle value is the point of this type. A driveway, a parking aisle or
/// a road signed `access=destination` is not unusable — a rider has to be able
/// to reach an address on one — but it is not a road anyone may cut through
/// either, and treating those two cases as one is how a router ends up sending
/// someone across a supermarket car park to save thirty metres.
enum WayAccess {
  /// Usable by anyone, in the middle of a route like any other road.
  open,

  /// Usable only to reach something on it: allowed in a run at the start or
  /// the end of a route, never as a link between two public roads.
  accessOnly,

  /// Not usable at all. The way is dropped before it reaches the graph.
  blocked;

  /// The stricter of two readings.
  ///
  /// Used wherever two tags each have something to say — the `service=`
  /// subtype and the `access=` value, say. Being wrong toward *more*
  /// restriction costs a detour; being wrong toward less puts a rider on a
  /// road they may not be on.
  WayAccess strictest(WayAccess other) => index >= other.index ? this : other;
}

/// Reads the tags that decide whether a way is a road, a private approach, or
/// neither.
///
/// Separate from `OsmConverter` because this is a table of OpenStreetMap
/// conventions rather than conversion logic, and because the interesting cases
/// — `service=parking_aisle`, `access=destination`, a track with no
/// `tracktype` — are worth reading in one place and testing directly.
abstract final class WayAccessRules {
  /// `service=` subtypes that are not roads for anyone.
  ///
  /// A drive-through is a queue lane at a window, an emergency access is a
  /// fire lane, a bus-only service road is not for private traffic, and a
  /// slipway leads into water. None is an address and none is a route.
  static const excludedServices = {
    'drive-through',
    'drive_through',
    'emergency_access',
    'bus',
    'slipway',
  };

  /// `service=` subtypes that exist to reach one property, never to pass
  /// through it.
  static const accessOnlyServices = {'driveway', 'parking_aisle'};

  /// Speeds in km/h for the `service=` subtypes that differ from the class
  /// default.
  ///
  /// A parking aisle at 20 km/h is a fiction — they are full of pedestrians
  /// and reversing cars — and the fiction is what makes cutting through a car
  /// park look cheap.
  static const serviceSpeedKmh = {
    'driveway': 10.0,
    'parking_aisle': 10.0,
    'alley': 15.0,
  };

  /// Access values that stop a way being a through-route without closing it.
  ///
  /// `destination` is the tag that literally means "no through traffic".
  /// `customers` and `delivery` say the same of a narrower audience — one a
  /// delivery rider generally belongs to. `permit` is grouped here by
  /// decision: it reads as prior individual permission, which is arguably
  /// closer to `private`, but a pack is built for riders who are expected at
  /// the places they deliver to.
  static const accessOnlyValues = {
    'destination',
    'customers',
    'delivery',
    'permit',
    'discouraged',
  };

  /// Access values that close a way to everyone.
  static const blockedValues = {'no', 'private', 'military', 'emergency'};

  /// Access values that close a way to motor vehicles only.
  ///
  /// A scooter is not a tractor. A bicycle on a farm track is unaffected.
  static const motorBlockedValues = {'agricultural', 'forestry'};

  /// Access values that assert a way *is* open, overriding a category default.
  static const openValues = {'yes', 'permissive', 'designated', 'official'};

  /// Bicycle classes that are not cyclable unless the tags say so.
  ///
  /// A pavement is not a cycle route by default. These were routable with no
  /// check at all, which is the same shape of bug as ignoring `service=`: a
  /// tag that decides the answer was never read.
  static const bicycleNeedsPermission = {'footway', 'pedestrian', 'bridleway'};

  /// Speeds in km/h by `tracktype`, for the motor profiles.
  ///
  /// A `grade1` track is a paved farm road; a `grade5` is bare earth. Untagged
  /// is treated as `grade3`, the middle, because an unsurveyed track is more
  /// often rough than not.
  static const trackSpeedKmh = {
    'grade1': 25.0,
    'grade2': 18.0,
    'grade3': 10.0,
    'grade4': 7.0,
    'grade5': 5.0,
  };

  /// The speed for a track whose `tracktype` is not stated.
  static const untaggedTrackSpeedKmh = 10.0;

  /// How [profile] may use the way described by [tags].
  ///
  /// Resolution, in order:
  ///
  /// 1. An excluded `service=` subtype, or an access value that closes the way,
  ///    is [WayAccess.blocked] and stays that way — `access=yes` on a fire lane
  ///    is still a fire lane.
  /// 2. Otherwise the class default and the access value are read
  ///    independently and the **stricter** wins.
  /// 3. An explicit positive access value may loosen [WayAccess.accessOnly] to
  ///    [WayAccess.open], because a mapper asserting `access=yes` on a driveway
  ///    is saying something specific that beats a category default.
  static WayAccess of(Map<String, String> tags, VehicleProfile profile) {
    final highway = tags['highway']?.toLowerCase();
    if (highway == null) return WayAccess.blocked;

    final service = tags['service']?.toLowerCase();

    // Rule 1. Checked before anything can loosen it.
    if (highway == 'service' &&
        service != null &&
        excludedServices.contains(service)) {
      return WayAccess.blocked;
    }

    final explicit = _accessValue(tags, profile);
    if (explicit == WayAccess.blocked) return WayAccess.blocked;

    if (!profile.isMotorVehicle &&
        bicycleNeedsPermission.contains(highway) &&
        !_bicycleInvited(tags)) {
      return WayAccess.blocked;
    }

    // Rule 3. An explicit yes beats the category default; an exclusion has
    // already returned, so this can never open one.
    if (explicit == WayAccess.open) return WayAccess.open;

    var byClass = WayAccess.open;
    if (highway == 'service' &&
        service != null &&
        accessOnlyServices.contains(service)) {
      byClass = WayAccess.accessOnly;
    }
    // A track leads to a farm, not across one. Left open for bicycles, which
    // route over tracks as ordinary minor ways.
    if (highway == 'track' && profile.isMotorVehicle) {
      byClass = WayAccess.accessOnly;
    }

    // Rule 2.
    return byClass.strictest(explicit ?? WayAccess.open);
  }

  /// The speed [profile] should be given on this way, or null to use the
  /// per-class default.
  static double? speedKmh(Map<String, String> tags, VehicleProfile profile) {
    final highway = tags['highway']?.toLowerCase();

    if (highway == 'service') {
      final service = tags['service']?.toLowerCase();
      return service == null ? null : serviceSpeedKmh[service];
    }

    if (highway == 'track' && profile.isMotorVehicle) {
      final grade = tags['tracktype']?.toLowerCase();
      return trackSpeedKmh[grade] ?? untaggedTrackSpeedKmh;
    }

    return null;
  }

  /// The access value that applies to [profile], or null when the way carries
  /// none this profile reads.
  ///
  /// The most specific key present decides, so `motorcar=yes` beats
  /// `access=no` — which is the whole reason the keys are ordered.
  ///
  /// A value none of the tables name is read as *no opinion*, not as a
  /// restriction. The tables enumerate what restricts; treating everything
  /// else as restrictive would let one typo — `access=Yes` before this
  /// lowercases, `acess=yes` after — quietly downgrade an arterial to an
  /// approach road, which is a far worse failure than missing a rare value.
  static WayAccess? _accessValue(
    Map<String, String> tags,
    VehicleProfile profile,
  ) {
    for (final key in profile.accessKeys) {
      final value = tags[key]?.toLowerCase();
      if (value == null) continue;

      if (blockedValues.contains(value)) return WayAccess.blocked;
      if (profile.isMotorVehicle && motorBlockedValues.contains(value)) {
        return WayAccess.blocked;
      }
      if (accessOnlyValues.contains(value)) return WayAccess.accessOnly;
      if (openValues.contains(value)) return WayAccess.open;

      return null;
    }
    return null;
  }

  static bool _bicycleInvited(Map<String, String> tags) {
    final value = tags['bicycle']?.toLowerCase();
    return value == 'yes' || value == 'designated' || value == 'permissive';
  }
}
