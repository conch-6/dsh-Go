import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/tavern/tavern_storage.dart';
import 'package:dsh_app/ui/tavern/tavern_settings_page.dart';
import 'package:dsh_app/ui/tavern/tavern_usage_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

TavernMessage _reply(String id, int prompt, int cache, int out) => TavernMessage(
  nodeId: id,
  role: TavernRole.character,
  speaker: '林晚',
  text: '答',
  at: DateTime(2026),
  reportedUsage: TavernUsage(promptTokens: prompt, cacheHitTokens: cache, completionTokens: out),
);

/// The preview with three chats: a long one, a short one, and one where the
/// model reported nothing.
class _Three extends PreviewTavern {
  _Three() : super(tick: Duration.zero);

  static final _at = DateTime(2026, 11, 11);
  final lines = {
    'long': [for (var i = 0; i < 4; i++) _reply('l$i', 20000, 10000, 1000)],
    'short': [_reply('s0', 3000, 0, 500)],
    'quiet': [TavernMessage(nodeId: 'q0', role: TavernRole.character, speaker: '星图', text: '嗯', at: DateTime(2026))],
  };

  @override
  Stream<List<TavernChatSummary>> watchChats({String? characterId}) => Stream.value([
    TavernChatSummary(id: 'short', characterId: 'sample-innkeeper', title: '雨夜', updatedAt: _at),
    TavernChatSummary(id: 'long', characterId: 'sample-innkeeper', title: '旅店', updatedAt: _at),
    TavernChatSummary(id: 'quiet', characterId: 'sample-navigator', title: '', updatedAt: _at),
  ]);

  @override
  Future<List<TavernMessage>> path(String chatId, {int limit = 60, String? beforeNodeId}) async =>
      beforeNodeId == null ? lines[chatId]! : const [];
}

Future<void> _show(WidgetTester tester, Widget home) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(390, 844) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tavernProvider.overrideWith((ref) => _Three()),
        tavernStorageProvider.overrideWith((ref) async => const TavernStorage()),
      ],
      child: MaterialApp(
        theme: withTestFonts(buildLightTheme()),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every chat added up, the one that took the most first; a quiet one left out', (tester) async {
    await _show(tester, const TavernUsagePage());
    final total = find.byKey(const ValueKey('tavern-usage-total'));
    // 4×20000+3000 in, 40000 of it cached, 4×1000+500 out.
    for (final text in ['8.3万', '48%', '4500']) {
      expect(
        find.descendant(of: total, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
    final long = tester.getTopLeft(find.byKey(const ValueKey('tavern-usage-long'))).dy;
    final short = tester.getTopLeft(find.byKey(const ValueKey('tavern-usage-short'))).dy;
    expect(long, lessThan(short));
    expect(find.byKey(const ValueKey('tavern-usage-quiet')), findsNothing);
    expect(
      find.descendant(of: find.byKey(const ValueKey('tavern-usage-long')), matching: find.text('林晚 · 旅店')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(const ValueKey('tavern-usage-long')), matching: find.text('8.4万')),
      findsOneWidget,
    );
  });

  testWidgets('酒馆设置 › 数据 opens it', (tester) async {
    await _show(tester, const TavernSettingsPage());
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('tavern-usage-stats')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tavern-usage-stats')));
    await tester.pumpAndSettle();
    expect(find.byType(TavernUsagePage), findsOneWidget);
  });
}
