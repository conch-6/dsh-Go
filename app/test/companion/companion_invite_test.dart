// Her invitation to rest, on the page: shown after a quiet stretch, silently,
// above the input; a yes goes through the cushion's own entry, once.

import 'dart:io';

import 'package:dsh_app/companion/companion_initiative.dart';
import 'package:dsh_app/companion/companion_initiative_owner.dart';
import 'package:dsh_app/companion/companion_keeper.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'phone_keeper_fake.dart';

const _invite = '要不要陪我在软垫上歇一会儿？';

class _Room {
  _Room(this.tester, this.root);

  final WidgetTester tester;
  final Directory root;
  final phone = FakePhoneKeeper(state: FakePhoneKeeper.snapshotOf());
  final commands = <(String, Map<String, Object?>)>[];
  CompanionStageEvents? events;

  Iterable<String> get names => commands.map((c) => c.$1);

  Future<void> open() async {
    // A phone reports this long before the room opens; tests start with none,
    // and an unknown state never permits an invitation.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    Directory('${root.path}/pack/runtime').createSync(recursive: true);
    Directory('${root.path}/pack/character').createSync(recursive: true);
    File('${root.path}/pack/runtime/live2dcubismcore.min.js').writeAsStringSync('core');
    File('${root.path}/pack/character/index.json').writeAsStringSync('[]');
    File('${root.path}/pack/character/character.json').writeAsStringSync('{"name":"鲸鱼娘"}');
    // Both clocks follow the test's fake time, timers and all.
    final start = tester.binding.clock.now();
    CompanionInitiativeClock clock() {
      final ms = tester.binding.clock.now().difference(start).inMilliseconds;
      return CompanionInitiativeClock(wallMs: 1793899800000 + ms, monoMs: ms);
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
          companionPhoneKeeperProvider.overrideWithValue((_) => phone as CompanionKeeper),
          companionInitiativeClockProvider.overrideWithValue(clock),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('zh'),
          home: CompanionPage(
            storeOverride: CompanionPackStore(root),
            stageBuilder: (controller, stage) {
              events = stage;
              return const SizedBox.expand();
            },
            stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
          ),
        ),
      ),
    );
    for (var i = 0; i < 100 && events == null; i++) {
      await settle();
    }
    expect(events, isNotNull, reason: 'the stage was never built');
    events!.onReady();
    await settle();
  }

  /// Real file and preference work, then the frames it causes.
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> wait(Duration time) async {
    for (var left = time; left > Duration.zero; left -= const Duration(seconds: 1)) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  Future<void> close() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('companion-invite');
    SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true, 'companion_home_hint_done': true});
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold a file a moment longer; the system clears temp.
    }
  });

  testWidgets('after a quiet while she asks, silently; yes takes her to the cushion once', (tester) async {
    final room = _Room(tester, root);
    await room.open();
    // Her greeting first; the quiet only starts once it's gone.
    // Her greeting is on screen for about five seconds; the quiet starts after it.
    await room.wait(const Duration(seconds: 44));
    expect(find.text(_invite), findsNothing);
    await room.wait(const Duration(seconds: 8));
    expect(find.text(_invite), findsOneWidget);
    expect(room.names, containsAll(['glance', 'beckon']));
    // Nothing spoken for it: no mouth, no words.
    final shownAt = room.commands.lastIndexWhere((c) => c.$1 == 'beckon');
    expect(room.names.skip(shownAt).where((n) => n == 'say'), isEmpty);
    expect(tester.binding.focusManager.primaryFocus?.context?.widget, isNot(isA<EditableText>()));

    await tester.tap(find.text('好呀'));
    await room.settle();
    expect(room.phone.events.where((e) => e == 'rest'), hasLength(1));
    expect(room.commands.where((c) => c.$1 == 'prop').single.$2, {'name': 'rest'});
    expect(room.commands.where((c) => c.$1 == 'beckon').last.$2, {'prop': null});
    await room.wait(const Duration(seconds: 2));
    expect(find.text(_invite), findsNothing);
    expect(find.textContaining(RegExp('歇一小会儿|躺好啦')), findsOneWidget);

    // One per visit.
    await room.wait(const Duration(minutes: 2));
    expect(find.text(_invite), findsNothing);
    await room.close();
  });

  testWidgets('not now: she nods, nothing else happens', (tester) async {
    final room = _Room(tester, root);
    await room.open();
    await room.wait(const Duration(seconds: 52));
    expect(find.text(_invite), findsOneWidget);
    room.commands.clear();

    await tester.tap(find.text('等会儿'));
    await room.settle();
    expect(room.commands.where((c) => c.$1 == 'action').single.$2, {'name': 'nodSmall'});
    expect(room.phone.events, isNot(contains('rest')));
    expect(room.names, isNot(contains('say')));
    await room.wait(const Duration(seconds: 1));
    expect(find.text(_invite), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(companionInitiativeKey), contains('"declinedUntilMs":'));
    await room.close();
  });

  testWidgets('left alone it goes by itself after a few seconds', (tester) async {
    final room = _Room(tester, root);
    await room.open();
    await room.wait(const Duration(seconds: 52));
    expect(find.text(_invite), findsOneWidget);
    await room.wait(const Duration(seconds: 9));
    expect(find.text(_invite), findsNothing);
    expect(room.phone.events, isNot(contains('rest')));
    await room.close();
  });

  testWidgets('touching her first means no invitation this visit', (tester) async {
    final room = _Room(tester, root);
    await room.open();
    await room.wait(const Duration(seconds: 20));
    await tester.tapAt(const Offset(200, 300));
    await room.wait(const Duration(minutes: 2));
    expect(find.text(_invite), findsNothing);
    await room.close();
  });

  testWidgets('switched off in her menu: no invitation', (tester) async {
    SharedPreferences.setMockInitialValues({
      'companion_touch_hint_done': true,
      'companion_home_hint_done': true,
      'companion_initiative_enabled': false,
    });
    final room = _Room(tester, root);
    await room.open();
    await room.wait(const Duration(minutes: 2));
    expect(find.text(_invite), findsNothing);
    await room.close();
  });
}
