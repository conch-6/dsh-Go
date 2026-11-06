import 'dart:async';
import 'dart:io';

import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/ui/share_code/share_code_panel.dart';
import 'package:dsh_app/ui/share_code/share_out.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

void main() {
  testWidgets('reopened profile save cannot replace the pending native source', (tester) async {
    final cache = Directory.systemTemp.createTempSync('share-save-source-');
    addTearDown(() => cache.deleteSync(recursive: true));
    const channel = MethodChannel('test/share-save-source');
    final gates = (await tester.runAsync(() async => List.generate(4, (_) => Completer<void>())))!;
    final entered = gates[0], release = gates[1], firstDone = gates[2], secondDone = gates[3];
    var calls = 0;
    String? firstContent;
    final paths = <String>[];
    final names = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'saveToDownloads');
      final args = call.arguments as Map;
      final path = args['path'] as String;
      final name = args['name'] as String;
      paths.add(path);
      names.add(name);
      final first = calls++ == 0;
      if (first) {
        entered.complete();
        await release.future;
      }
      final content = await File(path).readAsString();
      if (first) {
        firstContent = content;
        firstDone.complete();
      } else {
        secondDone.complete();
      }
      return 'Download/DSH-Go/$name';
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final out = ShareOut(
      files: const FilesChannel(channel),
      cacheRoot: () async => cache,
      clock: () => DateTime(2026, 10, 24),
    );
    ProfileShare payload(String name) => ProfileShare(
      skills: [
        SharedSkill(name: name, files: {'SKILL.md': '$name content'}),
      ],
    );
    Future<void> show(String name) => tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: Scaffold(
          body: ShareCodePanel(key: ValueKey(name), payload: payload(name), title: name),
        ),
        overrides: [shareOutProvider.overrideWithValue(out)],
      ),
    );
    usePhoneSurface(tester);
    await show('first');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('share-code-save')));
      await entered.future;
    });
    // Disposing/reopening resets the page-local busy flag, as dismissible profile sheets do.
    await show('second');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('share-code-save')));
      await secondDone.future;
      release.complete();
      await firstDone.future;
    });
    await tester.pump();
    expect(names, ['dsh-go-profile-20261024.dshgo', 'dsh-go-profile-20261024.dshgo']);
    expect((decodeShareFile(firstContent!) as ProfileShare).skills.single.name, 'first');
    await tester.pumpWidget(const SizedBox());
  });
  test('native failure removes only its owned save directory', () async {
    final cache = Directory.systemTemp.createTempSync('share-save-failure-');
    addTearDown(() => cache.deleteSync(recursive: true));
    const channel = MethodChannel('test/share-save-failure');
    String? source;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      source = (call.arguments as Map)['path'] as String;
      expect(await File(source!).readAsString(), 'original content');
      throw PlatformException(code: 'permission', message: 'controlled native refusal');
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    final out = ShareOut(files: const FilesChannel(channel), cacheRoot: () async => cache);
    final unrelated = await out.write('previous.dshgo', 'previous content');
    await expectLater(
      out.save('profile.dshgo', 'original content'),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'permission')),
    );
    expect(source, isNotNull);
    expect(await File(source!).parent.exists(), false);
    expect(await unrelated.readAsString(), 'previous content');
  });
}
