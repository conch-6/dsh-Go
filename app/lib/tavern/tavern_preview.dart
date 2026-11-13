// A stand-in [Tavern] for building the screens before the engine
// (packages/dsh_tavern, Pro's T8) lands: two sample characters, an in-memory
// tree, and canned replies that stream like a model. Nothing is stored and no
// model is called; the chat page says so ([TavernPreview] → 预览 banner).

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';

/// Marks the stand-in, so the screens can say replies are samples.
abstract interface class TavernPreview {}

class PreviewTavern implements Tavern, TavernPreview {
  PreviewTavern({DateTime Function()? clock, this.tick = const Duration(milliseconds: 28)})
    : _clock = clock ?? DateTime.now {
    final now = _clock();
    for (final c in _samples) {
      _characters[c.id] = _Char(c, now);
    }
  }

  final DateTime Function() _clock;

  /// Time between streamed pieces.
  final Duration tick;

  final _characters = <String, _Char>{};
  final _chats = <String, _Chat>{};
  final _listChanged = StreamController<void>.broadcast();
  final _running = <String, StreamController<TavernEvent>>{};
  var _seq = 0;

  String _id(String prefix) => '$prefix-${++_seq}';

  // Library -------------------------------------------------------------------

  /// The list as the engine gives it (T23): the long fields left out, which
  /// [character] fills in.
  List<TavernCharacter> _characterList() {
    final list = _characters.values.map((c) => _view(c, summary: true)).toList()
      ..sort((a, b) => (b.lastChatAt ?? b.importedAt!).compareTo(a.lastChatAt ?? a.importedAt!));
    return list;
  }

  TavernCharacter _view(_Char c, {bool summary = false}) {
    final chats = _chats.values.where((chat) => chat.characterId == c.id).toList();
    DateTime? last;
    for (final chat in chats) {
      if (last == null || chat.updatedAt.isAfter(last)) last = chat.updatedAt;
    }
    return TavernCharacter(
      id: c.id,
      name: c.name,
      creator: c.creator,
      tags: c.tags,
      description: summary ? '' : c.description,
      creatorNotes: summary ? '' : c.creatorNotes,
      greetings: summary ? const [] : c.greetings,
      hasLorebook: c.data['character_book'] is Map,
      theme: summary ? null : _copySetting(_dshgoOf(c.data)['theme']),
      chatCount: chats.length,
      lastChatAt: last,
      importedAt: c.importedAt,
    );
  }

  Stream<T> _watch<T>(T Function() read) async* {
    yield read();
    yield* _listChanged.stream.map((_) => read());
  }

  @override
  Stream<List<TavernCharacter>> watchCharacters() => _watch(_characterList);

  @override
  Future<TavernCharacter?> character(String id) async => switch (_characters[id]) {
    final c? => _view(c),
    null => null,
  };

  @override
  Future<TavernCharacter> importCard(Uint8List bytes, {String? fileName}) async =>
      throw const TavernImportError('preview');

  @override
  Future<Uint8List> exportCard(String characterId, {TavernCardFormat format = TavernCardFormat.png}) async =>
      throw UnsupportedError('preview');

  @override
  Future<void> deleteCharacter(String characterId) async {
    _characters.remove(characterId);
    _chats.removeWhere((_, chat) => chat.characterId == characterId);
    _listChanged.add(null);
  }

  static const _editableTexts = {
    'name',
    'nickname',
    'description',
    'personality',
    'scenario',
    'first_mes',
    'mes_example',
    'system_prompt',
    'post_history_instructions',
    'creator_notes',
    'creator',
    'character_version',
  };

  @override
  Future<Map<String, Object?>?> characterFields(String characterId) async => switch (_characters[characterId]) {
    final c? => _copy(c.data),
    null => null,
  };

  @override
  Future<TavernCharacter> updateCharacterFields(String characterId, Map<String, Object?> fields) async {
    final c = _characters[characterId];
    if (c == null) throw const TavernImportError('missing character');
    for (final MapEntry(:key, :value) in fields.entries) {
      final ok = _editableTexts.contains(key)
          ? value is String
          : (key == 'alternate_greetings' || key == 'tags') && value is List && value.every((v) => v is String);
      if (!ok) throw ArgumentError.value(value, key);
    }
    for (final MapEntry(:key, :value) in fields.entries) {
      c.data[key] = value is List ? [...value] : value;
    }
    _listChanged.add(null);
    return _view(c);
  }

  static Map<String, Object?> _copy(Map<String, Object?> data) => {
    for (final MapEntry(:key, :value) in data.entries)
      key: switch (value) {
        final List l => [...l],
        final Map<String, Object?> m => _copy(m),
        _ => value,
      },
  };

  /// Canned replies assemble no prompt: there is nothing to inspect.
  @override
  Future<TavernTurnInspection?> inspectTurn(String chatId, {String? nodeId}) async => null;

  // Personas ------------------------------------------------------------------

  final _personas = <String, TavernPersona>{};
  final _bindings = <String, String>{};
  String? _defaultPersona;

  List<TavernPersona> _personaList() => _personas.values.toList();

  @override
  Stream<List<TavernPersona>> watchPersonas() => _watch(_personaList);

  @override
  Future<TavernPersona?> persona(String personaId) async => _personas[personaId];

  @override
  Future<TavernPersona> createPersona({
    required String name,
    String description = '',
    String? avatarPath,
    int descriptionPosition = PersonaDescriptionPosition.inPrompt,
  }) async {
    final persona = TavernPersona(
      id: _id('persona'),
      name: name,
      description: description,
      avatarPath: avatarPath,
      descriptionPosition: descriptionPosition,
    );
    _personas[persona.id] = persona;
    _listChanged.add(null);
    return persona;
  }

