// A [Tavern] that is still opening (the engine opens its database and reads
// its settings asynchronously). Calls wait for it; streams start once it is
// open. The latest [configure] reaches it when it opens, so 酒馆设置 can be
// applied straight away.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';

class DeferredTavern implements Tavern {
  DeferredTavern(Future<Tavern> opening) {
    _ready = opening.then((tavern) {
      _open = tavern;
      if (_config case final config?) tavern.configure(config);
      return tavern;
    });
  }

  late final Future<Tavern> _ready;
  Tavern? _open;
  TavernModelConfig? _config;

  Stream<T> _stream<T>(Stream<T> Function(Tavern t) call) => Stream.fromFuture(_ready).asyncExpand(call);

  @override
  Stream<List<TavernCharacter>> watchCharacters() => _stream((t) => t.watchCharacters());

  @override
  Future<TavernCharacter?> character(String id) async => (await _ready).character(id);

  @override
  Future<TavernCharacter> importCard(Uint8List bytes, {String? fileName}) async =>
      (await _ready).importCard(bytes, fileName: fileName);

  @override
  Future<Uint8List> exportCard(String characterId, {TavernCardFormat format = TavernCardFormat.png}) async =>
      (await _ready).exportCard(characterId, format: format);

  @override
  Future<void> deleteCharacter(String characterId) async => (await _ready).deleteCharacter(characterId);

  @override
  Future<Map<String, Object?>?> characterFields(String characterId) async =>
      (await _ready).characterFields(characterId);

  @override
  Future<TavernCharacter> updateCharacterFields(String characterId, Map<String, Object?> fields) async =>
      (await _ready).updateCharacterFields(characterId, fields);

  @override
  Stream<List<TavernPersona>> watchPersonas() => _stream((t) => t.watchPersonas());

  @override
  Future<TavernPersona?> persona(String personaId) async => (await _ready).persona(personaId);

  @override
  Future<TavernPersona> createPersona({
    required String name,
    String description = '',
    String? avatarPath,
    int descriptionPosition = PersonaDescriptionPosition.inPrompt,
  }) async => (await _ready).createPersona(
    name: name,
    description: description,
    avatarPath: avatarPath,
    descriptionPosition: descriptionPosition,
  );

  @override
  Future<TavernPersona> updatePersona(
    String personaId, {
    String? name,
    String? description,
    String? avatarPath,
    bool clearAvatar = false,
    int? descriptionPosition,
  }) async => (await _ready).updatePersona(
    personaId,
    name: name,
    description: description,
    avatarPath: avatarPath,
    clearAvatar: clearAvatar,
    descriptionPosition: descriptionPosition,
  );

  @override
  Future<void> deletePersona(String personaId) async => (await _ready).deletePersona(personaId);

  @override
  Future<PersonaSelection> personaSelection({String? chatId}) async => (await _ready).personaSelection(chatId: chatId);

  @override
  Future<void> setDefaultPersona(String? personaId) async => (await _ready).setDefaultPersona(personaId);

  @override
  Future<void> bindPersona(String chatId, String? personaId) async => (await _ready).bindPersona(chatId, personaId);

  @override
  Stream<List<TavernChatSummary>> watchChats({String? characterId}) =>
      _stream((t) => t.watchChats(characterId: characterId));

  @override
  Future<String> createChat(String characterId, {int greeting = 0}) async =>
      (await _ready).createChat(characterId, greeting: greeting);

  @override
  Future<TavernChatImportResult> importChats(
    String characterId,
    List<TavernChatFile> files, {
    Map<String, String> lorebookIds = const {},
  }) async => (await _ready).importChats(characterId, files, lorebookIds: lorebookIds);

  @override
  Future<List<TavernChatFile>> exportChat(String chatId, {String? fileName}) async =>
      (await _ready).exportChat(chatId, fileName: fileName);

  @override
  Future<void> deleteChat(String chatId) async => (await _ready).deleteChat(chatId);

  @override
  Future<List<TavernMessage>> path(String chatId, {int limit = 60, String? beforeNodeId}) async =>
      (await _ready).path(chatId, limit: limit, beforeNodeId: beforeNodeId);

  @override
  Stream<void> pathChanges(String chatId) => _stream((t) => t.pathChanges(chatId));

  @override
  Stream<TavernEvent> send(String chatId, String text) => _stream((t) => t.send(chatId, text));

  @override
  Stream<TavernEvent> regenerate(String chatId, String nodeId) => _stream((t) => t.regenerate(chatId, nodeId));

  @override
  Stream<TavernEvent> continueReply(String chatId, String nodeId) => _stream((t) => t.continueReply(chatId, nodeId));

  @override
  Stream<TavernEvent> impersonate(String chatId) => _stream((t) => t.impersonate(chatId));

  /// Nothing to stop before it is open: no turn can be running yet.
  @override
  void stop(String chatId) => _open?.stop(chatId);

