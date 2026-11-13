import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/phone/phone_control_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness.dart';
import 'support.dart';

Map<String, Object?> _status([int? candidate]) => {
  ...phoneStatus(a11y: true),
  'skills': {
    'v': 1,
    'askAfterSuccess': true,
    'candidates': [
      if (candidate != null) {'taskId': candidate, 'generation': 1, 'steps': 1},
    ],
  },
};

void _pause(WidgetTester tester) {
  for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void _resume(WidgetTester tester) {
  if (tester.binding.lifecycleState == AppLifecycleState.paused) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('background completion stays manual after resume; a later foreground completion asks', (tester) async {
    _resume(tester);
    final native = FakePhoneNative(status: _status());
    await pumpPhone(tester, const PhoneControlScreen(), native: native);
    _pause(tester);
    native.push(_status(7));
    await settlePhone(tester);
    expect(find.text(appL10n.phoneSkillConfirmGoal), findsNothing);
    _resume(tester);
    await settlePhone(tester);
    expect(find.text(appL10n.phoneSkillConfirmGoal), findsNothing);
    expect(phoneOf(tester).status.skills.candidates.map((candidate) => candidate.taskId), [7]);
    await openPhoneFold(tester, 'phone-more-options');
    final save = find.text(appL10n.phoneSkillSaveAction);
    // AppPage uses a lazy SliverList; ensureVisible requires an already built element.
    await tester.scrollUntilVisible(save, 200, scrollable: find.byType(Scrollable).first);
    expect(save, findsOneWidget);
    // Built is not on screen: the last step can leave it just below the edge.
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text(appL10n.phoneSkillConfirmGoal), findsOneWidget);
    await tester.tap(find.text(appL10n.commonCancel));
    await tester.pumpAndSettle();
    native.push(_status(8));
    await settlePhone(tester);
    expect(find.text(appL10n.phoneSkillConfirmGoal), findsOneWidget);
  });

  for (final alreadyKnown in [false, true]) {
    testWidgets('resume read is a baseline even when its candidate is ${alreadyKnown ? 'unchanged' : 'new'}', (
      tester,
    ) async {
      _resume(tester);
      final native = FakePhoneNative(status: _status(alreadyKnown ? 7 : null));
      await pumpPhone(tester, const PhoneControlScreen(), native: native);
      _pause(tester);
      final read = Completer<Map<String, Object?>>();
      native.onStatus = () => read.future;
      _resume(tester);
      await tester.pump();
      expect(find.text(appL10n.phoneSkillConfirmGoal), findsNothing);
      native.status = _status(7);
      read.complete(native.status);
      await settlePhone(tester);
      expect(find.text(appL10n.phoneSkillConfirmGoal), findsNothing);
      native.onStatus = null;
      native.push(_status(8));
      await settlePhone(tester);
      expect(find.text(appL10n.phoneSkillConfirmGoal), findsOneWidget);
    });
  }

  testWidgets('entering the page with a warm stale provider treats its fresh read as baseline', (tester) async {
    _resume(tester);
    final native = FakePhoneNative(status: _status());
    await pumpPhone(tester, const PhoneControlScreen(), native: native);
    final read = Completer<Map<String, Object?>>();
    native.onStatus = () => read.future;
    final navigator = Navigator.of(tester.element(find.byType(PhoneControlScreen)));
    unawaited(navigator.push<void>(MaterialPageRoute<void>(builder: (_) => const PhoneControlScreen())));
    await tester.pumpAndSettle();
    native.status = _status(7);
    read.complete(native.status);
    await settlePhone(tester);
    expect(find.text(appL10n.phoneSkillConfirmGoal), findsNothing);
    native.onStatus = null;
    native.push(_status(8));
    await settlePhone(tester);
    expect(find.text(appL10n.phoneSkillConfirmGoal), findsOneWidget);
  });

  testWidgets('a queued foreground prompt is revoked by leaving the app before its callback', (tester) async {
    _resume(tester);
    final native = FakePhoneNative(status: _status());
    await pumpPhone(tester, const PhoneControlScreen(), native: native);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pause(tester);
      _resume(tester);
    });
    native.push(_status(7));
    await settlePhone(tester);
    expect(find.text(appL10n.phoneSkillConfirmGoal), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
