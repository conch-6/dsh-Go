// The new-chat empty state in two tiers — at most one primary pill
// (「重新连接」), everything else quiet chips of one size (the workspace chip
// and the suggestions). Geometry is measured, not eyeballed; goldens in light
// and dark. Regenerate with
// `flutter test --update-goldens test/chat/empty_actions_test.dart`.

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/empty_actions.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/widgets/whale_tail.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _workspace = Workspace(workspaceId: 'w1', path: '/root/workspace/dsh-app', title: 'dsh-app', sessionIds: []);

const _workspaceLabel = '在「dsh-app」中';

/// The new-chat screen: connected in a workspace, or with a failed engine
/// connection.
Future<void> _pumpChat(
  WidgetTester tester, {
  bool failed = false,
  Brightness brightness = Brightness.light,
  Size? size,
  double textScale = 1,
}) async {
  usePhoneView(tester);
  if (size != null) tester.view.physicalSize = size * 2;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final harness = ChatHarness(connected: !failed);
  final List<Override> overrides = failed
      ? [
          activeConnectionProvider.overrideWithValue(AsyncError<HostConnection?>(StateError('raw'), StackTrace.empty)),
          ...harness.overrides.skip(1),
        ]
      : [...harness.overrides, selectedWorkspaceProvider.overrideWithValue(_workspace)];
  await tester.pumpWidget(testApp(const ChatScreen(), brightness: brightness, overrides: overrides));
  await pumpFrames(tester, 8);
}

/// Just the empty state, centred in a phone-wide page.
Future<void> _pumpState(WidgetTester tester, ChatEmptyState state) async {
  usePhoneView(tester);
  await tester.pumpWidget(testApp(Scaffold(body: Center(child: state))));
  await pumpFrames(tester, 8);
}

double _screenWidth(WidgetTester tester) => tester.view.physicalSize.width / tester.view.devicePixelRatio;

/// The pill around [label] (its ink fills it exactly).
Finder _pill(String label) => find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first;

Rect _rect(WidgetTester tester, String label) => tester.getRect(_pill(label));

