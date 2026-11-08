// Local, silent greetings and cushion invitations. One controller belongs to
// the App installation, not to a host, page, session or WebView. The caller
// supplies observed eligibility and both clocks; this file performs no I/O.

const _maxSafeInteger = 9007199254740991;

abstract final class CompanionInitiativeRules {
  static const quietMs = 45000;
  static const promptMs = 8000;
  static const greetingGapMs = 30 * 60000;
  static const newStayAbsenceMs = 30 * 60000;
  static const inviteGapMs = 6 * 60 * 60000;
  static const windowMs = 24 * 60 * 60000;
  static const maxInvites = 2;
}

class CompanionInitiativeClock {
  const CompanionInitiativeClock({required this.wallMs, required this.monoMs});

  final int wallMs;
  final int monoMs;

  bool get _valid =>
      wallMs >= 0 &&
      monoMs >= 0 &&
      wallMs <= _maxSafeInteger - CompanionInitiativeRules.windowMs &&
      monoMs <= _maxSafeInteger - CompanionInitiativeRules.windowMs;

  Map<String, Object?> toJson() => {'wallMs': wallMs, 'monoMs': monoMs};
}

/// Only use newLedger after storage has confirmed that the key is absent.
/// An unavailable or malformed ledger closes optional prompts for this owner.
class CompanionInitiativeRestore {
  const CompanionInitiativeRestore.newLedger() : _status = 'new', _value = null;
  const CompanionInitiativeRestore.loaded(Object? value) : _status = 'loaded', _value = value;
  const CompanionInitiativeRestore.unavailable() : _status = 'unavailable', _value = null;

  final String _status;
  final Object? _value;
}

class CompanionInitiativeRecord {
  CompanionInitiativeRecord._(this.lastGreetingAtMs, List<int> invites, this.declinedUntilMs)
    : inviteAtMs = List.unmodifiable(invites);

  final int? lastGreetingAtMs;
  final List<int> inviteAtMs;
  final int declinedUntilMs;

  static int? _integer(Object? value) =>
      value is num && value.isFinite && value >= 0 && value <= _maxSafeInteger && value == value.toInt()
      ? value.toInt()
      : null;

  static CompanionInitiativeRecord? _read(Object? value) {
    if (value is! Map || value['v'] != 1 || !value.containsKey('lastGreetingAtMs')) {
      return null;
    }
    // Do not rewrite an unfamiliar record after dropping fields we cannot keep.
    if (value.keys.any((key) => !const {'v', 'lastGreetingAtMs', 'inviteAtMs', 'declinedUntilMs'}.contains(key))) {
      return null;
    }
    final last = value['lastGreetingAtMs'];
    final invites = value['inviteAtMs'];
    final declined = _integer(value['declinedUntilMs']);
    if ((last != null && _integer(last) == null) ||
        invites is! List ||
        invites.length > CompanionInitiativeRules.maxInvites ||
        declined == null) {
      return null;
    }
    final times = <int>[];
    for (final value in invites) {
      final time = _integer(value);
      if (time == null || (times.isNotEmpty && time - times.last < CompanionInitiativeRules.inviteGapMs)) {
        return null;
      }
      times.add(time);
    }
    return CompanionInitiativeRecord._(last == null ? null : _integer(last), times, declined);
  }

  Map<String, Object?> toJson() => {
    'v': 1,
    'lastGreetingAtMs': lastGreetingAtMs,
    'inviteAtMs': List<int>.of(inviteAtMs),
    'declinedUntilMs': declinedUntilMs,
  };
}

/// A complete current observation. contextKey changes on a real mode, binding
/// or view replacement, never on each build, revision or asOf update.
class CompanionInitiativeView {
  const CompanionInitiativeView({
    required this.visible,
    required this.resumed,
    required this.blocked,
    required this.enabled,
    required this.accessible,
    required this.contextKey,
  });