  @override
  Future<TavernPersona> updatePersona(
    String personaId, {
    String? name,
    String? description,
    String? avatarPath,
    bool clearAvatar = false,
    int? descriptionPosition,
  }) async {
    final persona = _personas[personaId]!.copyWith(
      name: name,
      description: description,
      avatarPath: avatarPath,
      clearAvatar: clearAvatar,
      descriptionPosition: descriptionPosition,
    );
    _personas[personaId] = persona;
    _listChanged.add(null);
    return persona;
  }

  @override
  Future<void> deletePersona(String personaId) async {
    _personas.remove(personaId);
    _bindings.removeWhere((_, id) => id == personaId);
    if (_defaultPersona == personaId) _defaultPersona = null;
    _listChanged.add(null);
  }

  @override
  Future<PersonaSelection> personaSelection({String? chatId}) async {
    final bound = chatId == null ? null : _bindings[chatId];
    final fallback = _defaultPersona;
    final persona = _personas[bound] ?? _personas[fallback];
    return PersonaSelection(
      persona: persona,
      source: _personas[bound] != null
          ? PersonaSelectionSource.chat
          : persona != null
          ? PersonaSelectionSource.globalDefault
          : PersonaSelectionSource.none,
      boundPersonaId: _personas.containsKey(bound) ? bound : null,
      defaultPersonaId: fallback,
    );
  }

  @override
  Future<void> setDefaultPersona(String? personaId) async {
    _defaultPersona = personaId;
    _listChanged.add(null);
  }

  @override
  Future<void> bindPersona(String chatId, String? personaId) async {
    if (personaId == null) {
      _bindings.remove(chatId);
    } else {
      _bindings[chatId] = personaId;
    }
    _listChanged.add(null);
  }

  // Chats ---------------------------------------------------------------------

