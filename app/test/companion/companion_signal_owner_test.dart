import 'dart:convert';

import 'package:dsh_app/companion/companion_initiative.dart';
import 'package:dsh_app/companion/companion_initiative_owner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class FailingStore extends InMemorySharedPreferencesStore {
  FailingStore() : super.empty();
  bool fail = true;
  @override
  Future<bool> setValue(String type, String key, Object value) =>
      fail ? Future.value(false) : super.setValue(type, key, value);
}

class Clock {
  int wall = DateTime.utc(2026, 11, 5, 8).millisecondsSinceEpoch;
  int mono = 0;
  CompanionInitiativeClock call() => CompanionInitiativeClock(wallMs: wall, monoMs: mono);
}

class Room implements CompanionInitiativeRoom {
  bool Function(CompanionInitiativeTicket)? onCan;
  void Function(CompanionInitiativeDisplay)? onShow;
  final shown = <CompanionInitiativeDisplay>[];
  final hidden = <String>[];
  @override
  bool canPresent(CompanionInitiativeTicket t) => t.kind != CompanionPromptKind.greeting && (onCan?.call(t) ?? true);
  @override
  void show(CompanionInitiativeDisplay d) {
    shown.add(d);
    onShow?.call(d);
  }

  @override
  void hide(String id) => hidden.add(id);
  @override
  void retime(String id, int? at) {}
  @override
  void rest(CompanionInitiativeEffect effect) {}
}

CompanionInitiativeView view({String key = 'room', bool blocked = false, bool accessible = false}) =>
    CompanionInitiativeView(
      visible: true,
      resumed: true,
      blocked: blocked,
      enabled: true,
      accessible: accessible,
      contextKey: key,
    );
CompanionInitiativeSignal candidate(Clock clock, {String id = 'signal', int ttl = 120000}) =>
    CompanionInitiativeSignal(id: id, contextKey: 'room', expiresAtMonoMs: clock.mono + ttl);
Future<CompanionInitiative> make(WidgetTester tester, Clock clock) async {
  final owner = CompanionInitiative(clock.call);
  await tester.runAsync(() => owner.ready);
  return owner;
}

Future<void> pass(WidgetTester tester, Clock clock, int ms) async {
  var remaining = ms;
  while (remaining > 0) {
    final amount = remaining > 1000 ? 1000 : remaining;
    clock.wall += amount;
    clock.mono += amount;
    await tester.pump(Duration(milliseconds: amount));
    remaining -= amount;
  }
}