  /// Combine independently observed gates; do not include this controller's
  /// own greeting/invitation slot in externalPromptBusy.
  factory CompanionInitiativeView.room({
    required bool routeVisible,
    required bool stageReady,
    required bool resumed,
    required bool inputBusy,
    required bool generating,
    required bool audioBusy,
    required bool activityBusy,
    required bool approvalPending,
    required bool externalPromptBusy,
    required bool quietHoursBlocked,
    required bool enabled,
    required bool accessible,
    required String contextKey,
  }) => CompanionInitiativeView(
    visible: routeVisible && stageReady,
    resumed: resumed,
    blocked:
        inputBusy ||
        generating ||
        audioBusy ||
        activityBusy ||
        approvalPending ||
        externalPromptBusy ||
        quietHoursBlocked,
    enabled: enabled,
    accessible: accessible,
    contextKey: contextKey,
  );

  final bool visible;
  final bool resumed;
  final bool blocked;
  final bool enabled;
  final bool accessible;
  final String contextKey;

  Map<String, Object?> toJson() => {
    'visible': visible,
    'resumed': resumed,
    'blocked': blocked,
    'enabled': enabled,
    'accessible': accessible,
    'contextKey': contextKey,
  };
}

enum CompanionInitiativeEventType {
  enter,
  leave,
  observe,
  userActivation,
  check,
  present,
  dropOffer,
  accept,
  decline,
  storageFault,
}

class CompanionInitiativeEvent {
  const CompanionInitiativeEvent.enter(CompanionInitiativeView view)
    : this._(CompanionInitiativeEventType.enter, view: view);
  const CompanionInitiativeEvent.leave() : this._(CompanionInitiativeEventType.leave);
  const CompanionInitiativeEvent.observe(CompanionInitiativeView view)
    : this._(CompanionInitiativeEventType.observe, view: view);
  const CompanionInitiativeEvent.userActivation() : this._(CompanionInitiativeEventType.userActivation);
  const CompanionInitiativeEvent.check() : this._(CompanionInitiativeEventType.check);
  const CompanionInitiativeEvent.present(String ticketId)
    : this._(CompanionInitiativeEventType.present, ticketId: ticketId);
  const CompanionInitiativeEvent.dropOffer(String ticketId)
    : this._(CompanionInitiativeEventType.dropOffer, ticketId: ticketId);
  const CompanionInitiativeEvent.accept(String ticketId)
    : this._(CompanionInitiativeEventType.accept, ticketId: ticketId);
  const CompanionInitiativeEvent.decline([String? ticketId])
    : this._(CompanionInitiativeEventType.decline, ticketId: ticketId);
  const CompanionInitiativeEvent.storageFault() : this._(CompanionInitiativeEventType.storageFault);

  const CompanionInitiativeEvent._(this.type, {this.view, this.ticketId});
  final CompanionInitiativeEventType type;
  final CompanionInitiativeView? view;
  final String? ticketId;
}

enum CompanionPromptKind { greeting, invite }

class CompanionInitiativeTicket {
  const CompanionInitiativeTicket._(this.id, this.kind, this.ownerEpoch, this.stayId, this.contextKey);

  final String id;
  final CompanionPromptKind kind;
  final int ownerEpoch;
  final int stayId;
  final String contextKey;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'ownerEpoch': ownerEpoch,
    'stayId': stayId,
    'contextKey': contextKey,
  };
}

class CompanionInitiativeDisplay {
  const CompanionInitiativeDisplay._(this.ticket, this.committedAtWallMs, this.expiresAtMono);

  final CompanionInitiativeTicket ticket;
  final int committedAtWallMs;
  final int? expiresAtMono;

  Map<String, Object?> toJson() => {
    ...ticket.toJson(),
    'committedAtWallMs': committedAtWallMs,
    'expiresAtMono': expiresAtMono,
  };
}

enum CompanionInitiativeEffectType { offer, cancelOffer, show, hide, updateTimeout, persist, restIntent }