  @override
  Stream<List<TavernChatSummary>> watchChats({String? characterId}) => _watch(() {
    final list = [
      for (final chat in _chats.values)
        if (characterId == null || chat.characterId == characterId) _summary(chat),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  });

  TavernChatSummary _summary(_Chat chat) {
    final path = chat.path();
    return TavernChatSummary(
      id: chat.id,
      characterId: chat.characterId,
      title: chat.title,
      updatedAt: chat.updatedAt,
      lastText: path.isEmpty ? null : path.last.text,
      messageCount: path.length,
    );
  }

  @override
  Future<String> createChat(String characterId, {int greeting = 0}) async {
    final c = _characters[characterId]!;
    final now = _clock();
    final chat = _Chat(_id('chat'), characterId, c.name, now);
    final greetings = c.greetings;
    for (var i = 0; i < greetings.length; i++) {
      chat.add(_Node(_id('n'), null, TavernRole.character, c.name, greetings[i], now));
    }
    chat.chosen[null] = chat.children(null)[greeting.clamp(0, greetings.length - 1)].id;
    _chats[chat.id] = chat;
    _listChanged.add(null);
    return chat.id;
  }

  /// The samples have no ST chat files to read or write.
  @override
  Future<TavernChatImportResult> importChats(
    String characterId,
    List<TavernChatFile> files, {
    Map<String, String> lorebookIds = const {},
  }) async => throw UnsupportedError('preview');

  @override
  Future<List<TavernChatFile>> exportChat(String chatId, {String? fileName}) async => throw UnsupportedError('preview');

  @override
  Future<void> deleteChat(String chatId) async {
    _chats.remove(chatId);
    _listChanged.add(null);
  }

  @override
  Future<List<TavernMessage>> path(String chatId, {int limit = 60, String? beforeNodeId}) async {
    final all = _chats[chatId]!.path();
    var end = all.length;
    if (beforeNodeId != null) end = all.indexWhere((m) => m.nodeId == beforeNodeId).clamp(0, all.length);
    return all.sublist(math.max(0, end - limit), end);
  }

  @override
  Stream<void> pathChanges(String chatId) => _chats[chatId]!.changes.stream;

  // Turns ---------------------------------------------------------------------

  @override
  Stream<TavernEvent> send(String chatId, String text) {
    final chat = _chats[chatId]!;
    final tail = chat.tail();
    var parent = tail?.id;
    if (text.trim().isNotEmpty) {
      final user = _Node(_id('n'), parent, TavernRole.user, 'You', text, _clock());
      chat.add(user);
      chat.chosen[parent] = user.id;
      parent = user.id;
    }
    return _reply(chat, parent, _cannedFor(text));
  }

  @override
  Stream<TavernEvent> regenerate(String chatId, String nodeId) {
    final chat = _chats[chatId]!;
    final node = chat.nodes[nodeId]!;
    return _reply(chat, node.parent, _canned[_seq % _canned.length]);
  }

  @override
  Stream<TavernEvent> continueReply(String chatId, String nodeId) {
    final chat = _chats[chatId]!;
    final node = chat.nodes[nodeId]!;
    return _stream(chat, node, '\n\n她停顿了一下，又接着说：「还有一件事……我晚点再告诉你。」', started: false);
  }

  @override
  Stream<TavernEvent> impersonate(String chatId) async* {
    yield const TavernTextDelta('', '我推开门，四下看了看。');
    yield TavernTurnDone(
      TavernMessage(nodeId: '', role: TavernRole.user, speaker: 'You', text: '我推开门，四下看了看。', at: _clock()),
    );
  }

  @override
  void stop(String chatId) => _running[chatId]?.close();

  Stream<TavernEvent> _reply(_Chat chat, String? parent, String text) {
    final c = _characters[chat.characterId]!;
    final node = _Node(_id('n'), parent, TavernRole.character, c.name, '', _clock());
    chat.add(node);
    chat.chosen[parent] = node.id;
    return _stream(chat, node, text, started: true);
  }

  Stream<TavernEvent> _stream(_Chat chat, _Node node, String text, {required bool started}) {
    final out = StreamController<TavernEvent>();
    _running[chat.id] = out;
    var stopped = false;
    out.onCancel = () => stopped = true;
    unawaited(() async {
      if (started) out.add(TavernTurnStarted(chat.message(node)));
      chat.touch(_clock());
      if (_thinking && started) {
        for (final piece in _pieces(_sampleReasoning)) {
          await Future<void>.delayed(tick);
          if (stopped || out.isClosed) break;
          node.reasoning = (node.reasoning ?? '') + piece;
          out.add(TavernReasoningDelta(node.id, piece));
        }
      }
      final pieces = _pieces(text);
      for (final piece in pieces) {
        await Future<void>.delayed(tick);
        if (stopped || out.isClosed) break;
        node.text += piece;
        out.add(TavernTextDelta(node.id, piece));
      }
      _running.remove(chat.id);
      chat.changes.add(null);
      _listChanged.add(null);
      if (out.isClosed) return;
      out.add(
        stopped
            ? TavernTurnFailed(TavernFailure.cancelled, partial: chat.message(node))
            : TavernTurnDone(chat.message(node)),
      );
      await out.close();
    }());
    return out.stream;
  }

  // Editing the tree ----------------------------------------------------------

  @override
  Future<void> selectSibling(String chatId, String nodeId, int index) async {
    final chat = _chats[chatId]!;
    final node = chat.nodes[nodeId]!;
    final siblings = chat.children(node.parent);
    // As the engine: the chosen sibling's ancestors are all chosen too, so
    // any node of the tree can be made current in one call.
    var at = siblings[index.clamp(0, siblings.length - 1)];
    for (;;) {
      chat.chosen[at.parent] = at.id;
      final parent = at.parent;
      if (parent == null) break;
      at = chat.nodes[parent]!;
    }
    chat.changes.add(null);
  }

  /// As the engine: [nodeId] and all its ancestors chosen; the path stops at
  /// it unless [restoreDescendants] keeps what was chosen below. Nothing is
  /// deleted.
  @override
  Future<void> selectNode(String chatId, String nodeId, {bool restoreDescendants = false}) async {
    final chat = _chats[chatId]!;
    var at = chat.nodes[nodeId] ?? (throw StateError('No message $nodeId in $chatId'));
    if (!restoreDescendants) chat.chosen.remove(nodeId);
    for (;;) {
      chat.chosen[at.parent] = at.id;
      final parent = at.parent;
      if (parent == null) break;
      at = chat.nodes[parent]!;
    }
    chat.changes.add(null);
  }

  @override
  Future<void> edit(String chatId, String nodeId, String text) async {
    final chat = _chats[chatId]!;
    chat.nodes[nodeId]!.text = text;
    chat.changes.add(null);
  }

  /// What each deletion took, by its undo token, as the engine keeps them
  /// for as long as it is open.
  final _deletions = <String, ({String chatId, _Taken taken})>{};
  var _deletionSerial = 0;

  @override
  Future<String> deleteFrom(String chatId, String nodeId) async {
    final chat = _chats[chatId]!;
    final token = 'deletion-${++_deletionSerial}';
    _deletions[token] = (chatId: chatId, taken: chat.take(nodeId));
    chat.changes.add(null);
    _listChanged.add(null);
    return token;
  }

  @override
  Future<bool> undoDeleteFrom(String chatId, String deletionId) async {
    final deletion = _deletions[deletionId];
    if (deletion == null || deletion.chatId != chatId) return false;
    _deletions.remove(deletionId);
    final chat = _chats[chatId]!;
    chat.restore(deletion.taken);
    chat.changes.add(null);
    _listChanged.add(null);
    return true;
  }

  @override
  Future<List<TavernMessage>> searchChat(String chatId, String query, {int limit = 50}) async {
    if (limit < 0) throw ArgumentError.value(limit, 'limit');
    final chat = _chats[chatId]!;
    if (query.trim().isEmpty || limit == 0) return const [];
    return [
      for (final node in chat.newestFirst())
        if (node.text.contains(query) || node.speaker.contains(query)) chat.message(node),
    ].take(limit).toList();
  }

  // T16, in memory: the card's own lorebook, the whole tree, branch names,
  // one message out, and lines added without a reply.

  /// [c]'s card lorebook entries, made when it has none; a copy of its own
  /// (the sample card's book is a constant), kept on the card.
  List<Object?> _bookEntries(_Char c) {
    final book = _copySetting(c.data['character_book'] ?? const {'entries': <Object?>[]})! as Map<String, Object?>;
    final entries = (book['entries'] as List<Object?>?) ?? <Object?>[];
    // As the engine: an entry without an id takes its index before an edit.
    for (final (i, entry) in entries.indexed) {
      if (entry is Map<String, Object?> && entry['id'] == null) entry['id'] = i;
    }
    book['entries'] = entries;
    c.data['character_book'] = book;
    return entries;
  }

  _Char _characterFor(String characterId) =>
      _characters[characterId] ?? (throw const TavernImportError('missing character'));

  @override
  Future<TavernCharacter> addCharacterBookEntry(String characterId, Map<String, Object?> entry) async {
    final c = _characterFor(characterId);
    final entries = _bookEntries(c);
    final used = {for (final e in entries.whereType<Map<String, Object?>>()) e['id']};
    var id = 0;
    while (used.contains(id)) {
      id++;
    }
    entries.add({..._copySetting(entry)! as Map<String, Object?>, 'id': id});
    _listChanged.add(null);
    return _view(c);
  }

  @override
  Future<TavernCharacter> updateCharacterBookEntry(String characterId, int index, Map<String, Object?> fields) async {
    final c = _characterFor(characterId);
    final entries = _bookEntries(c);
    if (fields.containsKey('id')) throw ArgumentError.value(fields['id'], 'id');
    final entry = entries[RangeError.checkValidIndex(index, entries)]! as Map<String, Object?>;
    _mergeSettings(entry, fields);
    _listChanged.add(null);
    return _view(c);
  }

  @override
  Future<TavernCharacter> deleteCharacterBookEntry(String characterId, int index) async {
    final c = _characterFor(characterId);
    final entries = _bookEntries(c);
    entries.removeAt(RangeError.checkValidIndex(index, entries));
    _listChanged.add(null);
    return _view(c);
  }

  @override
  Future<Map<String, Object?>> previewCharacterBook(
    String characterId,
    String text, {
    String? chatId,
    int seed = 0,
  }) async {
    // A stand-in for the engine's world-info stage: enabled entries, always-on
    // or keyed by a case-blind substring (and, if selective, one secondary
    // key too). No macros, regex, budget, recursion or timed effects.
    final c = _characterFor(characterId);
    final book = c.data['character_book'];
    final entries = book is Map && book['entries'] is List ? book['entries'] as List : const <Object?>[];
    final lower = text.toLowerCase();
    bool said(String key) => key.isNotEmpty && lower.contains(key.toLowerCase());
    List<String> strings(Object? v) => [
      if (v is List)
        for (final s in v)
          if (s is String) s,
    ];
    final activated = <Map<String, Object?>>[];
    for (final (i, e) in entries.indexed) {
      if (e is! Map<String, Object?> || e['enabled'] == false) continue;
      final secondary = strings(e['secondary_keys']);
      final primary = e['constant'] == true ? null : strings(e['keys']).where(said).firstOrNull;
      final matches = secondary.where(said).toList();
      final selective = e['selective'] == true && secondary.isNotEmpty;
      if (e['constant'] != true && (primary == null || (selective && matches.isEmpty))) continue;
      activated.add({
        'bookId': '$characterId:card',
        'uid': '${e['id'] ?? i}',
        'source': 'character',
        'reason': e['constant'] == true ? 'constant' : 'keywords',
        'content': e['content'] is String ? e['content'] : '',
        'originalContent': e['content'] is String ? e['content'] : '',
        'order': e['insertion_order'] is num ? e['insertion_order'] : 100,
        'position': e['position'] == 'after_char' ? 1 : 0,
        'primaryKey': primary,
        'secondaryMatches': primary == null ? const <String>[] : matches,
      });
    }
    activated.sort((a, b) => (b['order']! as num).compareTo(a['order']! as num));
    return {
      'scope': 'character-book',
      'stage': 'world-info',
      'seed': seed,
      'chatId': chatId,
      'contextNodeId': null,
      'overflowed': false,
      'scanRounds': 1,
      'activated': activated,
      'preparedEffects': const <Object?>[],
    };
  }

  @override
  Future<List<TavernTreeNode>> tree(String chatId) async {
    final chat = _chats[chatId]!;
    final current = {for (final m in chat.path()) m.nodeId};
    return [
      for (final node in chat.inOrder())
        () {
          final siblings = chat.children(node.parent);
          return TavernTreeNode(
            nodeId: node.id,
            parentId: node.parent,
            role: node.role,
            speaker: node.speaker,
            preview: String.fromCharCodes(node.text.runes.take(64)),
            at: node.at,
            isCurrentPath: current.contains(node.id),
            siblingIndex: siblings.indexOf(node),
            siblingCount: siblings.length,
            hidden: node.hidden,
            branchName: chat.branchNames[node.id],
          );
        }(),
    ];
  }

  @override
  Future<Map<String, Object?>> readVariables(String chatId) async => {};

  /// The preview keeps no state: the selected leaf's empty ST-variables view,
  /// as a card without a state schema reads.
  @override
  Future<TavernStateSnapshot> readState(String chatId) async => TavernStateSnapshot(
    chatId: chatId,
    nodeId: _chats[chatId]!.tail()?.id,
    legacy: true,
    initialized: false,
    valueExists: false,
    automaticEnabled: false,
    values: const <String, Object?>{},
  );

  /// Not kept here, so not pretended: an edit is refused.
  @override
  Future<TavernStateEditResult> setStateValue(String chatId, String path, Object? value, {String? expectedNodeId}) =>
      Future.error(UnsupportedError('The preview tavern keeps no state.'));

  @override
  Future<List<TavernAgentRun>> readAgentRuns(String chatId, {String? nodeId, int limit = 50}) async {
    if (limit < 0) throw ArgumentError.value(limit, 'limit');
    return const [];
  }

  /// [node] added at the end of [chat]'s current path.
  TavernMessage _append(_Chat chat, TavernRole role, String speaker, String text) {
    final parent = chat.tail()?.id;
    final node = _Node(_id('n'), parent, role, speaker, text, _clock());
    chat.add(node);
    chat.chosen[parent] = node.id;
    chat.touch(node.at);
    chat.changes.add(null);
    _listChanged.add(null);
    return chat.message(node);
  }

  @override
  Future<TavernMessage> sendOnly(String chatId, String text) async =>
      _append(_chats[chatId]!, TavernRole.user, 'You', text);

  @override
  Future<TavernMessage> narrate(String chatId, String text, {String? speaker}) async =>
      _append(_chats[chatId]!, TavernRole.narrator, speaker ?? 'System', text.trim());

  @override
  Future<void> nameBranch(String chatId, String nodeId, String? name) async {
    final chat = _chats[chatId]!;
    final label = name?.trim() ?? '';
    if (label.isEmpty) {
      chat.branchNames.remove(nodeId);
    } else {
      chat.branchNames[nodeId] = label;
    }
    chat.changes.add(null);
  }

  @override
  Future<void> deleteMessage(String chatId, String nodeId) async {
    final chat = _chats[chatId]!;
    chat.removeOne(nodeId);
    chat.changes.add(null);
    _listChanged.add(null);
  }

  /// The preview runs a turn only for the stream that asked for it: there is
  /// none to rejoin.
  @override
  Stream<TavernEvent> resumeTurn(String chatId) => const Stream.empty();

  @override
  Future<TavernBackupInfo> backup(String destinationPath) async =>
      throw UnsupportedError('The preview keeps nothing to back up.');

  @override
  Future<void> setHidden(String chatId, String nodeId, bool hidden) async {
    final chat = _chats[chatId]!;
    chat.nodes[nodeId]!.hidden = hidden;
    chat.changes.add(null);
  }

  @override
  void configure(TavernModelConfig config) => _thinking = config.thinking;

  /// 思考 is on: replies think a little first.
  var _thinking = false;

  /// Settings as the engine keeps them: the global ones, and each chat's over
  /// them. Objects merge; lists and values replace; null is a value too.
  final _globalSettings = <String, Object?>{};
  final _chatSettings = <String, Map<String, Object?>>{};

  @override
  Future<Map<String, Object?>> readSettings({String? chatId}) async {
    final settings = <String, Object?>{};
    _mergeSettings(settings, _globalSettings);
    if (_chatSettings[chatId] case final chat?) _mergeSettings(settings, chat);
    return settings;
  }

  @override
  Future<void> setSettings(Map<String, Object?> patch, {String? chatId}) async =>
      _mergeSettings(chatId == null ? _globalSettings : _chatSettings.putIfAbsent(chatId, () => {}), patch);

  /// No helper runs in the preview: directing is off, nothing pending, no
  /// runs or proposals.
  @override
  Future<TavernDirectorSnapshot> readDirector(String chatId) async {
    if (!_chats.containsKey(chatId)) throw StateError('No chat $chatId');
    return TavernDirectorSnapshot(
      chatId: chatId,
      automaticEnabled: false,
      pendingJobs: 0,
      running: false,
      stale: false,
    );
  }

  @override
  Stream<TavernDirectorSnapshot> watchDirector(String chatId) => Stream.fromFuture(readDirector(chatId));

  /// No model here to ask, so not pretended.
  @override
  Future<TavernDirectorRun> runDirector(String chatId) =>
      Future.error(UnsupportedError('The preview tavern has no director.'));

  @override
  Future<List<TavernDirectorEvent>> readDirectorEvents(String chatId, {int limit = 50, String? beforeEventId}) async {
    if (limit < 0) throw ArgumentError.value(limit, 'limit');
    return const [];
  }

  // Presets, kept in memory as the engine keeps them; no regex scripts or
  // lorebooks of its own (importing one says so), and its text shows as written.

  @override
  Future<TavernDisplayResult> displayText(
    String chatId, {
    String? nodeId,
    String? text,
    TavernRole? role,
    String? speaker,
    num? depth,
    bool reasoning = false,
  }) async => TavernDisplayResult(
    text: text ?? _chats[chatId]?.nodes[nodeId]?.text ?? (throw StateError('No message $nodeId in $chatId')),
  );

  final _presets = <String, TavernPreset>{};
  final _presetsChanged = StreamController<void>.broadcast();
  var _presetCount = 0;
  String? _defaultPreset;
  final _chatPresets = <String, String?>{};

  List<TavernPresetSummary> _presetList() =>
      [for (final p in _presets.values) p.summary]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Future<List<TavernPresetSummary>> listPresets() async => _presetList();

  @override
  Stream<List<TavernPresetSummary>> watchPresets() async* {
    yield _presetList();
    await for (final _ in _presetsChanged.stream) {
      yield _presetList();
    }
  }

  @override
  Future<TavernPreset?> preset(String presetId) async => _presets[presetId];

  @override
  Future<TavernPresetImportResult> importPreset(String text, {String? fileName}) async {
    final Object? json;
    try {
      json = jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
    } on FormatException {
      throw TavernPresetImportError([
        const TavernPresetIssue(
          path: r'$',
          code: 'json',
          message: 'not JSON',
          severity: TavernPresetIssueSeverity.error,
        ),
      ]);
    }
    if (json is! Map<String, Object?>) {
      throw TavernPresetImportError([
        const TavernPresetIssue(
          path: r'$',
          code: 'object',
          message: 'not an object',
          severity: TavernPresetIssueSeverity.error,
        ),
      ]);
    }
    final at = DateTime.now();
    final id = 'preset-${_presetCount++}';
    final name = fileName == null
        ? 'Preset $_presetCount'
        : fileName.replaceFirst(RegExp(r'\.json$', caseSensitive: false), '');
    final preset = TavernPreset(id: id, name: name, sourceText: text, raw: json, createdAt: at, updatedAt: at);
    _presets[id] = preset;
    _presetsChanged.add(null);
    return TavernPresetImportResult(preset, const []);
  }

  @override
  Future<TavernPresetImportResult> updatePreset(String presetId, Map<String, Object?> patch, {String? name}) async {
    final old = _presets[presetId]!;
    // As the engine: objects merge, arrays and scalars are replaced.
    final raw = _copySetting(old.raw)! as Map<String, Object?>;
    _mergeSettings(raw, patch);
    final preset = TavernPreset(
      id: old.id,
      name: name ?? old.name,
      sourceText: old.sourceText,
      raw: raw,
      envelope: old.envelope,
      createdAt: old.createdAt,
      updatedAt: DateTime.now(),
    );
    _presets[presetId] = preset;
    _presetsChanged.add(null);
    return TavernPresetImportResult(preset, const []);
  }

  @override
  Future<TavernPresetImportResult> updatePresetPrompt(String presetId, String identifier, Map<String, Object?> patch) =>
      _editPreset(presetId, (raw) {
        final prompts = [
          for (final p in (raw['prompts'] as List?) ?? const []) Map<String, Object?>.of(p as Map<String, Object?>),
        ];
        final i = prompts.indexWhere((p) => p['identifier'] == identifier);
        if (i >= 0) prompts[i] = {...prompts[i], ...patch};
        raw['prompts'] = prompts;
      });

  @override
  Future<TavernPresetImportResult> setPresetOrder(String presetId, List<String> identifiers) =>
      _editPreset(presetId, (raw) {
        final order = _orderOf(raw);
        order['order'] = [
          for (final id in identifiers)
            {
              'identifier': id,
              'enabled':
                  [
                    for (final e in (order['order'] as List?) ?? const [])
                      if ((e as Map)['identifier'] == id) e['enabled'],
                  ].firstOrNull ??
                  true,
            },
        ];
      });

  @override
  Future<TavernPresetImportResult> setPresetPromptEnabled(String presetId, String identifier, bool enabled) =>
      _editPreset(presetId, (raw) {
        final order = _orderOf(raw);
        final list = [
          for (final e in (order['order'] as List?) ?? const []) Map<String, Object?>.of(e as Map<String, Object?>),
        ];
        final i = list.indexWhere((e) => e['identifier'] == identifier);
        i < 0 ? list.add({'identifier': identifier, 'enabled': enabled}) : list[i]['enabled'] = enabled;
        order['order'] = list;
      });

  /// The 100001 group of [raw]'s prompt_order, made when missing (from the
  /// first group), as the engine edits it.
  static Map<String, Object?> _orderOf(Map<String, Object?> raw) {
    final groups = [
      for (final g in (raw['prompt_order'] as List?) ?? const []) Map<String, Object?>.of(g as Map<String, Object?>),
    ];
    var i = groups.indexWhere((g) => '${g['character_id']}' == '100001');
    if (i < 0) {
      groups.add({'character_id': 100001, 'order': groups.isEmpty ? <Object?>[] : groups.first['order']});
      i = groups.length - 1;
    }
    raw['prompt_order'] = groups;
    return groups[i];
  }

  Future<TavernPresetImportResult> _editPreset(String presetId, void Function(Map<String, Object?> raw) edit) async {
    final old = _presets[presetId]!;
    final raw = old.raw;
    edit(raw);
    final preset = TavernPreset(
      id: old.id,
      name: old.name,
      sourceText: old.sourceText,
      raw: raw,
      envelope: old.envelope,
      createdAt: old.createdAt,
      updatedAt: DateTime.now(),
    );
    _presets[presetId] = preset;
    _presetsChanged.add(null);
    return TavernPresetImportResult(preset, const []);
  }

  @override
  Future<String> exportPreset(String presetId) async => _presets[presetId]!.sourceText;

  @override
  Future<TavernPresetSelection> presetSelection({String? chatId}) async {
    final bound = chatId == null ? null : _chatPresets[chatId];
    final effective = bound ?? _defaultPreset;
    return TavernPresetSelection(
      source: bound != null
          ? PresetSelectionSource.chat
          : _defaultPreset != null
          ? PresetSelectionSource.globalDefault
          : PresetSelectionSource.stDefault,
      boundPresetId: bound,
      defaultPresetId: _defaultPreset,
      effectivePresetId: effective,
    );
  }

  @override
  Future<void> setDefaultPreset(String? presetId) async {
    _defaultPreset = presetId;
    _presetsChanged.add(null);
  }

  @override
  Future<void> bindPreset(String chatId, String? presetId) async {
    _chatPresets[chatId] = presetId;
    _presetsChanged.add(null);
  }

  @override
  Future<void> deletePreset(String presetId) async {
    _presets.remove(presetId);
    if (_defaultPreset == presetId) _defaultPreset = null;
    _chatPresets.removeWhere((_, id) => id == presetId);
    _presetsChanged.add(null);
  }

  /// The preview files no import reports.
  @override
  Future<TavernImportReport?> readImportReport(TavernImportKind kind, String assetId) async => null;

  @override
  Future<TavernImportReport> recheckImport(TavernImportKind kind, String assetId) =>
      throw UnsupportedError('The preview keeps no import reports');

  final _regex = <String, TavernRegexScript>{};
  var _regexCount = 0;

  @override
  Future<List<TavernRegexScript>> listRegexScripts() async => _regex.values.toList();

  /// Global regex scripts, kept in memory: one ST script or a list of them.
  @override
  Future<TavernRegexImportResult> importRegexScripts(String text) async {
    final json = jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
    final rules = json is List ? json : [json];
    final scripts = [
      for (final rule in rules.whereType<Map<String, Object?>>())
        TavernRegexScript(id: 'regex-${_regexCount++}', sourceText: text, raw: rule, importedAt: DateTime.now()),
    ];
    if (scripts.isEmpty) throw const FormatException('No regex scripts');
    for (final script in scripts) {
      _regex[script.id] = script;
    }
    return TavernRegexImportResult(scripts);
  }

  @override
  Future<TavernRegexScript> setRegexEnabled(String regexId, bool enabled) async {
    final old = _regex[regexId]!;
    return _regex[regexId] = TavernRegexScript(
      id: old.id,
      sourceText: old.sourceText,
      raw: {...old.raw, 'disabled': !enabled},
      importedAt: old.importedAt,
      diagnostics: old.diagnostics,
    );
  }

  /// An edit in place, as the engine makes it: the patch copied when called,
  /// merged into the rule (maps by key, the rest replaced, null kept), its
  /// id, place and first source kept. The preview checks nothing: the rule
  /// keeps the findings it had (none), not a fresh 「compatible」.
  @override
  Future<TavernRegexScript> updateRegexScript(String regexId, Map<String, Object?> patch) {
    final captured = jsonDecode(jsonEncode(patch)) as Map<String, Object?>;
    return Future.sync(() {
      final old = _regex[regexId];
      if (old == null) throw TavernImportError('No regex script $regexId');
      Map<String, Object?> merge(Map<String, Object?> base, Map<String, Object?> edit) => {
        ...base,
        for (final MapEntry(:key, :value) in edit.entries)
          key: switch ((base[key], value)) {
            (final Map<String, Object?> was, final Map<String, Object?> now) => merge(was, now),
            _ => value,
          },
      };
      return _regex[regexId] = TavernRegexScript(
        id: old.id,
        sourceText: old.sourceText,
        raw: merge(old.raw, captured),
        importedAt: old.importedAt,
        diagnostics: old.diagnostics,
      );
    });
  }

  @override
  Future<void> deleteRegex(String regexId) async => _regex.remove(regexId);

  @override
  Future<String> exportRegex({String? regexId}) async => jsonEncode([
    for (final s in _regex.values)
      if (regexId == null || s.id == regexId) s.raw,
  ]);

  // Standalone lorebooks, kept in memory; their bindings go into the
  // settings as the engine keeps them (lorebooks.<source>).

  final _books = <String, TavernLorebook>{};
  var _bookCount = 0;

  @override
  Future<List<TavernLorebookSummary>> listLorebooks() async => _books.values.toList();

  @override
  Future<TavernLorebookImportResult> importLorebook(String text, {String? fileName}) async {
    final json = jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
    if (json is! Map<String, Object?> || json['entries'] == null) throw const FormatException('Not a lorebook');
    final entries = json['entries'];
    final name = fileName?.replaceFirst(RegExp(r'\.json$', caseSensitive: false), '') ?? 'Lorebook ${_bookCount + 1}';
    final book = TavernLorebook(
      id: 'book-${_bookCount++}',
      name: name,
      entryCount: entries is Map ? entries.length : (entries is List ? entries.length : 0),
      stWorldName: name,
      raw: json,
    );
    _books[book.id] = book;
    return TavernLorebookImportResult(book, const []);
  }

  @override
  Future<Map<String, Object?>?> lorebook(String id) async => _books[id]?.raw;

  @override
  Future<void> putLorebook(String id, Map<String, Object?> json) async {
    final old = _books[id];
    final entries = json['entries'];
    _books[id] = TavernLorebook(
      id: id,
      name: old?.name ?? id,
      entryCount: entries is Map ? entries.length : (entries is List ? entries.length : 0),
      stWorldName: old?.stWorldName,
      raw: json,
    );
  }

  @override
  Future<String> exportLorebook(String id) async => jsonEncode(_books[id]!.raw);

  @override
  Future<void> deleteLorebook(String id) async => _books.remove(id);

  @override
  Future<void> bindLorebooks(
    List<String> ids, {
    WorldInfoSource source = WorldInfoSource.global,
    String? chatId,
    String? characterId,
    String? personaId,
  }) => switch ((characterId, personaId)) {
    (final String id, _) => setSettings({
      'characterLorebooks': {id: ids},
    }),
    (_, final String id) => setSettings({
      'personaLorebooks': {id: ids},
    }),
    _ => setSettings({
      'lorebooks': {source.name: ids},
    }, chatId: chatId),
  };

  @override
  Future<void> close() async {
    await _listChanged.close();
    await _presetsChanged.close();
  }
}

/// [patch] into [into], copied: a reader never holds what is stored.
void _mergeSettings(Map<String, Object?> into, Map<String, Object?> patch) {
  for (final MapEntry(:key, :value) in patch.entries) {
    if (into[key] case final Map<String, Object?> old when value is Map<String, Object?>) {
      _mergeSettings(old, value);
    } else {
      into[key] = _copySetting(value);
    }
  }
}

/// A card's extensions.dshgo, or nothing.
Map<Object?, Object?> _dshgoOf(Map<String, Object?> data) => switch (data['extensions']) {
  {'dshgo': final Map<Object?, Object?> dshgo} => dshgo,
  _ => const {},
};

Object? _copySetting(Object? value) => switch (value) {
  final Map<String, Object?> map => {for (final MapEntry(:key, :value) in map.entries) key: _copySetting(value)},
  final List<Object?> list => [for (final item in list) _copySetting(item)],
  _ => value,
};

class _Card {
  const _Card({
    required this.id,
    required this.name,
    required this.description,
    required this.greetings,
    this.creator,
    this.tags = const [],
    this.creatorNotes = '',
    this.book,
  });