/// The content row inside the pill around [label].
Rect _content(WidgetTester tester, String label) =>
    tester.getRect(find.descendant(of: _pill(label), matching: find.byType(Row)).first);

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await WhaleSprites.load();
    chatClock = () => DateTime(2026, 10, 23, 15, 20);
  });

  group('geometry', () {
    testWidgets('suggestions: equal chips, edge to edge with the composer', (tester) async {
      await _pumpChat(tester);
      expect(tester.takeException(), isNull);
      final composer = tester.getRect(find.byType(Composer));
      final cells = [for (final s in defaultSuggestions) _rect(tester, s.label)];

      for (final c in cells) {
        expect(c.height, moreOrLessEquals(EmptyActions.height));
        expect(c.width, moreOrLessEquals(cells[0].width, epsilon: 0.5));
      }
      // 2×2, the outer edges on the composer's (12 from the screen).
      expect(cells[0].left, moreOrLessEquals(composer.left, epsilon: 0.5));
      expect(cells[2].left, moreOrLessEquals(composer.left, epsilon: 0.5));
      expect(cells[1].right, moreOrLessEquals(composer.right, epsilon: 0.5));
      expect(cells[3].right, moreOrLessEquals(composer.right, epsilon: 0.5));
      expect(cells[0].top, cells[1].top);
      expect(cells[2].top, cells[3].top);
      expect(cells[1].left - cells[0].right, moreOrLessEquals(EmptyActions.gap));
      expect(cells[2].top - cells[0].bottom, moreOrLessEquals(EmptyActions.gap));

      // Inside each chip the content is centred: equal room left and right
      // once the icon's own air is counted, equal room above and below.
      for (final s in defaultSuggestions) {
        final chip = _rect(tester, s.label);
        final row = _content(tester, s.label);
        expect(
          row.left - chip.left + EmptyActions.leadingAir,
          moreOrLessEquals(chip.right - row.right, epsilon: 0.5),
          reason: s.label,
        );
        expect(row.top - chip.top, moreOrLessEquals(chip.bottom - row.bottom, epsilon: 0.5), reason: s.label);
        final paragraph = tester.renderObject<RenderParagraph>(find.text(s.label));
        expect(paragraph.didExceedMaxLines, isFalse, reason: '${s.label} is cut');
      }
    });

    testWidgets('workspace chip: same height, centred, both sides read equal', (tester) async {
      await _pumpChat(tester);
      final chip = _rect(tester, _workspaceLabel);
      expect(chip.height, moreOrLessEquals(EmptyActions.height));
      expect(chip.center.dx, moreOrLessEquals(_screenWidth(tester) / 2, epsilon: 0.5));
      final folder = tester.getRect(
        find.descendant(of: _pill(_workspaceLabel), matching: find.byIcon(AppIcons.workspace)),
      );
      final chevron = tester.getRect(
        find.descendant(of: _pill(_workspaceLabel), matching: find.byIcon(AppIcons.expand)),
      );
      final left = folder.left - chip.left + EmptyActions.leadingAir;
      final right = chip.right - chevron.right + EmptyActions.chevronAir;
      expect(left, moreOrLessEquals(EmptyActions.inset, epsilon: 0.5));
      expect(right, moreOrLessEquals(EmptyActions.inset, epsilon: 0.5));
      expect(folder.center.dy, moreOrLessEquals(chip.center.dy, epsilon: 0.5));
      expect(chevron.center.dy, moreOrLessEquals(chip.center.dy, epsilon: 0.5));
    });

    testWidgets('360dp with large text: one chip per row, nothing cut', (tester) async {
      await _pumpChat(tester, size: const Size(360, 780), textScale: 1.3);
      expect(tester.takeException(), isNull);
      final composer = tester.getRect(find.byType(Composer));
      final cells = [for (final s in defaultSuggestions) _rect(tester, s.label)];
      for (final (i, c) in cells.indexed) {
        expect(c.left, moreOrLessEquals(composer.left, epsilon: 0.5));
        expect(c.right, moreOrLessEquals(composer.right, epsilon: 0.5));
        expect(c.height, moreOrLessEquals(cells[0].height, epsilon: 0.5));
        expect(c.height, greaterThan(EmptyActions.height), reason: 'grows with text');
        if (i > 0) {
          expect(c.top - cells[i - 1].bottom, moreOrLessEquals(EmptyActions.gap));
        }
        final paragraph = tester.renderObject<RenderParagraph>(find.text(defaultSuggestions[i].label));
        expect(paragraph.didExceedMaxLines, isFalse);
      }
      // The workspace chip grows by the same amount.
      expect(_rect(tester, _workspaceLabel).height, moreOrLessEquals(cells[0].height, epsilon: 0.5));
    });

    testWidgets('no workspace chosen on a remote host: the chip names the one it falls back to', (tester) async {
      usePhoneView(tester);
      final harness = ChatHarness(connected: true);
      await tester.pumpWidget(
        testApp(
          const ChatScreen(),
          overrides: [...harness.overrides, recentWorkspaceForNewChatProvider.overrideWithValue(_workspace)],
        ),
      );
      await pumpFrames(tester, 8);
      expect(find.text(_workspaceLabel), findsOneWidget);
    });

    testWidgets('no workspace at all on a remote host: the chip names its default folder', (tester) async {
      usePhoneView(tester);
      final harness = ChatHarness(connected: true);
      await tester.pumpWidget(
        testApp(
          const ChatScreen(),
          overrides: [...harness.overrides, newChatInHostDefaultProvider.overrideWithValue(true)],
        ),
      );
      await pumpFrames(tester, 8);
      expect(find.text('在「主机默认目录」中'), findsOneWidget);
    });

    testWidgets('the primary pill takes the workspace chip\'s place exactly', (tester) async {
      Future<(Rect, double)> slot(bool failed) async {
        await _pumpState(
          tester,
          ChatEmptyState(
            connected: !failed,
            onSuggestion: (_) {},
            workspace: failed ? null : '项目',
            onWorkspace: () {},
            onReconnect: failed ? () {} : null,
          ),
        );
        final label = failed ? '重新连接' : '在「项目」中';
        final subtitle = tester.getRect(find.text(failed ? '没能连上引擎' : '今天想做点什么？'));
        final pill = _rect(tester, label);
        return (pill, pill.top - subtitle.bottom);
      }

      final (primary, primaryGap) = await slot(true);
      final (chip, chipGap) = await slot(false);
      expect(primary.height, moreOrLessEquals(chip.height));
      expect(primary.height, moreOrLessEquals(EmptyActions.height));
      expect(primary.center.dx, moreOrLessEquals(195, epsilon: 0.5));
      expect(chip.center.dx, moreOrLessEquals(195, epsilon: 0.5));
      expect(primaryGap, moreOrLessEquals(chipGap, epsilon: 0.1));
    });
  });

  group('tiers', () {
    testWidgets('connected: no primary, every control a quiet chip', (tester) async {
      await _pumpChat(tester);
      expect(find.byType(EmptyPrimaryPill), findsNothing);
      expect(find.byType(QuietChip), findsNWidgets(defaultSuggestions.length + 1));
      final theme = Theme.of(tester.element(find.byType(ChatEmptyState)));
      for (final material in tester.widgetList<Material>(
        find.descendant(of: find.byType(QuietChip), matching: find.byType(Material)),
      )) {
        expect(material.color, quietChipFill(theme));
        expect(material.elevation, 0);
      }
    });

    testWidgets('failed: one primary pill, nothing else to tap', (tester) async {
      await _pumpChat(tester, failed: true);
      await pumpFrames(tester, 6);
      expect(find.text('没能连上引擎'), findsOneWidget);
      expect(find.byType(EmptyPrimaryPill), findsOneWidget);
      expect(find.byType(QuietChip), findsNothing);
      final theme = Theme.of(tester.element(find.byType(ChatEmptyState)));
      final fill = tester.widget<Material>(
        find.descendant(of: find.byType(EmptyPrimaryPill), matching: find.byType(Material)),
      );
      expect(fill.color, theme.colorScheme.primary);
    });

    testWidgets('the primary pill reconnects', (tester) async {
      var taps = 0;
      await _pumpState(tester, ChatEmptyState(connected: false, onSuggestion: (_) {}, onReconnect: () => taps++));
      await tester.tap(find.text('重新连接'));
      await tester.pump();
      expect(taps, 1);
      final semantics = tester.getSemantics(_pill('重新连接'));
      expect(semantics.label, '重新连接');
    });

    testWidgets('connecting: the chips are there but do nothing', (tester) async {
      final picked = <ChatSuggestion>[];
      await _pumpState(tester, ChatEmptyState(connected: false, connecting: true, onSuggestion: picked.add));
      expect(find.text('正在连接引擎…'), findsOneWidget);
      expect(find.byType(EmptyPrimaryPill), findsNothing);
      await tester.tap(find.text(defaultSuggestions[0].label));
      await tester.pump();
      expect(picked, isEmpty);
    });

    testWidgets('a chip fills in its suggestion', (tester) async {
      final picked = <ChatSuggestion>[];
      await _pumpState(tester, ChatEmptyState(connected: true, onSuggestion: picked.add));
      await tester.tap(find.text(defaultSuggestions[2].label));
      await tester.pump();
      expect(picked, [defaultSuggestions[2]]);
    });

    testWidgets('workspace chip: a label and a hint, not one long sentence', (tester) async {
      var opened = 0;
      await _pumpState(
        tester,
        ChatEmptyState(connected: true, onSuggestion: (_) {}, workspace: '项目', onWorkspace: () => opened++),
      );
      final semantics = tester.getSemantics(_pill('在「项目」中'));
      expect(semantics.label, '在「项目」中');
      expect(semantics.hint, isEmpty);
      await tester.tap(find.text('在「项目」中'));
      await tester.pump();
      expect(opened, 1);
    });
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    group('goldens ($mode)', () {
      testWidgets('connected, in a workspace', (tester) async {
        await _pumpChat(tester, brightness: brightness);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/empty_tiers_$mode.png'));
      });

      testWidgets('engine unreachable', (tester) async {
        await _pumpChat(tester, failed: true, brightness: brightness);
        await pumpFrames(tester, 6);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/empty_tiers_failed_$mode.png'));
      });

      testWidgets('360dp, large text', (tester) async {
        await _pumpChat(tester, brightness: brightness, size: const Size(360, 780), textScale: 1.3);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/empty_tiers_narrow_$mode.png'));
      });
    });
  }
}