class CompanionInitiativeEffect {
  const CompanionInitiativeEffect._(
    this.type, {
    this.ticket,
    this.display,
    this.ticketId,
    this.reason,
    this.expiresAtMono,
    this.record,
    this.contextKey,
    this.ownerEpoch,
  });

  final CompanionInitiativeEffectType type;
  final CompanionInitiativeTicket? ticket;
  final CompanionInitiativeDisplay? display;
  final String? ticketId;
  final String? reason;
  final int? expiresAtMono;
  final CompanionInitiativeRecord? record;
  final String? contextKey;
  final int? ownerEpoch;

  Map<String, Object?> toJson() => switch (type) {
    CompanionInitiativeEffectType.offer => {'type': type.name, 'ticket': ticket!.toJson()},
    CompanionInitiativeEffectType.show => {
      'type': type.name,
      'display': display!.toJson(),
      'silent': true,
      'autoAnnounce': false,
    },
    CompanionInitiativeEffectType.cancelOffer ||
    CompanionInitiativeEffectType.hide => {'type': type.name, 'ticketId': ticketId, 'reason': reason},
    CompanionInitiativeEffectType.updateTimeout => {
      'type': type.name,
      'ticketId': ticketId,
      'expiresAtMono': expiresAtMono,
    },
    CompanionInitiativeEffectType.persist => {'type': type.name, 'value': record!.toJson()},
    CompanionInitiativeEffectType.restIntent => {
      'type': type.name,
      'ticketId': ticketId,
      'contextKey': contextKey,
      'ownerEpoch': ownerEpoch,
    },
  };
}

class _Stay {
  _Stay(this.id) : interacted = false, invited = false;
  _Stay.copy(_Stay value) : id = value.id, interacted = value.interacted, invited = value.invited;

  final int id;
  bool interacted;
  bool invited;
  Map<String, Object?> toJson() => {'id': id, 'interacted': interacted, 'invited': invited};
}

class _State {
  _State(this.lastNow, CompanionInitiativeRestore restored) {
    if (restored._status == 'new') {
      record = CompanionInitiativeRecord._(null, [], 0);
    } else if (restored._status != 'loaded') {
      fault = 'ledger-unavailable';
    } else {
      record = CompanionInitiativeRecord._read(restored._value);
      if (record == null) {
        fault = 'ledger-invalid';
      } else if ((record!.lastGreetingAtMs != null && record!.lastGreetingAtMs! > lastNow.wallMs) ||
          record!.inviteAtMs.any((t) => t > lastNow.wallMs)) {
        fault = 'history-in-future';
      }
    }
  }

  _State.copy(_State value)
    : record = value.record,
      fault = value.fault,
      lastNow = value.lastNow,
      inRoom = value.inRoom,
      outsideSinceMono = value.outsideSinceMono,
      view = value.view,
      ownerEpoch = value.ownerEpoch,
      nextStay = value.nextStay,
      nextTicket = value.nextTicket,
      stay = value.stay == null ? null : _Stay.copy(value.stay!),
      quietSinceMono = value.quietSinceMono,
      ticket = value.ticket,
      display = value.display;

  CompanionInitiativeRecord? record;
  String? fault;
  CompanionInitiativeClock lastNow;
  bool inRoom = false;
  int? outsideSinceMono;
  CompanionInitiativeView? view;
  int ownerEpoch = 0;
  int nextStay = 1;
  int nextTicket = 1;
  _Stay? stay;
  int? quietSinceMono;
  CompanionInitiativeTicket? ticket;
  CompanionInitiativeDisplay? display;

  bool get eligible =>
      fault == null && inRoom && (view?.visible ?? false) && view!.resumed && !view!.blocked && view!.enabled;
  bool get quietEligible => eligible && stay != null && !stay!.interacted && !stay!.invited;

