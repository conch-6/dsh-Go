// A card's own scripts (酒馆助手's 角色脚本库; docs/design/roleplay-compat.md
// §8.3): the tree under the card's extensions.tavern_helper.scripts, or the
// older extensions.TavernHelper_scripts — scripts and folders — of which the
// enabled ones run in the whole-story canvas, each in its own hidden frame.

import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tavern_provider.dart';

/// One script that runs: its id and name as the card gives them, and its
/// code. [buttons] are the names of the buttons it shows (for the composer's
/// row, once there is one).
final class TavernCardScript {
  const TavernCardScript({required this.id, required this.name, required this.content, this.buttons = const []});

  final String id;
  final String name;
  final String content;
  final List<String> buttons;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'content': content, 'buttons': buttons};

  @override
  bool operator ==(Object other) =>
      other is TavernCardScript &&
      other.id == id &&
      other.name == name &&
      other.content == content &&
      _sameList(other.buttons, buttons);

  @override
  int get hashCode => Object.hash(id, name, content, Object.hashAll(buttons));
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The scripts of [card] (a card's JSON, its fields under data or at the top)
/// that run, in the tree's order: enabled, with code, not in a folder that is
/// off. Anything not shaped like a script or a folder is passed over.
List<TavernCardScript> tavernCardScripts(Object? card) {
  Map<String, Object?>? object(Object? v) => v is Map<String, Object?> ? v : null;
  final root = object(card);
  final extensions = object(object(root?['data'])?['extensions']) ?? object(root?['extensions']);
  if (extensions == null) return const [];
  final tree = object(extensions['tavern_helper'])?['scripts'] ?? extensions['TavernHelper_scripts'];
  final out = <TavernCardScript>[];
  void visit(Object? nodes) {
    if (nodes is! List<Object?>) return;
    for (final node in nodes.map(object).nonNulls) {
      if (node['enabled'] == false) continue;
      final nested = node['scripts'] ?? node['children'];
      if (node['type'] == 'folder' || (node['type'] != 'script' && nested is List<Object?>)) {
        visit(nested);
        continue;
      }
      final content = node['content'];
      if (node['enabled'] != true || content is! String || content.trim().isEmpty) continue;
      final button = object(node['button']);
      out.add(
        TavernCardScript(
          id: switch (node['id']) {
            final String s when s.isNotEmpty => s,
            _ => 'script-${out.length}',
          },
          name: switch (node['name']) {
            final String s => s,
            _ => '',
          },
          content: content,
          buttons: [
            if (button?['enabled'] != false)
              for (final b in switch (button?['buttons']) {
                final List<Object?> list => list,
                _ => const <Object?>[],
              })
                if (object(b) case {'name': final String name} when object(b)!['visible'] != false && name.isNotEmpty)
                  name,
          ],
        ),
      );
    }
  }

  visit(tree);
  return out;
}

/// A character's card as the engine exports it, its fields (V2/V3 data, or a
/// V1 card's top level); null when it cannot be read.
final tavernCardDataProvider = FutureProvider.autoDispose.family<Map<String, Object?>?, String>((
  ref,
  characterId,
) async {
  try {
    final bytes = await ref.watch(tavernProvider).exportCard(characterId, format: TavernCardFormat.json);
    return tavernCardData(jsonDecode(utf8.decode(bytes)));
  } on Object {
    return null;
  }
});

/// [card]'s fields: under data for V2/V3, else its top level; null for
/// something that is not a card.
Map<String, Object?>? tavernCardData(Object? card) {
  if (card is! Map<String, Object?>) return null;
  return switch (card['data']) {
    final Map<String, Object?> data => data,
    _ => card,
  };
}

/// The scripts a character's card carries; none when it cannot be read.
final tavernCardScriptsProvider = FutureProvider.autoDispose.family<List<TavernCardScript>, String>((
  ref,
  characterId,
) async {
  final data = await ref.watch(tavernCardDataProvider(characterId).future);
  return data == null ? const [] : tavernCardScripts({'data': data});
});

/// Where it is kept, per character, that the word over the composer about
/// its card's scripts waiting on 整页画布 was put away.
const tavernScriptsHintOffKey = 'tavern.scriptsHintOff.';

/// Whether that word was put away for [characterId]'s card: then it is not
/// said again, for any of its chats.
final tavernScriptsHintOffProvider = FutureProvider.autoDispose.family<bool, String>(
  (ref, characterId) async =>
      (await SharedPreferences.getInstance()).getBool('$tavernScriptsHintOffKey$characterId') ?? false,
);

/// Puts that word away for [characterId]'s card, for good.
Future<void> tavernPutScriptsHintAway(String characterId) async =>
    (await SharedPreferences.getInstance()).setBool('$tavernScriptsHintOffKey$characterId', true);