  final String id;
  final String name;
  final String? creator;
  final List<String> tags;
  final String description;
  final String creatorNotes;
  final List<String> greetings;

  /// A V3 character_book, as a card carries it.
  final Map<String, Object?>? book;
}

class _Char {
  _Char(_Card card, this.importedAt)
    : id = card.id,
      data = {
        'name': card.name,
        'nickname': '',
        'description': card.description,
        'personality': '',
        'scenario': '',
        'first_mes': card.greetings.first,
        'alternate_greetings': card.greetings.skip(1).toList(),
        'mes_example': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'creator_notes': card.creatorNotes,
        'creator': card.creator ?? '',
        'character_version': '',
        'tags': [...card.tags],
        'extensions': <String, Object?>{
          'depth_prompt': {'prompt': '', 'depth': 4},
        },
        'character_book': ?card.book,
      };

  final String id;

  /// The card's V3 `data`, as [Tavern.characterFields] gives it.
  final Map<String, Object?> data;
  final DateTime importedAt;

  String get name => data['name']! as String;
  String? get creator => switch (data['creator']) {
    final String c when c.isNotEmpty => c,
    _ => null,
  };
  List<String> get tags => (data['tags']! as List).cast<String>();
  String get description => data['description']! as String;
  String get creatorNotes => data['creator_notes']! as String;
  List<String> get greetings => [
    data['first_mes']! as String,
    ...(data['alternate_greetings']! as List).cast<String>(),
  ];
}

class _Node {
  _Node(this.id, this.parent, this.role, this.speaker, this.text, this.at);
  final String id;
  final String? parent;
  final TavernRole role;
  final String speaker;
  String text;
  String? reasoning;
  final DateTime at;
  bool hidden = false;
}

/// A deletion's nodes, each with its place in the order, and the chosen path
/// before and after it.
typedef _Taken = ({List<(int, _Node)> nodes, Map<String?, String> before, Map<String?, String> after});

class _Chat {
  _Chat(this.id, this.characterId, this.title, this.updatedAt);
  final String id;
  final String characterId;
  final String title;
  DateTime updatedAt;
  final nodes = <String, _Node>{};
  final _order = <String>[];

