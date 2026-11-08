/// Fixed, content-free evidence only. Never retain the native response map.
class SystemImeEvidence {
  SystemImeEvidence._(this.code, this.capturedAt, List<SystemImeEvent> events)
    : events = List.unmodifiable(events);

  static const maxEvents = 64;
  static const windowMs = 120000;
  static const codes = {
    'ok', 'noEvents', 'unavailable', 'unsupported', 'denied', 'cancelled',
    'busy', 'timeout', 'limitExceeded', 'failed',
  };
  static const reasons = {
    'SHOW_SOFT_INPUT', 'SHOW_SOFT_INPUT_FROM_IME', 'SHOW_AUTO_EDITOR_FORWARD_NAV',
    'SHOW_STATE_VISIBLE_FORWARD_NAV', 'SHOW_STATE_ALWAYS_VISIBLE', 'HIDE_SOFT_INPUT',
    'HIDE_SOFT_INPUT_FROM_IME', 'HIDE_STATE_HIDDEN_FORWARD_NAV',
    'HIDE_ALWAYS_HIDDEN_STATE', 'HIDE_WINDOW_LOST_FOCUS',
  };

  final String code;
  final int capturedAt;
  final List<SystemImeEvent> events;
  bool get ok => code == 'ok' || code == 'noEvents';

  factory SystemImeEvidence.failure(String code, DateTime at) =>
      SystemImeEvidence._(codes.contains(code) && code != 'ok' && code != 'noEvents' ? code : 'failed',
          at.millisecondsSinceEpoch, const []);

  factory SystemImeEvidence.fromNative(Object? raw, {required DateTime now}) {
    SystemImeEvidence invalid() => SystemImeEvidence.failure('failed', now);
    if (raw is! Map) return invalid();
    final code = raw['code'];
    final capturedAt = raw['capturedAt'];
    final rows = raw['events'];
    final nowMs = now.millisecondsSinceEpoch;
    if (code is! String || !codes.contains(code) ||
        raw['source'] != 'privilegedIme' || raw['ok'] is! bool ||
        raw['ok'] != (code == 'ok' || code == 'noEvents') ||
        capturedAt is! int || capturedAt <= 0 ||
        capturedAt > nowMs || capturedAt < nowMs - windowMs || rows is! List) {
      return invalid();
    }
    if (rows.length > maxEvents) return SystemImeEvidence.failure('limitExceeded', now);
    if ((code == 'ok' && rows.isEmpty) || (code != 'ok' && rows.isNotEmpty)) return invalid();
    final events = <SystemImeEvent>[];
    for (final row in rows) {
      if (row is! Map) return invalid();
      final timestamp = row['timestamp'];
      final event = row['event'];
      final fromUser = row['fromUser'];
      final reason = row['reason'];
      final origin = row['origin'];
      if (timestamp is! int || timestamp < capturedAt - windowMs || timestamp > capturedAt ||
          !row.containsKey('fromUser') || (fromUser != null && fromUser is! bool) ||
          event is! String || reason is! String || origin is! String) {
        return invalid();
      }
      final request = event == 'requestShow' || event == 'requestHide';
      final valid = switch (origin) {
        'imeTracker' => request && reasons.contains(reason),
        'inputMethodManager' => request && fromUser == null && reason == 'unknown',
        'inputConnection' => event == 'connectionClosed' && fromUser == null && reason == 'unknown',
        _ => false,
      };
      if (!valid) return invalid();
      events.add(SystemImeEvent._(timestamp, event, fromUser, reason, origin));
    }
    events.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return SystemImeEvidence._(code, capturedAt, events);
  }

  Map<String, Object?> toJson() => {
    'ok': ok,
    'code': code,
    'capturedAt': capturedAt,
    'source': 'privilegedIme',
    'events': events.map((event) => event.toJson()).toList(),
  };
}

class SystemImeEvent {
  const SystemImeEvent._(this.timestamp, this.event, this.fromUser, this.reason, this.origin);

  final int timestamp;
  final String event;
  final bool? fromUser;
  final String reason;
  final String origin;

  Map<String, Object?> toJson() => {
    'timestamp': timestamp,
    'event': event,
    'fromUser': fromUser,
    'reason': reason,
    'origin': origin,
  };
}