  @override
  Future<void> selectSibling(String chatId, String nodeId, int index) async =>
      (await _ready).selectSibling(chatId, nodeId, index);

  @override
  Future<void> selectNode(String chatId, String nodeId, {bool restoreDescendants = false}) async =>
      (await _ready).selectNode(chatId, nodeId, restoreDescendants: restoreDescendants);

  @override
  Future<void> edit(String chatId, String nodeId, String text) async => (await _ready).edit(chatId, nodeId, text);

  @override
  Future<String> deleteFrom(String chatId, String nodeId) async => (await _ready).deleteFrom(chatId, nodeId);

  @override
  Future<TavernCharacter> addCharacterBookEntry(String characterId, Map<String, Object?> entry) async =>
      (await _ready).addCharacterBookEntry(characterId, entry);

  @override
  Future<TavernCharacter> updateCharacterBookEntry(String characterId, int index, Map<String, Object?> fields) async =>
      (await _ready).updateCharacterBookEntry(characterId, index, fields);

  @override
  Future<TavernCharacter> deleteCharacterBookEntry(String characterId, int index) async =>
      (await _ready).deleteCharacterBookEntry(characterId, index);

  @override
  Future<Map<String, Object?>> previewCharacterBook(
    String characterId,
    String text, {
    String? chatId,
    int seed = 0,
  }) async => (await _ready).previewCharacterBook(characterId, text, chatId: chatId, seed: seed);

  @override
  Future<List<TavernTreeNode>> tree(String chatId) async => (await _ready).tree(chatId);

  @override
  Future<Map<String, Object?>> readVariables(String chatId) async => (await _ready).readVariables(chatId);

  @override
  Future<TavernStateSnapshot> readState(String chatId) async => (await _ready).readState(chatId);

  @override
  Future<TavernStateEditResult> setStateValue(
    String chatId,
    String path,
    Object? value, {
    String? expectedNodeId,
  }) async => (await _ready).setStateValue(chatId, path, value, expectedNodeId: expectedNodeId);

  @override
  Future<List<TavernAgentRun>> readAgentRuns(String chatId, {String? nodeId, int limit = 50}) async =>
      (await _ready).readAgentRuns(chatId, nodeId: nodeId, limit: limit);

  @override
  Future<TavernMessage> sendOnly(String chatId, String text) async => (await _ready).sendOnly(chatId, text);

  @override
  Future<TavernMessage> narrate(String chatId, String text, {String? speaker}) async =>
      (await _ready).narrate(chatId, text, speaker: speaker);

  @override
  Future<void> nameBranch(String chatId, String nodeId, String? name) async =>
      (await _ready).nameBranch(chatId, nodeId, name);

  @override
  Future<void> deleteMessage(String chatId, String nodeId) async => (await _ready).deleteMessage(chatId, nodeId);

  @override
  Future<bool> undoDeleteFrom(String chatId, String deletionId) async =>
      (await _ready).undoDeleteFrom(chatId, deletionId);

  @override
  Future<List<TavernMessage>> searchChat(String chatId, String query, {int limit = 50}) async =>
      (await _ready).searchChat(chatId, query, limit: limit);

  @override
  Stream<TavernEvent> resumeTurn(String chatId) => _stream((t) => t.resumeTurn(chatId));

  @override
  Future<TavernBackupInfo> backup(String destinationPath) async => (await _ready).backup(destinationPath);

  @override
  Future<void> setHidden(String chatId, String nodeId, bool hidden) async =>
      (await _ready).setHidden(chatId, nodeId, hidden);

  @override
  Future<TavernTurnInspection?> inspectTurn(String chatId, {String? nodeId}) async =>
      (await _ready).inspectTurn(chatId, nodeId: nodeId);

  @override
  void configure(TavernModelConfig config) {
    _config = config;
    _open?.configure(config);
  }

  // Display regex, presets, regex scripts and lorebooks (T20, T21) -----------

  @override
  Future<TavernDisplayResult> displayText(
    String chatId, {
    String? nodeId,
    String? text,
    TavernRole? role,
    String? speaker,
    num? depth,
    bool reasoning = false,
  }) async => (await _ready).displayText(
    chatId,
    nodeId: nodeId,
    text: text,
    role: role,
    speaker: speaker,
    depth: depth,
    reasoning: reasoning,
  );

  @override
  Future<List<TavernPresetSummary>> listPresets() async => (await _ready).listPresets();

  @override
  Stream<List<TavernPresetSummary>> watchPresets() => _stream((t) => t.watchPresets());

  @override
  Future<TavernPreset?> preset(String presetId) async => (await _ready).preset(presetId);

  @override
  Future<TavernPresetImportResult> importPreset(String text, {String? fileName}) async =>
      (await _ready).importPreset(text, fileName: fileName);

  @override
  Future<TavernPresetImportResult> updatePreset(String presetId, Map<String, Object?> patch, {String? name}) async =>
      (await _ready).updatePreset(presetId, patch, name: name);

