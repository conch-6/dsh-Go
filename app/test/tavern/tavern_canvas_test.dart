import 'dart:convert';

import 'package:dsh_app/tavern/tavern_canvas.dart';
import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/tavern/tavern_settings.dart';
import 'package:dsh_app/ui/tavern/tavern_canvas_view.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// What the canvas was last handed.
class _Canvas {
  List<TavernCanvasEntry> entries = const [];
  ValueListenable<(String, String)?>? streaming;
  void Function(String nodeId)? onMenu;
  var builds = 0;
}

Future<(PreviewTavern, String, _Canvas)> _chat(WidgetTester tester, {Map<String, Object> prefs = const {}}) async {
  SharedPreferences.setMockInitialValues({TavernSettingsController.canvasKey: true, ...prefs});
  final tavern = PreviewTavern(tick: Duration.zero);
  final chat = (await tester.runAsync(() => tavern.createChat('sample-innkeeper')))!;
  await tester.runAsync(() => tavern.narrate(chat, '*雨停了。*\n\n"进来吧，" 她说。'));
  tester.view.physicalSize = const Size(390, 844) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final canvas = _Canvas();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tavernProvider.overrideWith((ref) => tavern),
        tavernCanvasBuilderProvider.overrideWithValue(({required entries, required streaming, required onMenu}) {
          canvas
            ..entries = entries
            ..streaming = streaming
            ..onMenu = onMenu
            ..builds += 1;
          return const SizedBox.expand(key: ValueKey('fake-canvas'));
        }),
      ],
      child: MaterialApp(
        theme: withTestFonts(buildLightTheme()),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: TavernChatPage(chatId: chat),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (tavern, chat, canvas);
}

