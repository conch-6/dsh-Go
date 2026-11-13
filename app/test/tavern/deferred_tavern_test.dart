import 'dart:async';

import 'package:dsh_app/tavern/deferred_tavern.dart';
import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('calls and streams wait for the tavern to open; configure reaches it then', () async {
    final opening = Completer<Tavern>();
    final deferred = DeferredTavern(opening.future)
      ..configure(TavernModelConfig(apiKey: () async => 'k', thinking: true));

    final characters = deferred.watchCharacters().first;
    final chat = deferred.createChat('sample-innkeeper');
    deferred.stop('nothing yet'); // no turn can run before it opens

    final preview = PreviewTavern(tick: const Duration(milliseconds: 1));
    opening.complete(preview);

    expect((await characters).map((c) => c.name), containsAll(['林晚', '星图']));
    final events = await deferred.send(await chat, '你好').toList();
    // The thinking set before it opened applies: the reply thinks first.
    expect(events.whereType<TavernReasoningDelta>(), isNotEmpty);
    expect(events.last, isA<TavernTurnDone>());
  });

  test('the libraries and the display pass reach the engine once it opens (T20, T21)', () async {
    final preview = PreviewTavern(tick: Duration.zero);
    final chat = await preview.createChat('sample-innkeeper');
    final deferred = DeferredTavern(Future.value(preview));

    expect(await deferred.listPresets(), isEmpty);
    expect(await deferred.watchPresets().first, isEmpty);
    expect((await deferred.presetSelection(chatId: chat)).source, PresetSelectionSource.stDefault);
    expect(await deferred.listRegexScripts(), isEmpty);
    expect(await deferred.listLorebooks(), isEmpty);
    expect((await deferred.displayText(chat, text: '*她笑了*')).text, '*她笑了*');
    // Presets and lorebooks go through to the preview's own.
    final imported = await deferred.importPreset('{"temperature": 1}', fileName: 'a.json');
    expect((await deferred.listPresets()).single.id, imported.preset.id);
    final book = await deferred.importLorebook('{"entries": {"0": {"content": "x"}}}', fileName: 'w.json');
    expect((await deferred.listLorebooks()).single.id, book.book.id);
  });
}
