import 'package:geo_route_finder/geo_route_finder.dart';
import 'package:test/test.dart';

/// Reading `restriction:conditional` against a clock.
///
/// The bias throughout is toward *keeping the restriction on*. A turn that is
/// wrongly left open sends a rider into a manoeuvre the sign forbids, at
/// exactly the hour the sign exists for; a turn wrongly left closed costs a
/// detour. Those are not symmetric mistakes, and the code is not symmetric
/// about them.

void main() {
  /// Monday 2026-09-14 at [hour]:[minute].
  DateTime monday(int hour, [int minute = 0]) =>
      DateTime(2026, 9, 14, hour, minute);

  /// Sunday 2026-09-13.
  DateTime sunday(int hour, [int minute = 0]) =>
      DateTime(2026, 9, 13, hour, minute);

  bool applies(String expression, DateTime? at) =>
      ConditionalRestriction.appliesAt(expression, at);

  group('with no clock', () {
    test('every condition applies', () {
      // The deliberate default. Not knowing the time is not a reason to
      // assume the permissive case.
      expect(applies('no_left_turn @ (Mo-Fr 07:00-09:00)', null), isTrue);
      expect(applies('no_left_turn @ (Sa,Su)', null), isTrue);
      expect(applies('anything at all', null), isTrue);
    });
  });

  group('weekday and clock selectors', () {
    const morning = 'no_left_turn @ (Mo-Fr 07:00-09:00)';

    test('inside the window, on a listed day', () {
      expect(applies(morning, monday(8)), isTrue);
    });

    test('outside the window, on a listed day', () {
      expect(applies(morning, monday(10)), isFalse);
      expect(applies(morning, monday(6, 59)), isFalse);
    });

    test('the end of the window is exclusive', () {
      // A restriction "until nine" does not bind at nine. The rider who
      // arrives on the hour is through.
      expect(applies(morning, monday(8, 59)), isTrue);
      expect(applies(morning, monday(9)), isFalse);
    });

    test('a day outside the selector', () {
      expect(applies(morning, sunday(8)), isFalse);
    });

    test('a day list rather than a range', () {
      const weekend = 'no_left_turn @ (Sa,Su)';
      expect(applies(weekend, sunday(8)), isTrue);
      expect(applies(weekend, monday(8)), isFalse);
    });

    test('a clock range with no days binds every day', () {
      const always = 'no_left_turn @ (07:00-09:00)';
      expect(applies(always, monday(8)), isTrue);
      expect(applies(always, sunday(8)), isTrue);
      expect(applies(always, sunday(10)), isFalse);
    });

    test('a day selector with no clock binds all day', () {
      const sundays = 'no_left_turn @ (Su)';
      expect(applies(sundays, sunday(3)), isTrue);
      expect(applies(sundays, sunday(23)), isTrue);
      expect(applies(sundays, monday(3)), isFalse);
    });

    test('two windows in one rule', () {
      const peaks = 'no_left_turn @ (Mo-Fr 07:00-09:00,16:00-18:00)';
      expect(applies(peaks, monday(8)), isTrue);
      expect(applies(peaks, monday(17)), isTrue);
      expect(applies(peaks, monday(12)), isFalse);
    });

    test('two rules separated by a semicolon', () {
      const mixed = 'no_left_turn @ (Mo-Fr 07:00-09:00; Sa 08:00-12:00)';
      expect(applies(mixed, monday(8)), isTrue);
      expect(applies(mixed, DateTime(2026, 9, 12, 9)), isTrue); // Saturday
      expect(applies(mixed, sunday(9)), isFalse);
    });

    test('a window running through midnight', () {
      // `22:00-06:00` is two spans, not an empty one — which is what a naive
      // `from <= now && now < to` would make of it.
      const night = 'no_entry @ (22:00-06:00)';
      expect(applies(night, monday(23)), isTrue);
      expect(applies(night, monday(2)), isTrue);
      expect(applies(night, monday(12)), isFalse);
    });

    test('a day range wrapping the end of the week', () {
      const weekend = 'no_left_turn @ (Sa-Su)';
      expect(applies(weekend, sunday(8)), isTrue);
      expect(applies(weekend, monday(8)), isFalse);
    });

    test('24/7 is always in force', () {
      expect(applies('no_left_turn @ (24/7)', monday(3)), isTrue);
    });

    test('the parentheses are optional', () {
      expect(applies('no_left_turn @ Mo-Fr 07:00-09:00', monday(8)), isTrue);
      expect(applies('no_left_turn @ Mo-Fr 07:00-09:00', monday(12)), isFalse);
    });
  });

  group('what it cannot read, it does not guess', () {
    test('an unparseable condition stays in force', () {
      // The whole safety argument in one test. A parser that does not
      // understand an expression must not conclude the turn is open.
      expect(applies('no_left_turn @ (school days)', monday(12)), isTrue);
      expect(
        applies('no_left_turn @ (Mo-Fr sunset-sunrise)', monday(12)),
        isTrue,
      );
      expect(applies('no_left_turn @ (2026 Jan 01)', monday(12)), isTrue);
    });

    test('a malformed clock stays in force', () {
      expect(applies('no_left_turn @ (Mo-Fr 07:00)', monday(12)), isTrue);
      expect(applies('no_left_turn @ (Mo-Fr 25:00-26:00)', monday(12)), isTrue);
    });

    test('an unknown weekday stays in force', () {
      expect(applies('no_left_turn @ (Xx 07:00-09:00)', monday(8)), isTrue);
    });

    test('an expression with no condition at all stays in force', () {
      // A plain `restriction` value that reached here by mistake. There is
      // nothing to evaluate, so nothing is relaxed.
      expect(applies('no_left_turn', monday(12)), isTrue);
      expect(applies('no_left_turn @ ()', monday(12)), isTrue);
      expect(applies('', monday(12)), isTrue);
    });

    test('one unreadable rule does not let the others decide', () {
      // Partial information is not better information: if any rule cannot be
      // read, the answer is "in force" rather than whatever the rest happen
      // to say.
      expect(
        applies('no_left_turn @ (school days; Mo-Fr 07:00-09:00)', monday(12)),
        isTrue,
      );
    });
  });
}