  Map<String, Object?> toJson() => {
    'record': record?.toJson(),
    'fault': fault,
    'lastNow': lastNow.toJson(),
    'inRoom': inRoom,
    'outsideSinceMono': outsideSinceMono,
    'view': view?.toJson(),
    'ownerEpoch': ownerEpoch,
    'nextStay': nextStay,
    'nextTicket': nextTicket,
    'stay': stay?.toJson(),
    'quietSinceMono': quietSinceMono,
    'ticket': ticket?.toJson(),
    'display': display?.toJson(),
  };
}

/// Synchronous transitions install the latest state before returning effects.
/// Host/mode bindings, lifecycle observations, rendering and serialized ledger
/// writes remain the App owner's responsibility. This is not a multiwriter lock.
class CompanionInitiativeController {
  CompanionInitiativeController({required CompanionInitiativeClock now, required CompanionInitiativeRestore restored}) {
    if (!now._valid) throw ArgumentError('Expected safe nonnegative wallMs and monoMs');
    _state = _State(now, restored);
  }

  late _State _state;
  String? get fault => _state.fault;
  CompanionInitiativeRecord? get record => _state.record;
  CompanionInitiativeTicket? get offer => _state.ticket;
  CompanionInitiativeDisplay? get display => _state.display;

  /// Detached diagnostic state, including ephemeral context. Persist only the
  /// record supplied by a persist effect, not this process-local snapshot.
  Map<String, Object?> inspect() => _state.toJson();

