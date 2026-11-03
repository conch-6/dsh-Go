// New rows ease in (fade + rise 8) once, the first time they show; what was
// already there when the conversation opened never animates. Expanding a
// tool row keeps its detail mounted while it collapses again.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart' show chatClock;
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/chat/widgets/stream_motion.dart';
import 'package:dsh_app/ui/chat/widgets/thinking_pill.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

Future<void> _noRespond(ApprovalRequest r, ApprovalDecision d) async {}

/// The opacity painted over [finder], 1 when nothing fades it.
double _opacityOf(WidgetTester tester, Finder finder) {
  final fades = find.ancestor(of: finder, matching: find.byType(Opacity));
  var value = 1.0;
  for (final element in fades.evaluate()) {
    value *= (element.widget as Opacity).opacity;
  }
  return value;
}

ChatState _state(List<ChatItem> items) => ChatState(items: items, title: '测试', loading: false);

void main() {
  setUpAll(() async {
    await loadTestFonts();
    chatClock = () => DateTime(2026, 10, 23, 9);
  });

  testWidgets('a new reply fades in once; the history does not', (tester) async {
    final first = [user(1, '第一个问题'), assistant(2, '第一个回答')];
    final harness = ChatHarness(session: 's1', states: {'s1': _state(first)});
    usePhoneView(tester);
    mockClipboard(tester);
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await tester.pump();
    // Opened with these rows: already in place, no fade.
    expect(_opacityOf(tester, find.text('第一个回答')), 1);

    harness.controllers['s1']!.emit(_state([...first, user(3, '第二个问题'), assistant(4, '第二个回答')]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final early = _opacityOf(tester, find.text('第二个回答'));
    expect(early, lessThan(1));
    expect(_opacityOf(tester, find.text('第一个回答')), 1);

    await tester.pump(const Duration(milliseconds: 400));
    expect(_opacityOf(tester, find.text('第二个回答')), 1);
  });

  testWidgets('committing a reply preserves its state and folds the expanded thinking', (tester) async {
    usePhoneView(tester);
    final harness = ChatHarness(
      session: 's1',
      states: {
        's1': _state([user(1, '问题'), assistant(2, '回答', rowKey: 'm1.1', streaming: true, reasoning: '完整思考')]),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await tester.pump();
    await tester.tap(find.byType(ThinkingPill));
    await pumpFrames(tester, 10);
    // 展开时只有全文,行内预览让位。
    expect(find.descendant(of: find.byType(ThinkingPill), matching: find.text('完整思考')), findsOneWidget);
    bool pillExpanded() => tester
        .widget<Semantics>(
          find
              .descendant(
                of: find.byType(ThinkingPill),
                matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.expanded != null),
              )
              .first,
        )
        .properties
        .expanded!;
    expect(pillExpanded(), isTrue);
    final state = tester.state(find.byType(AssistantMessage));
    harness.controllers['s1']!.emit(_state([user(1, '问题'), assistant(16, '回答', rowKey: 'm1.1', reasoning: '完整思考')]));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.state(find.byType(AssistantMessage)), same(state));
      expect(_opacityOf(tester, find.text('回答')), 1);
    }
    // 一轮结束:亲手展开的全文收回去,只剩一行预览。
    expect(pillExpanded(), isFalse);
  });

  testWidgets('adding a visual fence preserves the reply state', (tester) async {
    usePhoneView(tester);
    final harness = ChatHarness(
      session: 's1',
      states: {
        's1': _state([assistant(2, '回答', rowKey: 'm1.1', streaming: true)]),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await tester.pump();
    final state = tester.state(find.byType(AssistantMessage));
    harness.controllers['s1']!.emit(_state([assistant(2, '回答\n\n```dsh-ui\n', rowKey: 'm1.1', streaming: true)]));
    await tester.pump();
    expect(tester.state(find.byType(AssistantMessage)), same(state));
  });

  testWidgets('reduced motion: new rows are simply there', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: StreamFadeIn(child: Text('第二个回答')),
        ),
      ),
    );
    expect(_opacityOf(tester, find.text('第二个回答')), 1);
    expect(find.byType(Opacity), findsNothing);
  });

  testWidgets('tool detail stays mounted while it collapses', (tester) async {
    usePhoneView(tester);
    final item = tool('b', 'bash', {'command': 'echo hi'}, result: 'hi');
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ToolRow(item: item, onRespond: _noRespond),
        ),
      ),
    );
    expect(find.byType(ToolDetail), findsNothing);
    await tester.tap(find.text('运行'));
    await pumpFrames(tester, 4);
    expect(find.byType(ToolDetail), findsOneWidget);

    await tester.tap(find.text('运行'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-collapse: still there, shrinking.
    expect(find.byType(ToolDetail), findsOneWidget);
    await pumpFrames(tester, 4);
    expect(find.byType(ToolDetail), findsNothing);
  });
}
