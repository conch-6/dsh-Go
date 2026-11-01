import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_filter_bar.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../drawer/support.dart';
import '../shell/golden_harness.dart';
import '../workspace/support.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump(const Duration(milliseconds: 450));
}

Future<(DrawerHost, ProviderContainer)> openArchive(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final host = DrawerHost();
  host.seedSession('a1', '归档的旧对话', DateTime(2026, 10, 1));
  host.archived = ['a1'];
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
      overrides: workspaceOverrides(host, prefs: const WorkspacePrefs(loaded: true), current: null),
    ),
  );
  await settle(tester);
  final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
  addTearDown(container.read(activeConnectionProvider).value!.client.close);
  expect(container.read(sessionsProvider).value, isEmpty);
  expect(find.byType(DrawerViewButton), findsOneWidget);
  await tester.tap(find.byType(DrawerViewButton));
  await settle(tester);
  await tester.tap(find.text('已归档'));
  await settle(tester);
  expect(find.byType(SessionSearchPage), findsOneWidget);
  expect(find.byType(SearchResultTile), findsOneWidget);
  return (host, container);
}

void main() {
  testWidgets('all-archived drawer remains browsable and restores before opening', (tester) async {
    final (host, container) = await openArchive(tester);
    await tester.tap(find.byType(SearchResultTile));
    await settle(tester);
    expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
    await tester.tap(find.text('恢复并打开'));
    await settle(tester);
    expect(host.argsOf('workspace/unarchiveSession'), hasLength(1));
    expect(host.archived, isEmpty);
    expect(container.read(currentSessionProvider), 'a1');
    expect(find.byType(SessionSearchPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final roundTrip in [false, true]) {
    testWidgets('restore confirmation retires across host switch (return: $roundTrip)', (tester) async {
      final (host, container) = await openArchive(tester);
      await tester.tap(find.byType(SearchResultTile));
      await settle(tester);
      container.read(activeHostProvider.notifier).select(const HostRef.ssh('other'));
      if (roundTrip) container.read(activeHostProvider.notifier).select(HostRef.local);
      await settle(tester);
      await tester.tap(find.text('恢复并打开'));
      await settle(tester);
      expect(host.argsOf('workspace/unarchiveSession'), isEmpty);
      expect(host.archived, ['a1']);
      expect(container.read(currentSessionProvider), isNull);
      expect(find.byType(SessionSearchPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