  List<CompanionInitiativeEffect> handle(CompanionInitiativeEvent event, CompanionInitiativeClock now) {
    final s = _State.copy(_state);
    final effects = <CompanionInitiativeEffect>[];
    if (!now._valid || now.monoMs < s.lastNow.monoMs || now.wallMs < s.lastNow.wallMs) {
      _block(s, effects, 'clock-invalid-or-regressed');
      _state = s;
      return List.unmodifiable(effects);
    }
    s.lastNow = now;
    final viewEvent =
        event.type == CompanionInitiativeEventType.enter || event.type == CompanionInitiativeEventType.observe;
    if (!viewEvent) _expire(s, now, effects);

    switch (event.type) {
      case CompanionInitiativeEventType.enter:
        final wasInRoom = s.inRoom;
        final newStay =
            s.stay == null ||
            (!wasInRoom &&
                s.outsideSinceMono != null &&
                now.monoMs - s.outsideSinceMono! >= CompanionInitiativeRules.newStayAbsenceMs);
        if (!wasInRoom) {
          s.inRoom = true;
          s.ownerEpoch++;
          s.quietSinceMono = null;
          _cancel(s, effects, 'enter');
        }
        s.outsideSinceMono = null;
        _applyView(s, event.view!, now, effects);
        if (newStay) {
          s.stay = _Stay(s.nextStay++);
          // A greeting is evaluated only here. It is not retried after awaits.
          if (s.eligible && _greetingAllows(s, now.wallMs)) _offer(s, CompanionPromptKind.greeting, effects);
        }
      case CompanionInitiativeEventType.leave:
        if (s.inRoom) {
          s.inRoom = false;
          s.outsideSinceMono = now.monoMs;
          s.ownerEpoch++;
          s.quietSinceMono = null;
          _cancel(s, effects, 'leave');
        }
      case CompanionInitiativeEventType.observe:
        _applyView(s, event.view!, now, effects);
      case CompanionInitiativeEventType.userActivation:
        _userAction(s, effects);
      case CompanionInitiativeEventType.dropOffer:
        if (s.ticket?.id == event.ticketId) {
          effects.add(
            CompanionInitiativeEffect._(
              CompanionInitiativeEffectType.cancelOffer,
              ticketId: s.ticket!.id,
              reason: 'adapter-discarded',
            ),
          );
          s.ticket = null;
        }
      case CompanionInitiativeEventType.decline:
        if (!s.inRoom || (event.ticketId != null && !_currentInvite(s, event.ticketId))) break;
        _userAction(s, effects);
        if (s.fault == null && s.record != null) {
          final r = s.record!;
          final deadline = now.wallMs + CompanionInitiativeRules.inviteGapMs;
          s.record = CompanionInitiativeRecord._(
            r.lastGreetingAtMs,
            r.inviteAtMs,
            deadline > r.declinedUntilMs ? deadline : r.declinedUntilMs,
          );
          _persist(s, effects);
        }
      case CompanionInitiativeEventType.accept:
        if (!s.eligible || !_currentInvite(s, event.ticketId)) break;
        final accepted = s.display!.ticket;
        _userAction(s, effects);
        effects.add(
          CompanionInitiativeEffect._(
            CompanionInitiativeEffectType.restIntent,
            ticketId: accepted.id,
            contextKey: accepted.contextKey,
            ownerEpoch: accepted.ownerEpoch,
          ),
        );
      case CompanionInitiativeEventType.present:
        final ticket = s.ticket;
        if (ticket == null || ticket.id != event.ticketId) break;
        s.ticket = null;
        final current =
            s.eligible &&
            s.display == null &&
            ticket.ownerEpoch == s.ownerEpoch &&
            ticket.stayId == s.stay?.id &&
            ticket.contextKey == s.view!.contextKey;
        final allowed =
            current &&
            (ticket.kind == CompanionPromptKind.greeting
                ? _greetingAllows(s, now.wallMs)
                : s.quietEligible &&
                      s.quietSinceMono != null &&
                      now.monoMs - s.quietSinceMono! >= CompanionInitiativeRules.quietMs &&
                      _inviteAllows(s, now.wallMs));
        if (!allowed) {
          effects.add(
            CompanionInitiativeEffect._(
              CompanionInitiativeEffectType.cancelOffer,
              ticketId: ticket.id,
              reason: 'present-rejected',
            ),
          );
          break;
        }
        final r = s.record!;
        if (ticket.kind == CompanionPromptKind.greeting) {
          s.record = CompanionInitiativeRecord._(now.wallMs, r.inviteAtMs, r.declinedUntilMs);
        } else {
          s.record = CompanionInitiativeRecord._(r.lastGreetingAtMs, [
            ..._recent(r, now.wallMs),
            now.wallMs,
          ], r.declinedUntilMs);
          s.stay!.invited = true;
        }
        s.display = CompanionInitiativeDisplay._(
          ticket,
          now.wallMs,
          s.view!.accessible ? null : now.monoMs + CompanionInitiativeRules.promptMs,
        );
        effects.add(CompanionInitiativeEffect._(CompanionInitiativeEffectType.show, display: s.display));
        _persist(s, effects);
      case CompanionInitiativeEventType.storageFault:
        _block(s, effects, 'storage-failed');
      case CompanionInitiativeEventType.check:
        break;
    }
    if (viewEvent) _expire(s, now, effects);
    if (!s.quietEligible) {
      s.quietSinceMono = null;
    } else {
      s.quietSinceMono ??= now.monoMs;
    }
    // Stale button/present callbacks never manufacture a fresh ticket.
    if (viewEvent || event.type == CompanionInitiativeEventType.check) {
      if (s.quietEligible &&
          s.quietSinceMono != null &&
          now.monoMs - s.quietSinceMono! >= CompanionInitiativeRules.quietMs &&
          _inviteAllows(s, now.wallMs)) {
        _offer(s, CompanionPromptKind.invite, effects);
      }
    }
    _state = s;
    return List.unmodifiable(effects);
  }

  static void _cancel(_State s, List<CompanionInitiativeEffect> effects, String reason) {
    if (s.ticket != null) {
      effects.add(
        CompanionInitiativeEffect._(CompanionInitiativeEffectType.cancelOffer, ticketId: s.ticket!.id, reason: reason),
      );
    }
    if (s.display != null) {
      effects.add(
        CompanionInitiativeEffect._(CompanionInitiativeEffectType.hide, ticketId: s.display!.ticket.id, reason: reason),
      );
    }
    s.ticket = null;
    s.display = null;
  }

