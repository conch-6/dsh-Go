// The one owner of her invitations for this installation (Pro C452 §2). It
// outlives pages, hosts, modes and stage reloads: the room attaches to it, it
// does not make its own. It restores and writes the ledger, keeps the two
// one-shot wakeups, and hands the controller's effects to the attached room.
// What may be offered, and when, stays the controller's (companion_initiative.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'companion_initiative.dart';

const companionInitiativeKey = 'companion_initiative_v1';
const _enabledKey = 'companion_initiative_enabled';

/// Both clocks for the controller: the wall clock for its day-long quotas, a
/// monotonic one for quiet and display time. Tests drive their own.
final companionInitiativeClockProvider = Provider<CompanionInitiativeClock Function()>((ref) {
  final mono = Stopwatch()..start();
  return () =>
      CompanionInitiativeClock(wallMs: DateTime.now().millisecondsSinceEpoch, monoMs: mono.elapsedMilliseconds);
});

final companionInitiativeProvider = Provider<CompanionInitiative>((ref) {
  final owner = CompanionInitiative(ref.watch(companionInitiativeClockProvider));
  ref.onDispose(owner.dispose);
  return owner;
});

/// Whether she may invite at all. Null until read: an unread switch permits nothing.
class CompanionInitiativeEnabled extends Notifier<bool?> {
  @override
  bool? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (ref.mounted && state == null) state = prefs.getBool(_enabledKey) ?? true;
    } on Object {
      // Stays null: no invitations from a setting nobody could read.
    }
  }

  Future<void> set(bool on) async {
    state = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, on);
  }
}

final companionInitiativeEnabledProvider = NotifierProvider<CompanionInitiativeEnabled, bool?>(
  CompanionInitiativeEnabled.new,
);

/// The room the owner shows things in. Every call is synchronous: a ticket is
/// mounted, or dropped, inside the event that produced it (C452 §6).
abstract interface class CompanionInitiativeRoom {
  /// Whether [ticket] can be shown here right now, by this room.
  bool canPresent(CompanionInitiativeTicket ticket);

  void show(CompanionInitiativeDisplay display);

  void hide(String ticketId);

  /// The shown ticket now ends at [expiresAtMono], or is held (null).
  void retime(String ticketId, int? expiresAtMono);

  /// The person said yes to the invitation [intent] names. Not a rest yet:
  /// the room checks it is still its own and goes through its usual entry.
  void rest(CompanionInitiativeEffect intent);
}

class CompanionInitiative {
  CompanionInitiative(this._now) {
    unawaited(_restore());
  }

  final CompanionInitiativeClock Function() _now;
  CompanionInitiativeController? _controller;
  CompanionInitiativeRoom? _room;
  CompanionInitiativeView? _view;
  bool _disposed = false;

  /// One write at a time, in the order the controller asked for them.
  Future<void> _writes = Future.value();

  /// The quiet stretch the next wakeup was planned from, as this owner saw it:
  /// only to know when to ask, never to decide (C452 §8).
  int? _quietSinceMono;
  int? _wokeForQuiet;
  Timer? _quietWake;
  int? _quietWakeAt;
  Timer? _expiry;
  String? _expiryTicket;

  final _restored = Completer<void>();

  /// Finished restoring, either way.
  Future<void> get ready => _restored.future;

  /// For tests and diagnostics: why invitations are closed for this run, if they are.
  String? get fault =>
      _controller == null ? (_restored.isCompleted ? 'not-restored' : 'restoring') : _controller!.fault;

