/// Whether a `restriction:conditional` expression is in force at a given time.
///
/// OSM writes these as `<value> @ <condition>`, e.g.
/// `no_left_turn @ (Mo-Fr 07:00-09:00)`. The condition half is an
/// `opening_hours` expression, a small language with a large grammar — this
/// understands the part that turn restrictions actually use: weekday
/// selectors, clock ranges, and `;`-separated alternatives.
///
/// **Anything it cannot parse is treated as always in force.** That is the
/// safe direction and it is a deliberate choice: an unrecognised expression
/// means the restriction stays on, so the router avoids a junction it might
/// have been allowed through. The opposite default would send a rider into a
/// turn the sign forbids at exactly the hour the sign exists for, on the
/// strength of a parser failing.
abstract final class ConditionalRestriction {
  /// Whether [expression] forbids the movement at [at].
  ///
  /// A null [at] means "no clock was supplied", and every condition applies —
  /// the most restricted reading. A caller that knows the time gets the
  /// narrower answer; one that does not gets the safe one.
  static bool appliesAt(String expression, DateTime? at) {
    if (at == null) return true;

    final condition = _conditionOf(expression);
    if (condition == null) return true;

    final rules = condition
        .split(';')
        .map((r) => r.trim())
        .where((r) => r.isNotEmpty);

    if (rules.isEmpty) return true;

    for (final rule in rules) {
      final matched = _ruleMatches(rule, at);
      // Unparseable: stop and say "in force", rather than letting the
      // remaining rules decide on partial information.
      if (matched == null) return true;
      if (matched) return true;
    }

    return false;
  }

  /// The `opening_hours` half of `<value> @ <condition>`, or null.
  ///
  /// A bare expression with no `@` is not a conditional restriction — it is
  /// the plain `restriction` value that reached here by mistake, and there is
  /// nothing to evaluate.
  static String? _conditionOf(String expression) {
    final at = expression.indexOf('@');
    if (at < 0) return null;

    var condition = expression.substring(at + 1).trim();
    if (condition.startsWith('(') && condition.endsWith(')')) {
      condition = condition.substring(1, condition.length - 1).trim();
    }

    return condition.isEmpty ? null : condition;
  }

  /// Whether one rule covers [at]; null when the rule cannot be read.
  static bool? _ruleMatches(String rule, DateTime at) {
    if (rule == '24/7') return true;

    // A rule is an optional weekday selector followed by an optional list of
    // clock ranges: `Mo-Fr 07:00-09:00,16:00-18:00`. Either may be absent, and
    // an absent one means "every day" or "all day" respectively.
    final parts = rule.split(RegExp(r'\s+'));

    String? days;
    String? times;

    for (final part in parts) {
      if (part.isEmpty) continue;
      if (_looksLikeTimes(part)) {
        // A second clock list in one rule is a shape this does not model.
        if (times != null) return null;
        times = part;
      } else {
        if (days != null) return null;
        days = part;
      }
    }

    if (days == null && times == null) return null;

    if (days != null) {
      final onDay = _dayMatches(days, at.weekday);
      if (onDay == null) return null;
      if (!onDay) return false;
    }

    if (times == null) return true;

    return _timeMatches(times, at);
  }

  static bool _looksLikeTimes(String part) => part.contains(':');

  /// Weekday abbreviations, Monday first so the index matches
  /// `DateTime.weekday - 1`.
  static const _days = ['mo', 'tu', 'we', 'th', 'fr', 'sa', 'su'];

  /// Whether a selector such as `Mo-Fr` or `Sa,Su` covers [weekday].
  static bool? _dayMatches(String selector, int weekday) {
    final today = weekday - 1;

    for (final term in selector.split(',')) {
      final trimmed = term.trim().toLowerCase();
      if (trimmed.isEmpty) continue;

      final dash = trimmed.indexOf('-');
      if (dash < 0) {
        final index = _days.indexOf(trimmed);
        if (index < 0) return null;
        if (index == today) return true;
        continue;
      }

      final from = _days.indexOf(trimmed.substring(0, dash));
      final to = _days.indexOf(trimmed.substring(dash + 1));
      if (from < 0 || to < 0) return null;

      // `Sa-Mo` wraps through the end of the week, which is how a weekend
      // restriction spanning Sunday night is written.
      final inRange = from <= to
          ? today >= from && today <= to
          : today >= from || today <= to;

      if (inRange) return true;
    }

    return false;
  }

  /// Whether a list such as `07:00-09:00,16:00-18:00` covers [at].
  static bool? _timeMatches(String selector, DateTime at) {
    final minutes = at.hour * 60 + at.minute;

    for (final term in selector.split(',')) {
      final trimmed = term.trim();
      if (trimmed.isEmpty) continue;

      final dash = trimmed.indexOf('-');
      if (dash < 0) return null;

      final from = _minutesOf(trimmed.substring(0, dash));
      final to = _minutesOf(trimmed.substring(dash + 1));
      if (from == null || to == null) return null;

      // `22:00-06:00` runs through midnight. Read as two spans rather than an
      // empty one, which is what a naive comparison would make of it.
      final inRange = from <= to
          ? minutes >= from && minutes < to
          : minutes >= from || minutes < to;

      if (inRange) return true;
    }

    return false;
  }

  /// `HH:MM` as minutes past midnight, or null.
  static int? _minutesOf(String time) {
    final parts = time.trim().split(':');
    if (parts.length != 2) return null;

    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 24 || minute < 0 || minute > 59) return null;

    return hour * 60 + minute;
  }
}