  static void _block(_State s, List<CompanionInitiativeEffect> effects, String reason) {
    s.fault ??= reason;
    s.quietSinceMono = null;
    _cancel(s, effects, reason);
  }

  static void _applyView(
    _State s,
    CompanionInitiativeView view,
    CompanionInitiativeClock now,
    List<CompanionInitiativeEffect> effects,
  ) {
    if (view.contextKey.isEmpty) throw ArgumentError('Expected a nonempty contextKey');
    if (s.view?.contextKey != view.contextKey) {
      s.ownerEpoch++;
      s.quietSinceMono = null;
      _cancel(s, effects, 'context-changed');
    }
    final oldAccessible = s.view?.accessible;
    s.view = view;
    if (!s.eligible) {
      s.quietSinceMono = null;
      _cancel(s, effects, 'not-presentable');
    } else if (s.display != null && oldAccessible != view.accessible) {
      final display = s.display!;
      final expiry = view.accessible ? null : now.monoMs + CompanionInitiativeRules.promptMs;
      s.display = CompanionInitiativeDisplay._(display.ticket, display.committedAtWallMs, expiry);
      effects.add(
        CompanionInitiativeEffect._(
          CompanionInitiativeEffectType.updateTimeout,
          ticketId: display.ticket.id,
          expiresAtMono: expiry,
        ),
      );
    }
  }

  static void _offer(_State s, CompanionPromptKind kind, List<CompanionInitiativeEffect> effects) {
    if (s.ticket != null || s.display != null) return;
    s.ticket = CompanionInitiativeTicket._('${s.nextTicket++}', kind, s.ownerEpoch, s.stay!.id, s.view!.contextKey);
    effects.add(CompanionInitiativeEffect._(CompanionInitiativeEffectType.offer, ticket: s.ticket));
  }

  static List<int> _recent(CompanionInitiativeRecord record, int wallMs) =>
      record.inviteAtMs.where((t) => t > wallMs - CompanionInitiativeRules.windowMs).toList();

  static bool _inviteAllows(_State s, int wallMs) {
    final r = s.record;
    if (r == null || wallMs < r.declinedUntilMs) return false;
    return _recent(r, wallMs).length < CompanionInitiativeRules.maxInvites &&
        (r.inviteAtMs.isEmpty || wallMs - r.inviteAtMs.last >= CompanionInitiativeRules.inviteGapMs);
  }

  static bool _greetingAllows(_State s, int wallMs) =>
      s.record != null &&
      (s.record!.lastGreetingAtMs == null ||
          wallMs - s.record!.lastGreetingAtMs! >= CompanionInitiativeRules.greetingGapMs);

  static void _persist(_State s, List<CompanionInitiativeEffect> effects) =>
      effects.add(CompanionInitiativeEffect._(CompanionInitiativeEffectType.persist, record: s.record));

  static void _userAction(_State s, List<CompanionInitiativeEffect> effects) {
    if (!s.inRoom || s.stay == null) return;
    s.stay!.interacted = true;
    s.quietSinceMono = null;
    _cancel(s, effects, 'user-action');
  }

  static bool _currentInvite(_State s, String? id) =>
      s.display?.ticket.id == id &&
      s.display != null &&
      s.display!.ticket.kind == CompanionPromptKind.invite &&
      s.display!.ticket.ownerEpoch == s.ownerEpoch &&
      s.display!.ticket.stayId == s.stay?.id;

  static void _expire(_State s, CompanionInitiativeClock now, List<CompanionInitiativeEffect> effects) {
    final display = s.display;
    if (display != null && display.expiresAtMono != null && now.monoMs >= display.expiresAtMono!) {
      effects.add(
        CompanionInitiativeEffect._(CompanionInitiativeEffectType.hide, ticketId: display.ticket.id, reason: 'timeout'),
      );
      s.display = null;
    }
  }
}