  Future<void> _restore() async {
    CompanionInitiativeRestore restored;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.get(companionInitiativeKey);
      if (raw == null) {
        restored = const CompanionInitiativeRestore.newLedger();
      } else if (raw is String) {
        Object? value;
        try {
          value = jsonDecode(raw);
        } on FormatException {
          // Handed over as it is: the controller closes on what it can't read.
          value = raw;
        }
        restored = CompanionInitiativeRestore.loaded(value);
      } else {
        restored = CompanionInitiativeRestore.loaded(raw);
      }
    } on Object {
      restored = const CompanionInitiativeRestore.unavailable();
    }
    if (_disposed) return;
    _controller = CompanionInitiativeController(now: _now(), restored: restored);
    _restored.complete();
    // A room that arrived while the ledger was read enters now. The room never
    // shows a welcome (it greets in her own words), so arriving late can't
    // make one late.
    final room = _room;
    final view = _view;
    if (room != null && view != null) _run(CompanionInitiativeEvent.enter(view));
  }

  /// [room] is where the person is now, seen as [view].
  void enter(CompanionInitiativeRoom room, CompanionInitiativeView view) {
    if (!identical(_room, room) && _room != null) _run(const CompanionInitiativeEvent.leave());
    _room = room;
    _view = view;
    _run(CompanionInitiativeEvent.enter(view));
  }

  /// The person left the room ([room]): what they did to leave counts first.
  void leave(CompanionInitiativeRoom room) {
    if (!identical(_room, room)) return;
    _run(const CompanionInitiativeEvent.userActivation());
    _run(const CompanionInitiativeEvent.leave());
    _room = null;
    _view = null;
  }

  void observe(CompanionInitiativeRoom room, CompanionInitiativeView view) {
    if (!identical(_room, room)) return;
    _view = view;
    _run(CompanionInitiativeEvent.observe(view));
  }

  /// Something the person really did in the room: no invitation this stay.
  void activate(CompanionInitiativeRoom room) {
    if (!identical(_room, room)) return;
    _run(const CompanionInitiativeEvent.userActivation());
  }

  /// The invitation's own buttons: the current facts first, then the answer.
  /// Not preceded by a generic activation; the controller counts it (C452 §5.2).
  /// Whether the answer reached a current invitation.
  bool accept(CompanionInitiativeRoom room, String ticketId, CompanionInitiativeView view) =>
      _answer(room, ticketId, view, CompanionInitiativeEvent.accept(ticketId));

  bool decline(CompanionInitiativeRoom room, String ticketId, CompanionInitiativeView view) =>
      _answer(room, ticketId, view, CompanionInitiativeEvent.decline(ticketId));

  bool _answer(
    CompanionInitiativeRoom room,
    String ticketId,
    CompanionInitiativeView view,
    CompanionInitiativeEvent answer,
  ) {
    if (!identical(_room, room)) return false;
    _view = view;
    _run(CompanionInitiativeEvent.observe(view));
    // The fresh look may have retired it already: then there is nothing to answer.
    if (_controller?.display?.ticket.id != ticketId) return false;
    _run(answer);
    return true;
  }

  void _run(CompanionInitiativeEvent event) {
    final controller = _controller;
    if (controller == null || _disposed) return;
    _apply(controller, controller.handle(event, _now()));
    _track(event);
    _plan(controller);
  }

  void _apply(CompanionInitiativeController controller, List<CompanionInitiativeEffect> effects) {
    for (final effect in effects) {
      switch (effect.type) {
        case CompanionInitiativeEffectType.offer:
          final ticket = effect.ticket!;
          final room = _room;
          // Mounted now or never: nothing waits to be shown later.
          final next = room != null && room.canPresent(ticket)
              ? CompanionInitiativeEvent.present(ticket.id)
              : CompanionInitiativeEvent.dropOffer(ticket.id);
          _apply(controller, controller.handle(next, _now()));
        case CompanionInitiativeEffectType.show:
          final display = effect.display!;
          _room?.show(display);
          _arm(display.ticket.id, display.expiresAtMono);
        case CompanionInitiativeEffectType.hide:
          if (_expiryTicket == effect.ticketId) _disarm();
          _room?.hide(effect.ticketId!);
        case CompanionInitiativeEffectType.updateTimeout:
          if (controller.display?.ticket.id == effect.ticketId) _arm(effect.ticketId!, effect.expiresAtMono);
          _room?.retime(effect.ticketId!, effect.expiresAtMono);
        case CompanionInitiativeEffectType.persist:
          _write(effect.record!);
        case CompanionInitiativeEffectType.restIntent:
          _room?.rest(effect);
        case CompanionInitiativeEffectType.cancelOffer:
          break;
      }
    }
  }

  /// The whole record, after every earlier write. A failed write closes
  /// invitations for this run; a late success can't reopen them.
  void _write(CompanionInitiativeRecord record) {
    final value = jsonEncode(record.toJson());
    _writes = _writes.then((_) async {
      bool ok;
      try {
        final prefs = await SharedPreferences.getInstance();
        ok = await prefs.setString(companionInitiativeKey, value);
      } on Object {
        ok = false;
      }
      if (!ok) _run(const CompanionInitiativeEvent.storageFault());
    });
  }

  // ── Wakeups (C452 §8) ────────────────────────────────────────────────────

  static bool _quietLooking(CompanionInitiativeView? view) =>
      view != null && view.visible && view.resumed && !view.blocked && view.enabled;

  String? _trackedContext;

  /// Follows the quiet stretch the way the controller does, from the same
  /// events, so the wakeup lands when it could first matter.
  void _track(CompanionInitiativeEvent event) {
    final view = _view;
    final contextKey = view?.contextKey;
    final restart =
        event.type == CompanionInitiativeEventType.userActivation ||
        event.type == CompanionInitiativeEventType.leave ||
        event.type == CompanionInitiativeEventType.accept ||
        event.type == CompanionInitiativeEventType.decline ||
        contextKey != _trackedContext ||
        !_quietLooking(view) ||
        _room == null;
    _trackedContext = contextKey;
    if (restart) {
      _quietSinceMono = null;
      if (!_quietLooking(view) || _room == null) return;
    }
    _quietSinceMono ??= _now().monoMs;
  }

  void _plan(CompanionInitiativeController controller) {
    final since = _quietSinceMono;
    if (controller.fault != null ||
        since == null ||
        since == _wokeForQuiet ||
        controller.display != null ||
        controller.offer != null) {
      _cancelQuietWake();
      return;
    }
    final now = _now();
    final record = controller.record;
    var gate = 0;
    if (record != null) {
      final recent = record.inviteAtMs.where((t) => t > now.wallMs - CompanionInitiativeRules.windowMs).toList();
      gate = max(gate, record.declinedUntilMs);
      if (record.inviteAtMs.isNotEmpty) gate = max(gate, record.inviteAtMs.last + CompanionInitiativeRules.inviteGapMs);
      if (recent.length >= CompanionInitiativeRules.maxInvites) {
        gate = max(gate, recent.first + CompanionInitiativeRules.windowMs);
      }
    }
    final at = max(since + CompanionInitiativeRules.quietMs, now.monoMs + max<int>(0, gate - now.wallMs));
    if (_quietWake != null && _quietWakeAt == at) return;
    _cancelQuietWake();
    _quietWakeAt = at;
    _quietWake = Timer(Duration(milliseconds: max(0, at - now.monoMs)), () {
      _quietWake = null;
      _quietWakeAt = null;
      final controller = _controller;
      if (controller == null || _disposed) return;
      // Early by the clock the controller reads: wait out the rest.
      if (_now().monoMs < at) return _plan(controller);
      // Once per quiet stretch: a check that offers nothing isn't asked again
      // until the stretch starts over.
      _wokeForQuiet = since;
      _run(const CompanionInitiativeEvent.check());
    });
  }

  void _cancelQuietWake() {
    _quietWake?.cancel();
    _quietWake = null;
    _quietWakeAt = null;
  }

  void _arm(String ticketId, int? expiresAtMono) {
    _disarm();
    if (expiresAtMono == null) return; // Held for accessible navigation.
    _expiryTicket = ticketId;
    _expiry = Timer(Duration(milliseconds: max(0, expiresAtMono - _now().monoMs)), () {
      _expiry = null;
      if (_disposed) return;
      if (_now().monoMs < expiresAtMono) return _arm(ticketId, expiresAtMono);
      _run(const CompanionInitiativeEvent.check());
    });
  }

  void _disarm() {
    _expiry?.cancel();
    _expiry = null;
    _expiryTicket = null;
  }

  void dispose() {
    _disposed = true;
    _cancelQuietWake();
    _disarm();
    _room = null;
  }
}
