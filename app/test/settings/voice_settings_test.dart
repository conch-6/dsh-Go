import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/voice_settings.dart';
import 'package:dsh_app/ui/settings/voice_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  test('saved route is ready before first use and persists across provider recreation', () async {
    SharedPreferences.setMockInitialValues({VoiceSettingsController.preferenceKey: 'engine'});
    final first = ProviderContainer();
    expect(await first.read(voiceSettingsProvider.notifier).ready(), VoiceMode.engine);
    await first.read(voiceSettingsProvider.notifier).setMode(VoiceMode.system);
    first.dispose();
    final next = ProviderContainer();
    addTearDown(next.dispose);
    expect(await next.read(voiceSettingsProvider.notifier).ready(), VoiceMode.system);
    expect((await SharedPreferences.getInstance()).getString(VoiceSettingsController.preferenceKey), 'system');
  });

  test('an unknown stored route safely resolves to automatic', () async {
    SharedPreferences.setMockInitialValues({VoiceSettingsController.preferenceKey: 'future-mode'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(await container.read(voiceSettingsProvider.notifier).ready(), VoiceMode.auto);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('voice choices at 320dp, scale $scale, ${brightness.name} remain selectable', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 800);
        addTearDown(tester.view.reset);
        if (scale == 2) AppLocale.use(AppLocale.en);
        await tester.pumpWidget(
          testApp(
            Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: const VoiceSettingsPage(),
              ),
            ),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        final rows = [for (final mode in VoiceMode.values) find.byKey(ValueKey('voice-mode-${mode.name}'))];
        for (final row in rows) {
          await tester.ensureVisible(row);
          await tester.pumpAndSettle();
          expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
          expect(tester.getRect(row).left, greaterThanOrEqualTo(0));
          expect(tester.getRect(row).right, lessThanOrEqualTo(320));
        }
        // Mid-screen: at the top it would sit under the page's floating header.
        unawaited(
          Scrollable.ensureVisible(tester.element(find.byKey(const ValueKey('voice-mode-engine'))), alignment: 0.5),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('voice-mode-engine')));
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(tester.element(find.byType(VoiceSettingsPage)));
        expect(container.read(voiceSettingsProvider), VoiceMode.engine);
        expect((await SharedPreferences.getInstance()).getString(VoiceSettingsController.preferenceKey), 'engine');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