  @override
  Future<TavernPresetImportResult> updatePresetPrompt(
    String presetId,
    String identifier,
    Map<String, Object?> patch,
  ) async => (await _ready).updatePresetPrompt(presetId, identifier, patch);

  @override
  Future<TavernPresetImportResult> setPresetOrder(String presetId, List<String> identifiers) async =>
      (await _ready).setPresetOrder(presetId, identifiers);

  @override
  Future<TavernPresetImportResult> setPresetPromptEnabled(String presetId, String identifier, bool enabled) async =>
      (await _ready).setPresetPromptEnabled(presetId, identifier, enabled);

  @override
  Future<String> exportPreset(String presetId) async => (await _ready).exportPreset(presetId);

  @override
  Future<TavernPresetSelection> presetSelection({String? chatId}) async =>
      (await _ready).presetSelection(chatId: chatId);

  @override
  Future<void> setDefaultPreset(String? presetId) async => (await _ready).setDefaultPreset(presetId);

  @override
  Future<void> bindPreset(String chatId, String? presetId) async => (await _ready).bindPreset(chatId, presetId);

  @override
  Future<void> deletePreset(String presetId) async => (await _ready).deletePreset(presetId);

  @override
  Future<List<TavernRegexScript>> listRegexScripts() async => (await _ready).listRegexScripts();

  @override
  Future<TavernRegexImportResult> importRegexScripts(String text) async => (await _ready).importRegexScripts(text);

  /// The edit as it is when called: copied before waiting for the engine, so
  /// a caller changing its map afterwards does not change what is saved.
  @override
  Future<TavernRegexScript> updateRegexScript(String regexId, Map<String, Object?> patch) =>
      Future<TavernRegexScript>.sync(() {
        final captured = jsonDecode(jsonEncode(patch)) as Map<String, Object?>;
        return _ready.then((tavern) => tavern.updateRegexScript(regexId, captured));
      });

  @override
  Future<TavernRegexScript> setRegexEnabled(String regexId, bool enabled) async =>
      (await _ready).setRegexEnabled(regexId, enabled);

  @override
  Future<void> deleteRegex(String regexId) async => (await _ready).deleteRegex(regexId);

  @override
  Future<String> exportRegex({String? regexId}) async => (await _ready).exportRegex(regexId: regexId);

  @override
  Future<List<TavernLorebookSummary>> listLorebooks() async => (await _ready).listLorebooks();

  @override
  Future<TavernLorebookImportResult> importLorebook(String text, {String? fileName}) async =>
      (await _ready).importLorebook(text, fileName: fileName);

  @override
  Future<Map<String, Object?>?> lorebook(String id) async => (await _ready).lorebook(id);

  @override
  Future<void> putLorebook(String id, Map<String, Object?> json) async => (await _ready).putLorebook(id, json);

  @override
  Future<String> exportLorebook(String id) async => (await _ready).exportLorebook(id);

  @override
  Future<void> deleteLorebook(String id) async => (await _ready).deleteLorebook(id);

  @override
  Future<void> bindLorebooks(
    List<String> ids, {
    WorldInfoSource source = WorldInfoSource.global,
    String? chatId,
    String? characterId,
    String? personaId,
  }) async =>
      (await _ready).bindLorebooks(ids, source: source, chatId: chatId, characterId: characterId, personaId: personaId);

  // Import reports (T22) -------------------------------------------------------

  @override
  Future<TavernImportReport?> readImportReport(TavernImportKind kind, String assetId) async =>
      (await _ready).readImportReport(kind, assetId);

  @override
  Future<TavernImportReport> recheckImport(TavernImportKind kind, String assetId) async =>
      (await _ready).recheckImport(kind, assetId);

  @override
  Future<Map<String, Object?>> readSettings({String? chatId}) async => (await _ready).readSettings(chatId: chatId);

  @override
  Future<void> setSettings(Map<String, Object?> patch, {String? chatId}) async =>
      (await _ready).setSettings(patch, chatId: chatId);

  @override
  Future<TavernDirectorSnapshot> readDirector(String chatId) async => (await _ready).readDirector(chatId);

  @override
  Stream<TavernDirectorSnapshot> watchDirector(String chatId) => _stream((t) => t.watchDirector(chatId));

  @override
  Future<TavernDirectorRun> runDirector(String chatId) async => (await _ready).runDirector(chatId);

  @override
  Future<List<TavernDirectorEvent>> readDirectorEvents(String chatId, {int limit = 50, String? beforeEventId}) async =>
      (await _ready).readDirectorEvents(chatId, limit: limit, beforeEventId: beforeEventId);

  /// Nothing to close when it never opened.
  @override
  Future<void> close() async {
    final Tavern tavern;
    try {
      tavern = await _ready;
    } on Object {
      return;
    }
    await tavern.close();
  }
}