Future<Map<String, dynamic>> saved(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  return jsonDecode((await SharedPreferences.getInstance()).getString(companionInitiativeKey)!) as Map<String, dynamic>;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('signal cannot accept an invitation but can decline into the shared refusal', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    final shown = <CompanionInitiativeDisplay>[];
    final hidden = <String>[];
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () => true,
      present: (d) {
        shown.add(d);
        return true;
      },
      hide: hidden.add,
    );
    await pass(tester, clock, 46000);
    final id = shown.single.ticket.id;
    expect(owner.accept(room, id, view()), isFalse);
    expect(hidden, isEmpty);
    expect(owner.decline(room, id, view()), isTrue);
    expect(hidden, [id]);
    expect(owner.decline(room, id, view()), isFalse);
    final ledger = await saved(tester);
    expect(ledger['declinedUntilMs'], clock.wall + CompanionInitiativeRules.inviteGapMs);
    expect(ledger['signalAtMs'], [shown.single.committedAtWallMs]);
    owner.requestSignal(
      room,
      view(),
      candidate(clock, id: 'next'),
      isCurrent: () => true,
      present: (d) {
        shown.add(d);
        return true;
      },
      hide: hidden.add,
    );
    await pass(tester, clock, 46000);
    expect(shown, hasLength(1));
    owner.dispose();
  });

  testWidgets('last current callback crosses 23:00 and fresh staging rejects the ordinary signal', (tester) async {
    final clock = Clock()..wall = DateTime.utc(2026, 11, 5, 22, 59, 14).millisecondsSinceEpoch;
    final owner = await make(tester, clock);
    final room = Room();
    var cross = false;
    var renders = 0;
    room.onCan = (ticket) {
      cross = ticket.kind == CompanionPromptKind.signal;
      return true;
    };
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () {
        if (cross) {
          cross = false;
          clock.wall += 2000;
          clock.mono += 2000;
        }
        return true;
      },
      present: (_) {
        renders++;
        return true;
      },
      hide: (_) {},
    );
    await pass(tester, clock, 46000);
    expect(renders, 0);
    expect((await saved(tester))['signalAtMs'], isEmpty);
    owner.dispose();
  });

  testWidgets('a failed durable write closes the owner even if storage later recovers', (tester) async {
    final original = SharedPreferencesStorePlatform.instance;
    final store = FailingStore();
    SharedPreferencesStorePlatform.instance = store;
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    try {
      owner.enter(room, view());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(owner.fault, 'storage-failed');
      store.fail = false;
      owner.observe(room, view());
      await pass(tester, clock, 46000);
      expect(room.shown, isEmpty);
      expect(owner.fault, 'storage-failed');
    } finally {
      owner.dispose();
      SharedPreferencesStorePlatform.instance = original;
    }
  });

  testWidgets('unbounded observer reentrancy closes after a bounded queue drain', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    var checks = 0;
    room.onCan = (_) {
      checks++;
      owner.observe(room, view());
      return true;
    };
    owner.enter(room, view());
    await pass(tester, clock, 46000);
    expect(checks, inInclusiveRange(1, 64));
    expect(owner.fault, 'storage-failed');
    expect(room.shown, isEmpty);
    owner.dispose();
  });

  testWidgets('actual local signal display commits exactly once without inviting too', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    final displays = <CompanionInitiativeDisplay>[];
    final hides = <String>[];
    owner.enter(room, view());
    expect(
      owner.requestSignal(
        room,
        view(),
        candidate(clock),
        isCurrent: () => true,
        present: (d) {
          displays.add(d);
          return true;
        },
        hide: hides.add,
      ),
      isTrue,
    );
    await pass(tester, clock, 46000);
    expect(displays, hasLength(1));
    expect(room.shown, isEmpty);
    final ledger = await saved(tester);
    expect(ledger['signalAtMs'], [displays.single.committedAtWallMs]);
    expect(ledger['inviteAtMs'], isEmpty);
    await pass(tester, clock, 8000);
    expect(hides, [displays.single.ticket.id]);
    owner.dispose();
  });

  for (final throws in [false, true]) {
    testWidgets('actual presentation ${throws ? 'throw' : 'false'} never spends quota', (tester) async {
      final clock = Clock();
      final owner = await make(tester, clock);
      final room = Room();
      var attempts = 0;
      final hides = <String>[];
      owner.enter(room, view());
      owner.requestSignal(
        room,
        view(),
        candidate(clock),
        isCurrent: () => true,
        present: (_) {
          attempts++;
          if (throws) throw StateError('partial render');
          return false;
        },
        hide: hides.add,
      );
      await pass(tester, clock, 46000);
      expect(attempts, 1);
      expect(hides, hasLength(1));
      final ledger = await saved(tester);
      expect(ledger['signalAtMs'], isEmpty);
      expect(ledger['inviteAtMs'], isEmpty);
      expect(owner.fault, isNull);
      owner.dispose();
    });
  }

  testWidgets('source withdrawn while waiting is retired before rendering', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    var current = true;
    var renders = 0;
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () => current,
      present: (_) {
        renders++;
        return true;
      },
      hide: (_) {},
    );
    await pass(tester, clock, 30000);
    current = false;
    owner.observe(room, view());
    await pass(tester, clock, 16000);
    expect(renders, 0);
    expect((await saved(tester))['signalAtMs'], isEmpty);
    owner.dispose();
  });

  testWidgets('isCurrent reentrant room replacement cannot resurrect the old recipient', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    final newer = Room();
    var replace = false;
    var renders = 0;
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () {
        if (replace) {
          replace = false;
          owner.enter(newer, view(key: 'new'));
        }
        return true;
      },
      present: (_) {
        renders++;
        return true;
      },
      hide: (_) {},
    );
    replace = true;
    await pass(tester, clock, 46000);
    expect(renders, 0);
    expect((await saved(tester))['signalAtMs'], isEmpty);
    owner.dispose();
  });

  testWidgets('canPresent reentrant source cancellation is checked again before presentation', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    var renders = 0;
    room.onCan = (ticket) {
      if (ticket.kind == CompanionPromptKind.signal) owner.cancelSignal('signal');
      return true;
    };
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () => true,
      present: (_) {
        renders++;
        return true;
      },
      hide: (_) {},
    );
    await pass(tester, clock, 46000);
    expect(renders, 0);
    expect((await saved(tester))['signalAtMs'], isEmpty);
    owner.dispose();
  });

  testWidgets('true display followed by reentrant leave remains charged and hides captured receiver', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    final signalHides = <String>[];
    final displayed = <CompanionInitiativeDisplay>[];
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () => true,
      present: (d) {
        displayed.add(d);
        owner.leave(room);
        return true;
      },
      hide: signalHides.add,
    );
    await pass(tester, clock, 46000);
    expect(displayed, hasLength(1));
    expect(signalHides, [displayed.single.ticket.id]);
    expect(room.hidden, isEmpty);
    expect((await saved(tester))['signalAtMs'], [displayed.single.committedAtWallMs]);
    owner.dispose();
  });

  testWidgets('original gate expiry is retained across repeated observations', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    var renders = 0;
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock, ttl: 30000),
      isCurrent: () => true,
      present: (_) {
        renders++;
        return true;
      },
      hide: (_) {},
    );
    await pass(tester, clock, 20000);
    owner.observe(room, view());
    await pass(tester, clock, 26000);
    expect(renders, 0);
    expect((await saved(tester))['signalAtMs'], isEmpty);
    owner.dispose();
  });

  testWidgets('a restored invitation consumes the signal gap and survives owner restart', (tester) async {
    final clock = Clock();
    SharedPreferences.setMockInitialValues({
      companionInitiativeKey: jsonEncode({
        'v': 1,
        'lastGreetingAtMs': clock.wall,
        'inviteAtMs': [clock.wall - 1000],
        'declinedUntilMs': 0,
      }),
    });
    for (var attempt = 0; attempt < 2; attempt++) {
      final owner = await make(tester, clock);
      final room = Room();
      var renders = 0;
      owner.enter(room, view());
      owner.requestSignal(
        room,
        view(),
        candidate(clock),
        isCurrent: () => true,
        present: (_) {
          renders++;
          return true;
        },
        hide: (_) {},
      );
      await pass(tester, clock, 46000);
      expect(renders, 0);
      final ledger = await saved(tester);
      expect(ledger['inviteAtMs'], hasLength(1));
      expect(ledger['signalAtMs'], isEmpty);
      owner.dispose();
    }
  });

  testWidgets('showing an invitation uses the same render-before-charge protocol', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    room.onShow = (_) => throw StateError('invitation render failed');
    owner.enter(room, view());
    await pass(tester, clock, 46000);
    expect(room.shown, hasLength(1));
    expect(room.hidden, hasLength(1));
    expect((await saved(tester))['inviteAtMs'], isEmpty);
    owner.dispose();
  });

  testWidgets('default local night blocks ordinary signal presentation', (tester) async {
    final clock = Clock()..wall = DateTime.utc(2026, 11, 5, 23).millisecondsSinceEpoch;
    final owner = await make(tester, clock);
    final room = Room();
    var renders = 0;
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () => true,
      present: (_) {
        renders++;
        return true;
      },
      hide: (_) {},
    );
    await pass(tester, clock, 46000);
    expect(renders, 0);
    expect((await saved(tester))['signalAtMs'], isEmpty);
    owner.dispose();
  });
}