  /// The child each node continues with (null key: the root).
  final chosen = <String?, String>{};
  final changes = StreamController<void>.broadcast();

  void add(_Node node) {
    nodes[node.id] = node;
    _order.add(node.id);
  }

  void touch(DateTime at) => updatedAt = at;

  List<_Node> children(String? parent) => [
    for (final id in _order)
      if (nodes[id]!.parent == parent) nodes[id]!,
  ];

  /// The nodes from the root down the chosen children.
  List<_Node> _walk() {
    final out = <_Node>[];
    var next = chosen[null];
    while (next != null && nodes.containsKey(next)) {
      out.add(nodes[next]!);
      next = chosen[next];
    }
    return out;
  }

  _Node? tail() => _walk().lastOrNull;

  List<TavernMessage> path() => [for (final node in _walk()) message(node)];

  TavernMessage message(_Node node) {
    final siblings = children(node.parent);
    return TavernMessage(
      nodeId: node.id,
      parentId: node.parent,
      role: node.role,
      speaker: node.speaker,
      text: node.text,
      reasoning: node.reasoning,
      at: node.at,
      siblingIndex: siblings.indexOf(node),
      siblingCount: siblings.length,
      hidden: node.hidden,
    );
  }

  /// Every node, the newest first.
  Iterable<_Node> newestFirst() => [for (final id in _order.reversed) nodes[id]!];

