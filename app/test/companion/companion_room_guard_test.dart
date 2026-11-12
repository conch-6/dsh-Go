// The room around a stage that left (docs/design/companion-floating.md,
// 小屋接线): a dead renderer shows the failed screen, and 重试 there brings a
// new stage, never the old one; without her pack there is nothing to retry;
// a pack that can't be removed while something still reads it stays, and the
// room says so instead of crashing.

// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dsh_app/companion/companion_keeper.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/plugins/islands/island_platform.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../plugins/islands/support/fakes.dart';
import 'phone_keeper_fake.dart';

final _files = <String, List<int>>{
  'runtime/live2dcubismcore.min.js': utf8.encode('core'),
  'runtime/cubism-framework.js': utf8.encode('fw'),
  'character/m.model3.json': utf8.encode('{}'),
  'character/m.moc3': [1, 2, 3],
  'character/character.json': utf8.encode('{"name":"鲸鱼娘"}'),
};

String get _runtime => runtimeDigest({
  for (final e in _files.entries)
    if (e.key.startsWith('runtime/')) e.key: sha256.convert(e.value).toString(),
});

Uint8List _zip() {
  final archive = Archive();
  _files.forEach((name, data) => archive.add(ArchiveFile.bytes(name, data)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// As webview_flutter_android's controller: it has the native WebView's id.
class _Page extends FakeWebViewController {
  _Page(super.params) : webViewIdentifier = _next++;

  static int _next = 1;
  final int webViewIdentifier;
}

class _Web extends FakeWebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) {
    final page = _Page(params);
    controllers.add(page);
    return page;
  }
}

class _Islands extends FakeIslandPlatform {
  final attached = <int>[];
  final destroyed = <int>[];

  @override
  Future<bool> attach(int webViewId, {required bool dark, required int textZoom}) async {
    attached.add(webViewId);
    return true;
  }

  @override
  Future<void> destroy(int webViewId) async => destroyed.add(webViewId);
}

Future<bool> _listening(Uri page) async {
  try {
    (await Socket.connect(page.host, page.port, timeout: const Duration(seconds: 5))).destroy();
    return true;
  } on SocketException {
    return false;
  }
}

void main() {
  late Directory root;
  late CompanionPackStore store;
  late IslandPlatform previousIslands;

  setUp(() {
    root = Directory.systemTemp.createTempSync('companion-room-guard');
    store = CompanionPackStore(Directory('${root.path}/companion'), expectedRuntime: _runtime);
    SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true, 'companion_home_hint_done': true});
    previousIslands = IslandPlatform.instance;
  });
  tearDown(() {
    IslandPlatform.instance = previousIslands;
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold a file a moment longer; the system clears temp.
    }
  });

  Future<void> install(WidgetTester tester) => tester.runAsync(() async {
    final zip = File('${root.path}/first.zip')..writeAsBytesSync(_zip());
    await store.install(zip.path);
  });

  Future<void> open(WidgetTester tester, {CompanionStageBuilder? stageBuilder}) => tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
        companionPhoneKeeperProvider.overrideWithValue((_) => FakePhoneKeeper() as CompanionKeeper),
      ],
      child: MaterialApp(
        theme: buildDarkTheme(),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('zh'),
        home: CompanionPage(
          storeOverride: store,
          stageBuilder: stageBuilder,
          stageController: CompanionStageController(sink: (_, _) {}),
        ),
      ),
    ),
  );

  /// Real file, socket and isolate work, then the frames it causes.
  Future<void> settle(WidgetTester tester, {bool Function()? until, int rounds = 100}) async {
    for (var i = 0; i < rounds && !(until?.call() ?? false); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await settle(tester, rounds: 3);
    await tester.pump(const Duration(seconds: 10));
  }

  testWidgets('a dead renderer: the failed screen in plain words, the old server closed; 重试 builds a new stage', (
    tester,
  ) async {
    final web = _Web();
    final islands = _Islands();
    WebViewPlatform.instance = web;
    IslandPlatform.instance = islands;
    await install(tester);
    await open(tester);
    await settle(tester, until: () => web.controllers.isNotEmpty && web.controllers.single.loads.isNotEmpty);
    final first = web.controllers.single as _Page;
    final firstUrl = first.loads.single;
    expect(islands.attached, [first.webViewIdentifier]);
    expect(find.byKey(fakeWebViewKey), findsOneWidget);

    islands.emit(IslandRendererGone(webViewId: first.webViewIdentifier, crashed: true));
    await settle(tester, until: () => find.text('重试').evaluate().isNotEmpty);
    expect(find.text('她没能出来'), findsOneWidget);
    // The stage's own reason stays out of what the person reads.
    expect(find.text('她刚才没加载出来。先重试，还不行再重新导入素材包。'), findsOneWidget);
    expect(find.textContaining('renderer gone'), findsNothing);
    expect(find.text('导入素材包'), findsOneWidget);
    expect(find.byKey(fakeWebViewKey), findsNothing);
    expect(islands.destroyed, [first.webViewIdentifier]);
    expect(await tester.runAsync(() => _listening(firstUrl)), isFalse);

    await tester.tap(find.text('重试'));
    await settle(tester, until: () => web.controllers.length == 2 && web.controllers.last.loads.isNotEmpty);
    expect(web.controllers, hasLength(2));
    final second = web.controllers.last as _Page;
    expect(islands.attached, [first.webViewIdentifier, second.webViewIdentifier]);
    expect(second.loads.single, isNot(firstUrl));
    expect(first.loads, hasLength(1), reason: 'the dead WebView is not loaded again');
    expect(find.text('她没能出来'), findsNothing);
    expect(find.byKey(fakeWebViewKey), findsOneWidget);
    await close(tester);
  });

  testWidgets('a failure with her pack gone offers no 重试; other reasons are still shown as they were', (tester) async {
    await install(tester);
    CompanionStageEvents? stageEvents;
    await open(
      tester,
      stageBuilder: (_, events) {
        stageEvents = events;
        return const SizedBox.expand();
      },
    );
    await settle(tester, until: () => stageEvents != null);
    await tester.runAsync(() => store.pack.delete(recursive: true));
    stageEvents!.onFailed('timeout');
    await settle(tester, rounds: 6);
    expect(find.text('她没能出来'), findsOneWidget);
    expect(find.text('这台手机上加载失败了（timeout）。可以重新导入素材包再试一次。'), findsOneWidget);
    expect(find.text('导入素材包'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    await close(tester);
  });

  testWidgets('removing her pack while something still reads it: she stays, and the room says so', (tester) async {
    await install(tester);
    // A reader that can't let go, as the floating window's failed close would be.
    final unhook = store.beforeChanges(() async => throw StateError('still reading'));
    CompanionStageEvents? stageEvents;
    await open(
      tester,
      stageBuilder: (_, events) {
        stageEvents = events;
        return const SizedBox.expand();
      },
    );
    await settle(tester, until: () => stageEvents != null);
    stageEvents!.onReady();
    await settle(tester, rounds: 6);
    await tester.pump(const Duration(seconds: 8));

    await tester.tap(find.byIcon(AppIcons.more));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('移除素材'));
    await tester.tap(find.text('移除素材'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移除素材'));
    await settle(tester, until: () => find.text('写入失败，看看手机存储空间够不够。').evaluate().isNotEmpty);
    expect(tester.takeException(), isNull);
    expect(find.text('写入失败，看看手机存储空间够不够。'), findsOneWidget);
    expect(File('${store.pack.path}/character/index.json').existsSync(), isTrue);
    // A stage that fails on its way out doesn't turn the setup screen into the failed one.
    stageEvents!.onFailed('pack changed');
    await tester.pump();
    expect(find.text('她没能出来'), findsNothing);
    unhook();
    await close(tester);
  });
}
