import 'dart:convert';

import 'package:dsh_app/companion/companion_initiative.dart';
import 'package:dsh_app/companion/companion_initiative_owner.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Both clocks, moved by the test together with the fake timers.
class _Clock {
  int wall = 1793899800000;
  int mono = 0;

  CompanionInitiativeClock call() => CompanionInitiativeClock(wallMs: wall, monoMs: mono);
}

class _Room implements CompanionInitiativeRoom {
  bool presentable = true;
  final offered = <CompanionInitiativeTicket>[];
  final shown = <CompanionInitiativeDisplay>[];
  final hidden = <String>[];
  final rests = <CompanionInitiativeEffect>[];
  final retimed = <int?>[];

  /// Offered invitations; a welcome is offered too on a new visit, and dropped.
  Iterable<CompanionInitiativeTicket> get invites => offered.where((t) => t.kind == CompanionPromptKind.invite);

  @override
  bool canPresent(CompanionInitiativeTicket ticket) {
    offered.add(ticket);
    return presentable && ticket.kind == CompanionPromptKind.invite;
  }

  @override
  void show(CompanionInitiativeDisplay display) => shown.add(display);

  @override
  void hide(String ticketId) => hidden.add(ticketId);

  @override
  void retime(String ticketId, int? expiresAtMono) => retimed.add(expiresAtMono);

  @override
  void rest(CompanionInitiativeEffect intent) => rests.add(intent);
}

CompanionInitiativeView _view({
  bool visible = true,
  bool blocked = false,
  bool enabled = true,
  bool accessible = false,
  String key = 'room-a',
}) => CompanionInitiativeView(
  visible: visible,
  resumed: true,
  blocked: blocked,
  enabled: enabled,
  accessible: accessible,
  contextKey: key,
);

Future<CompanionInitiative> _owner(WidgetTester tester, _Clock clock) async {
  final container = ProviderContainer(overrides: [companionInitiativeClockProvider.overrideWithValue(clock.call)]);
  addTearDown(container.dispose);
  final owner = container.read(companionInitiativeProvider);
  await tester.runAsync(() => owner.ready);
  return owner;
}

/// Time passes for the clocks and the timers alike, a second at a time.
Future<void> _pass(
  WidgetTester tester,
  _Clock clock,
  Duration time, {
  Duration step = const Duration(seconds: 1),
}) async {
  var left = time;
  while (left > Duration.zero) {
    final d = left < step ? left : step;
    clock
      ..wall += d.inMilliseconds
      ..mono += d.inMilliseconds;
    await tester.pump(d);
    left -= d;
  }
}

