import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/tavern/tavern_session_usage.dart';
import 'package:dsh_app/ui/tavern/tavern_stage_panel.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// The preview, its chat a long line of [replies] exchanges handed out a
/// page at a time as the engine does; each reply reports 1000 in (400 from
/// the cache) and 100 out, except every tenth, which reports nothing.
class _LongChat extends PreviewTavern {
  _LongChat(int replies) : super(tick: Duration.zero) {
    for (var i = 0; i < replies; i++) {
      line
        ..add(TavernMessage(nodeId: 'u$i', role: TavernRole.user, speaker: 'User', text: '问$i', at: DateTime(2026)))
        ..add(
          TavernMessage(
            nodeId: 'c$i',
            role: TavernRole.character,
            speaker: '林晚',
            text: '答$i',
            at: DateTime(2026),
            reportedUsage: i % 10 == 9
                ? null
                : const TavernUsage(promptTokens: 1000, cacheHitTokens: 400, completionTokens: 100),
          ),
        );
    }
  }

  final line = <TavernMessage>[];
  var pages = 0;

  @override
  Future<List<TavernMessage>> path(String chatId, {int limit = 60, String? beforeNodeId}) async {
    pages++;
    final end = beforeNodeId == null ? line.length : line.indexWhere((m) => m.nodeId == beforeNodeId);
    return line.sublist((end - limit).clamp(0, end), end);
  }
}

void main() {
  test('a token count at a glance', () {
    expect(tavernTokenCount(8421, zh: true), '8421');
    expect(tavernTokenCount(12345, zh: true), '1.2万');
    expect(tavernTokenCount(1234567, zh: true), '123万');
    expect(tavernTokenCount(12345, zh: false), '12.3k');
    expect(tavernTokenCount(123456, zh: false), '123k');
    expect(tavernTokenCount(2500000, zh: false), '2.5M');
  });

  test("the whole line is read, page by page, and its replies' usage added up", () async {
    final tavern = _LongChat(150); // 300 messages: two pages of 200
    final usage = await tavernSessionUsage(tavern, 'chat');
    expect(tavern.pages, 2);
    expect(usage.replies, 135); // every tenth reports nothing
    expect((usage.prompt, usage.cacheHit, usage.completion), (135000, 54000, 13500));

    final empty = await tavernSessionUsage(_LongChat(0), 'chat');
    expect(empty.replies, 0);
  });

  testWidgets('本局 opens with what the chat took so far', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tavernProvider.overrideWith((ref) => _LongChat(150))],
        child: MaterialApp(
          theme: withTestFonts(buildLightTheme()),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const Scaffold(
            body: TavernStagePanel(chatId: 'chat', name: '林晚'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final usage = find.byKey(const ValueKey('tavern-session-usage'));
    expect(usage, findsOneWidget);
    for (final text in ['本局用量', '13.5万', '40%', '1.4万']) {
      expect(
        find.descendant(of: usage, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
    expect(find.descendant(of: usage, matching: find.textContaining('135 条回复')), findsOneWidget);
  });
}