void main() {
  test('a message reads as ST would draw it: paragraphs, emphasis, what is said in <q>', () {
    expect(
      tavernStoryHtml('她笑了。\n第二行\n\n*点头*，**很重要**。'),
      '<p>她笑了。<br>第二行</p>\n<p><em>点头</em>，<strong>很重要</strong>。</p>',
    );
    expect(tavernStoryHtml('"进来吧，" 她说。「好。」'), '<p><q>"进来吧，"</q> 她说。<q>「好。」</q></p>');
    // A tag's attributes are left as written; its words are formatted.
    expect(tavernStoryHtml('看<span title="a *b*">"这里"</span>'), '<p>看<span title="a *b*"><q>"这里"</q></span></p>');
    // Code keeps its marks; an ```html block and block HTML go as written.
    expect(tavernStoryHtml('用 `*x*` 吧'), '<p>用 <code>*x*</code> 吧</p>');
    expect(
      tavernStoryHtml('```js\nif (a < b) *c*\n```'),
      '<pre><code class="language-js">if (a &lt; b) *c*</code></pre>',
    );
    expect(tavernStoryHtml('```html\n<div class="bar">"x"</div>\n```'), '<div class="bar">"x"</div>');
    expect(tavernStoryHtml('<div class="bar">\n"好感" 42\n</div>'), '<div class="bar">\n"好感" 42\n</div>');
    expect(tavernStoryHtml('## 第一章'), '<h2>第一章</h2>');
    expect(tavernStoryHtml('> 引文\n> 第二行'), '<blockquote><p>引文<br>第二行</p></blockquote>');
    expect(tavernStoryHtml('a_b_c 和 _斜_'), '<p>a_b_c 和 <em>斜</em></p>');
  });

  test('the page has ST structure and colour variables, our script by nonce, and the chosen guards', () {
    String page({bool noScripts = false, bool offline = false}) => tavernCanvasDocument(
      text: const Color(0xff112233),
      accent: const Color(0xff445566),
      muted: const Color(0xff778899),
      quote: const Color(0xffaa5500),
      emphasis: const Color(0xff556677),
      userTint: const Color(0x22445566),
      fontSize: 15,
      lineHeight: 1.65,
      nonce: 'n0nce',
      userLabel: '你',
      labels: const TavernCanvasLabels(letterFrom: '{from}的信', taken: '获得'),
      noScripts: noScripts,
      offline: offline,
    );
    final open = page();
    expect(open, contains('<div id="chat"></div>'));
    expect(open, contains('--SmartThemeQuoteColor:rgba(170,85,0,1.000)'));
    expect(open, contains('--SmartThemeEmColor:rgba(85,102,119,1.000)'));
    expect(open, contains('font:var(--mainFontSize)/1.65'));
    expect(open, contains('<script nonce="n0nce">'));
    expect(open, contains("m.className='mes'"));
    expect(open, contains("m.setAttribute('mesid'"));
    expect(open, contains('DshTavern.postMessage'));
    expect(open, contains('var userLabel="你"'));
    expect(open, isNot(contains('Content-Security-Policy')));
    // Component tags are Web Components there, in the reader's words.
    for (final tag in ['dsh-letter', 'dsh-item', 'dsh-clue', 'dsh-phone', 'dsh-roll', 'dsh-notice', 'dsh-game']) {
      expect(open, contains("define('$tag'"));
    }
    expect(open, contains('"letterFrom":"{from}的信"'));
    expect(open, contains('"taken":"获得"'));
    expect(page(noScripts: true), contains("script-src 'nonce-n0nce'"));
    expect(page(offline: true), contains("default-src 'none'"));

    final json = jsonDecode(
      tavernCanvasJson(const [
        TavernCanvasEntry(mesid: 0, nodeId: 'n1', name: '林晚', html: '<p>好</p>'),
        TavernCanvasEntry(mesid: 1, nodeId: 'n2', name: '你', html: '<p>嗯</p>', isUser: true),
      ]),
    );
    expect(json, [
      {'mesid': 0, 'node': 'n1', 'name': '林晚', 'html': '<p>好</p>', 'user': false, 'system': false},
      {'mesid': 1, 'node': 'n2', 'name': '你', 'html': '<p>嗯</p>', 'user': true, 'system': false},
    ]);
  });

  testWidgets('with 整页画布 on, the story is the canvas, each message as shown', (tester) async {
    final (tavern, chat, canvas) = await _chat(tester);
    expect(find.byKey(const ValueKey('fake-canvas')), findsOneWidget);
    expect(find.byKey(const ValueKey('tavern-transcript')), findsNothing);
    final path = (await tester.runAsync(() => tavern.path(chat)))!;
    expect(canvas.entries.map((e) => e.nodeId), path.map((m) => m.nodeId));
    expect(canvas.entries.map((e) => e.mesid), List.generate(path.length, (i) => i));
    final narration = canvas.entries.last;
    expect(narration.isSystem, isTrue);
    expect(narration.name, '旁白');
    expect(narration.html, '<p><em>雨停了。</em></p>\n<p><q>"进来吧，"</q> 她说。</p>');
    expect(canvas.streaming!.value, isNull);

    // Holding a message on the canvas opens the app's own menu for it.
    canvas.onMenu!(narration.nodeId);
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsOneWidget);
  });

  testWidgets('视觉小说 keeps its own view', (tester) async {
    await _chat(tester, prefs: {TavernSettingsController.layoutKey: TavernLayout.visualNovel.name});
    expect(find.byKey(const ValueKey('fake-canvas')), findsNothing);
  });

  testWidgets('with the switch off, the native list', (tester) async {
    await _chat(tester, prefs: {TavernSettingsController.canvasKey: false});
    expect(find.byKey(const ValueKey('fake-canvas')), findsNothing);
    expect(find.byKey(const ValueKey('tavern-transcript')), findsOneWidget);
  });

  test('the setting is off until chosen, and kept', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(tavernSettingsProvider);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(tavernSettingsProvider).canvas, isFalse);
    await container.read(tavernSettingsProvider.notifier).setCanvas(true);
    expect(container.read(tavernSettingsProvider).canvas, isTrue);
    expect((await SharedPreferences.getInstance()).getBool(TavernSettingsController.canvasKey), isTrue);
  });
}