Future<Map<String, Object?>?> _ledger(WidgetTester tester) async {
  // Let the queued write land.
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(companionInitiativeKey);
  return raw == null ? null : jsonDecode(raw) as Map<String, Object?>;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('after 45 s of quiet she invites once; it goes by itself after 8 s and is kept', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    expect(owner.fault, isNull);
    final room = _Room();
    owner.enter(room, _view());

    await _pass(tester, clock, const Duration(seconds: 44));
    expect(room.shown, isEmpty);
    await _pass(tester, clock, const Duration(seconds: 2));
    expect(room.shown, hasLength(1));
    final display = room.shown.single;
    expect(display.ticket.kind, CompanionPromptKind.invite);
    expect(display.expiresAtMono, isNotNull);

    final ledger = await _ledger(tester);
    expect(ledger?['inviteAtMs'], [display.committedAtWallMs]);

    await _pass(tester, clock, const Duration(seconds: 9));
    expect(room.hidden, [display.ticket.id]);
    // One per visit: a long quiet afterwards brings no second one.
    await _pass(tester, clock, const Duration(minutes: 5), step: const Duration(seconds: 30));
    expect(room.shown, hasLength(1));
    owner.dispose();
  });

  testWidgets('anything the person does first means no invitation this visit', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 30));
    owner.activate(room);
    await _pass(tester, clock, const Duration(minutes: 3), step: const Duration(seconds: 5));
    expect(room.invites, isEmpty);
    expect(room.shown, isEmpty);
    owner.dispose();
  });

  testWidgets('only an unbroken quiet stretch counts', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 40));
    // Her words on screen for a while: the stretch starts over after them.
    owner.observe(room, _view(blocked: true));
    await _pass(tester, clock, const Duration(seconds: 10));
    owner.observe(room, _view());
    await _pass(tester, clock, const Duration(seconds: 40));
    expect(room.shown, isEmpty);
    await _pass(tester, clock, const Duration(seconds: 6));
    expect(room.shown, hasLength(1));
    owner.dispose();
  });

  testWidgets('a room that can not show it drops it; nothing is spent', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room()..presentable = false;
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 50));
    expect(room.invites, hasLength(1));
    expect(room.shown, isEmpty);
    expect(await _ledger(tester), isNull);
    owner.dispose();
  });

  testWidgets('switched off: none; a screen reader holds it until answered', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view(enabled: false));
    await _pass(tester, clock, const Duration(seconds: 50));
    expect(room.invites, isEmpty);

    owner.observe(room, _view(accessible: true));
    await _pass(tester, clock, const Duration(seconds: 46));
    expect(room.shown, hasLength(1));
    expect(room.shown.single.expiresAtMono, isNull);
    await _pass(tester, clock, const Duration(seconds: 30));
    expect(room.hidden, isEmpty);

    // The reader goes away: from now, the usual few seconds.
    owner.observe(room, _view());
    expect(room.retimed.single, isNotNull);
    await _pass(tester, clock, const Duration(seconds: 9));
    expect(room.hidden, hasLength(1));
    owner.dispose();
  });

  testWidgets('not now: hidden, and six quiet hours are kept on the phone', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 46));
    final id = room.shown.single.ticket.id;

    expect(owner.decline(room, id, _view()), isTrue);
    expect(room.hidden, [id]);
    expect(room.rests, isEmpty);
    final ledger = await _ledger(tester);
    expect(ledger?['declinedUntilMs'], clock.wall + CompanionInitiativeRules.inviteGapMs);
    // A second tap on a button already gone answers nothing.
    expect(owner.decline(room, id, _view()), isFalse);
    owner.dispose();
  });

  testWidgets('yes: one rest for the room, however often it is tapped', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 46));
    final display = room.shown.single;

    expect(owner.accept(room, display.ticket.id, _view()), isTrue);
    expect(owner.accept(room, display.ticket.id, _view()), isFalse);
    expect(room.rests, hasLength(1));
    expect(room.rests.single.ticketId, display.ticket.id);
    expect(room.rests.single.contextKey, 'room-a');
    expect(room.hidden, [display.ticket.id]);
    owner.dispose();
  });

  testWidgets('a yes after the room changed reaches nothing', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 46));
    final id = room.shown.single.ticket.id;

    // Light → full: the button belongs to the room before.
    expect(owner.accept(room, id, _view(key: 'room-b')), isFalse);
    expect(room.rests, isEmpty);
    expect(room.hidden, [id]);
    owner.dispose();
  });

  testWidgets('after a no, the next visit waits out the six hours before asking again', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 46));
    owner.decline(room, room.shown.single.ticket.id, _view());
    owner.leave(room);

    // Back after an hour: a new visit, but still inside the six hours.
    await _pass(tester, clock, const Duration(hours: 1), step: const Duration(minutes: 10));
    final again = _Room();
    owner.enter(again, _view(key: 'room-c'));
    await _pass(tester, clock, const Duration(hours: 4), step: const Duration(minutes: 10));
    expect(again.shown, isEmpty);
    // The wakeup lands when the six hours are up, not before.
    await _pass(tester, clock, const Duration(hours: 1, minutes: 10), step: const Duration(minutes: 10));
    expect(again.shown, hasLength(1));
    owner.dispose();
  });

  testWidgets('a ledger it can not read closes invitations and is left as it was', (tester) async {
    for (final saved in ['not json', '{"v":1,"lastGreetingAtMs":null,"inviteAtMs":[],"declinedUntilMs":0,"x":1}']) {
      SharedPreferences.setMockInitialValues({companionInitiativeKey: saved});
      final clock = _Clock();
      final owner = await _owner(tester, clock);
      expect(owner.fault, isNotNull, reason: saved);
      final room = _Room();
      owner.enter(room, _view());
      await _pass(tester, clock, const Duration(seconds: 50));
      expect(room.invites, isEmpty, reason: saved);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(companionInitiativeKey), saved);
      owner.leave(room);
      owner.dispose();
    }
  });

  testWidgets('the switch is on until turned off, and stays as set', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(companionInitiativeEnabledProvider), isNull);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(container.read(companionInitiativeEnabledProvider), isTrue);
    await tester.runAsync(() => container.read(companionInitiativeEnabledProvider.notifier).set(false));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('companion_initiative_enabled'), isFalse);
  });
}