  /// Every node, in the order it was added.
  Iterable<_Node> inOrder() => [for (final id in _order) nodes[id]!];

  /// Names given to branches, by the node each starts at.
  final branchNames = <String, String>{};

  /// [id] alone out: its children move up to its parent, the path through it
  /// goes on through the child it continued with.
  void removeOne(String id) {
    final node = nodes[id];
    if (node == null) return;
    final next = chosen[id];
    for (final child in children(id)) {
      nodes[child.id] = _Node(child.id, node.parent, child.role, child.speaker, child.text, child.at)
        ..reasoning = child.reasoning
        ..hidden = child.hidden;
    }
    nodes.remove(id);
    _order.remove(id);
    chosen.remove(id);
    branchNames.remove(id);
    if (chosen[node.parent] == id) {
      if (next != null) {
        chosen[node.parent] = next;
      } else {
        final rest = children(node.parent);
        if (rest.isEmpty) {
          chosen.remove(node.parent);
        } else {
          chosen[node.parent] = rest.last.id;
        }
      }
    }
  }

  /// [id] and everything under it taken out, with what [restore] needs.
  _Taken take(String id) {
    final before = Map.of(chosen);
    bool under(String? node) {
      for (var at = node; at != null; at = nodes[at]?.parent) {
        if (at == id) return true;
      }
      return false;
    }

    final taken = [
      for (final (i, node) in _order.indexed)
        if (under(node)) (i, nodes[node]!),
    ];
    remove(id);
    return (nodes: taken, before: before, after: Map.of(chosen));
  }

  /// Puts back what [take] took, each where it was; the path it was on too,
  /// unless the chat has gone another way since.
  void restore(_Taken taken) {
    final unchanged = chosen.length == taken.after.length && chosen.entries.every((e) => taken.after[e.key] == e.value);
    for (final (i, node) in taken.nodes) {
      nodes[node.id] = node;
      _order.insert(math.min(i, _order.length), node.id);
    }
    if (unchanged) {
      chosen
        ..clear()
        ..addAll(taken.before);
    }
  }

  void remove(String id) {
    final node = nodes[id];
    if (node == null) return;
    for (final child in children(id)) {
      remove(child.id);
    }
    nodes.remove(id);
    _order.remove(id);
    chosen.remove(id);
    if (chosen[node.parent] == id) {
      final rest = children(node.parent);
      if (rest.isEmpty) {
        chosen.remove(node.parent);
      } else {
        chosen[node.parent] = rest.last.id;
      }
    }
  }
}

Iterable<String> _pieces(String text) => RegExp(r'.{1,3}', dotAll: true).allMatches(text).map((m) => m[0]!);

const _sampleReasoning = '她在等一个答案，但不想说得太多。先回应眼前的问题，再留一点悬念。';

String _cannedFor(String text) => text.contains('?') || text.contains('？') ? _canned[1] : _canned[0];

const _canned = [
  '*她把手里的杯子放下，抬眼看你。*\n\n「你来得正好。外面的雨一直没停，镇上的人都躲在屋里。」\n\n她往壁炉那边挪了挪，给你让出一个位置。「坐吧，我去给你倒点热的。」',
  '「这个问题啊……」她想了想，手指在桌面上轻轻敲着。\n\n「我只能告诉你我知道的那部分。剩下的，你得自己去地下室看看。」',
  '*门外传来一阵脚步声，又很快远去。*\n\n她没有回头，只是低声说：「别出声，等他们走远。」',
];

const _samples = [
  _Card(
    id: 'sample-innkeeper',
    name: '林晚',
    creator: 'DSH Go',
    tags: ['示例', '悬疑'],
    description: '雨夜小镇上一家旅店的老板娘，知道很多事，但只说一半。',
    creatorNotes: '这是一张示例卡，用来预览酒馆的界面。',
    book: {
      'name': '雨镇',
      'entries': [
        {
          'keys': ['地下室', '酒窖'],
          'comment': '地下室',
          'content': '旅店地下室名义上是酒窖，钥匙只有林晚有。',
          'insertion_order': 100,
          'enabled': true,
          'constant': false,
        },
        {
          'keys': ['雨'],
          'comment': '连雨',
          'content': '雨已经下了三天，桥被冲断了。',
          'insertion_order': 90,
          'enabled': true,
          'constant': true,
        },
      ],
    },
    greetings: [
      '*旅店的门被风推开，带进一阵冷雨。柜台后面的女人抬起头。*\n\n「这么晚了还在赶路？进来吧，炉子还热着。」',
      '*你醒来时，发现自己躺在旅店二楼的床上。窗外还在下雨。*\n\n「你可算醒了。」门口的女人端着一碗汤，「昨晚你倒在门口，吓我一跳。」',
    ],
  ),
  _Card(
    id: 'sample-navigator',
    name: '星图',
    creator: 'DSH Go',
    tags: ['示例', '科幻'],
    description: '远航飞船上的导航 AI，说话简短，偶尔会讲冷笑话。',
    greetings: ['「舰桥欢迎你，舰长。航线已经算好，还有三十七个小时抵达。要听个笑话打发时间吗？」'],
  ),
];
