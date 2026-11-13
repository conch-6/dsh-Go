// ST continuation, display regex, injection ordering and world-info integration follow
// SillyTavern public/script.js, scripts/constants.js and scripts/world-info.js
// at 7e8663cd9c184a550b37238218bdd32c6efc68e9 (1.19.0, AGPL-3.0).
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'api.dart';
import 'backup.dart';
import 'director.dart';
import 'director/direct_tool.dart' as director_core;
import 'import_report.dart';
import 'inspection.dart';
import 'io/card_codec.dart' show TavernCard;
import 'io/chat_jsonl.dart';
import 'io/import_intake.dart';
import 'io/preset_codec.dart';
import 'io/regex_intake.dart';
import 'io/st_chat_document.dart';
import 'io/tavern_backup.dart' as backup_io;
import 'js_string.dart';
import 'llm/model_client.dart';
import 'llm/tool_calls.dart';
import 'lorebook_library.dart';
import 'macros/macro_engine.dart';
import 'persona.dart';
import 'preset_library.dart';
import 'prompt/character_fields.dart';
import 'prompt/preset.dart';
import 'prompt/prompt_assembler.dart';
import 'prompt/prompt_types.dart';
import 'regex/regex_engine.dart';
import 'regex/regex_worker.dart';
import 'regex_library.dart';
import 'state.dart';
import 'state/state_engine.dart' as state_core;
import 'story/story_engine.dart' as story_core;
import 'store/character_library.dart';
import 'store/chat_store.dart';
import 'store/persona_store.dart';
import 'store/regex_library.dart';
import 'worldinfo/world_info.dart';

part 'engine_state.dart';
part 'engine_director.dart';
part 'engine_director_watch.dart';
part 'engine_story.dart';
part 'engine_card_events.dart';
part 'engine_secrets.dart';

/// App convenience factory. [directory] is the actual tavern data directory,
/// normally `<app support>/tavern`. No extra path component is appended.
Future<Tavern> openTavern(String directory) => TavernEngine.openDirectory(Directory(directory));

/// Validates and restores a backup into a closed tavern directory. Open a new
/// engine after success. Invalid archives/versions never replace the target.
/// Like ordinary opening, the root must have one owner across processes.
Future<TavernBackupInfo> restoreTavernDirectory(String archivePath, String directory) async {
  final root = Directory(directory);
  final identity = await _directoryIdentity(root);
  if (!_reserveTavernRoot(identity)) throw StateError('The tavern directory overlaps an open or restoring root.');
  try {
    return await backup_io.restoreTavernBackup(
      File(archivePath),
      root,
      validateStaging: TavernEngine._validateBackupStaging,
    );
  } finally {
    _ownedTavernRoots.remove(identity);
  }
}

// Same-isolate ownership also prevents a page from reopening a root while a
// restore is between its two directory renames. It is not an OS file lock.
final _ownedTavernRoots = <String>{};

bool _reserveTavernRoot(String identity) {
  // Canonical directory URIs end in '/', so these checks include a directory
  // boundary. Replacing an ancestor would move a live descendant database.
  if (_ownedTavernRoots.any((owned) => identity.startsWith(owned) || owned.startsWith(identity))) return false;
  return _ownedTavernRoots.add(identity);
}

Future<String> _directoryIdentity(Directory directory) => backup_io.tavernDirectoryIdentity(directory);

/// A recording of the actual assembly, never a second macro evaluation.
class TavernInspection {
  const TavernInspection({
    required this.prompt,
    required this.worldInfo,
    required this.generationType,
    required this.at,
    this.preparedUiHits = const [],
    this.missingBooks = const [],
  });
  final PromptAssembly prompt;
  final WorldInfoResult worldInfo;
  final String generationType;
  final DateTime at;
  final List<WorldInfoHit> preparedUiHits;
  final List<Map<String, Object?>> missingBooks;

  Map<String, Object?> toJson() => _copy({
    'prompt': prompt.toJson(),
    'generationType': generationType,
    'at': at.toIso8601String(),
    'worldInfo': _worldInfoTrace(worldInfo, preparedUiHits: preparedUiHits, missingBooks: missingBooks),
  });
}

/// Owns the character files, chat database, settings, and active generations.
/// Only one engine should open a given app-support directory at a time.
class TavernEngine implements Tavern {
  TavernEngine._(
    this.directory,
    this._store,
    this._library,
    this._personas,
    this._document,
    this._config,
    this._modelClient,
    this._counter,
    this._clock,
    this._random,
    this._regexWorker,
    this._regexLibrary,
  ) {
    _globalVariables = _map(_document['globalVariables']);
    _storeSubscription = _store.changes.listen((chatId) {
      if (_closed) return;
      _paths.add(chatId);
      _directors.changed(chatId);
      if (!_turns.containsKey(chatId)) _notifyLists();
    });
    _personaSubscription = _personas.changes.listen((_) => _directors.changedAll());
  }

  static Future<TavernEngine> open(
    Directory appSupport, {
    TavernModelConfig? config,
    TavernModelClient? modelClient,
    PromptTokenCounter counter = const EstimatedTokenCounter(),
    DateTime Function()? clock,
    double Function()? random,
  }) => openDirectory(
    Directory('${appSupport.path}/tavern'),
    config: config,
    modelClient: modelClient,
    counter: counter,
    clock: clock,
    random: random,
  );

  /// Opens an explicit tavern root. Unlike [open], this does not append
  /// `tavern`; the caller chooses the complete data-directory path.
  static Future<TavernEngine> openDirectory(
    Directory directory, {
    TavernModelConfig? config,
    TavernModelClient? modelClient,
    PromptTokenCounter counter = const EstimatedTokenCounter(),
    DateTime Function()? clock,
    double Function()? random,
  }) async {
    final identity = await _directoryIdentity(directory);
    if (!_reserveTavernRoot(identity)) throw StateError('The tavern directory overlaps an open or restoring root.');
    try {
      await backup_io.recoverPendingTavernRestore(directory);
      await directory.create(recursive: true);
      final settingsFile = File('${directory.path}/settings.json');
      String? settingsText;
      try {
        settingsText = await settingsFile.readAsString();
      } on PathNotFoundException catch (error) {
        final code = error.osError?.errorCode;
        if (code != 2 && (!Platform.isWindows || code != 3)) {
          rethrow;
        }
        if (await FileSystemEntity.type(settingsFile.path) != FileSystemEntityType.notFound) {
          rethrow;
        }
      }
      final document = settingsText == null
          ? <String, Object?>{'version': 1, 'settings': <String, Object?>{}, 'globalVariables': <String, Object?>{}}
          : _decodeObject(settingsText, 'Tavern settings');
      if (document['version'] != 1) throw const FormatException('Unsupported Tavern settings version.');
      final now = clock ?? DateTime.now;
      final personas = await PersonaStore.open(directory);
      final regexWorker = RegexWorker();
      final regexLibrary = RegexLibrary(directory, regexWorker, clock: now);
      ChatStore? store;
      try {
        await regexLibrary.initialize();
        store = ChatStore.open('${directory.path}/tavern.sqlite3', clock: now);
        final result = TavernEngine._(
          directory,
          store,
          CharacterLibrary(directory, now: now),
          personas,
          document,
          config ?? TavernModelConfig(apiKey: () async => null),
          modelClient ?? TavernModelClient(),
          counter,
          now,
          random ?? Random.secure().nextDouble,
          regexWorker,
          regexLibrary,
        );
        result._directoryOwnerKey = identity;
        return result;
      } catch (_) {
        await regexWorker.close();
        await store?.close();
        await personas.close();
        rethrow;
      }
    } catch (_) {
      _ownedTavernRoots.remove(identity);
      rethrow;
    }
  }

  final Directory directory;
  late final String _directoryOwnerKey;
  final ChatStore _store;
  final CharacterLibrary _library;
  final PersonaStore _personas;
  final Map<String, Object?> _document;
  TavernModelConfig _config;
  final TavernModelClient _modelClient;
  final PromptTokenCounter _counter;
  final DateTime Function() _clock;
  final double Function() _random;
  final RegexWorker _regexWorker;
  final RegexLibrary _regexLibrary;
  // WI cannot queue behind obsolete 120ms display requests.
  final _keywordWorker = RegexWorker();
  late final _worldInfoEngine = WorldInfoEngine(worker: _keywordWorker);
  late final _chatCodec = ChatJsonlCodec(clock: _clock);
  final _presetCodec = const PresetCodec();
  late final Map<String, Object?> _globalVariables;
  late final StreamSubscription<String> _storeSubscription;
  late final StreamSubscription<void> _personaSubscription;
  final _charactersChanged = StreamController<void>.broadcast();
  final _chatsChanged = StreamController<void>.broadcast();
  final _paths = StreamController<String>.broadcast();
  final _turns = <String, _Turn>{};
  final _mutations = <String, Future<void>>{};
  final _deletingCharacters = <String>{};
  final _deletingPersonas = <String>{};
  final _deletingPresets = <String>{};
  final _operations = <Future<void>>{};
  final _inspections = <String, TavernInspection>{};
  // A null entry is a tombstone: never fall back to an older disk snapshot
  // after deleting the context of a more recent in-memory attempt.
  final _latestInspections = <String, TavernTurnInspection?>{};
  final _liveVariables = <String, ({String? leaf, Map<String, Object?> values})>{};
  final _books = <String, Map<String, Object?>>{};
  late final _directors = _DirectorCoordinator(this);
  final _bookSourceNames = <String, String>{};
  final _bookImportReports = <String, TavernImportReport>{};
  final _bookRevisions = <String, int>{};
  final _displayQueues = <(String, String?, bool), _DisplayQueue>{};
  Future<List<StoredCharacterSummary>>? _characterCache;
  final _characterDetails = <String, Future<StoredCharacter?>>{};
  static const _detailCacheCapacity = 8;
  Future<void> _libraryQueue = Future.value();
  Future<void> _personaQueue = Future.value();
  Future<void> _presetQueue = Future.value();
  Future<void> _fileQueue = Future.value();
  Future<void> _bookQueue = Future.value();
  Future<void>? _closeFuture;
  var _closing = false;
  var _closed = false;
  var _globalPresetUpdate = false;
  var _temporaryId = 0;
  var _capturingBackup = false;
  var _backupInProgress = false;
  Completer<void>? _backupCaptureDone;

  void _ensureOpen() {
    if (_closing || _closed) throw StateError('The tavern is closed.');
  }

  void _ensureAdmission() {
    _ensureOpen();
    if (_capturingBackup) throw const TavernModelException(TavernFailure.busy, 'backup_capture_in_progress');
  }

  Future<T> _operation<T>(FutureOr<T> Function() action) {
    _ensureAdmission();
    return _trackOperation(Future<T>.sync(action));
  }

  Future<T> _trackOperation<T>(Future<T> result) {
    final completed = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _operations.add(completed);
    unawaited(
      completed.then<void>((_) {
        _operations.remove(completed);
      }),
    );
    return result;
  }

  Future<T> _libraryOperation<T>(Future<T> Function() action) {
    final result = _libraryQueue.then((_) => action());
    _libraryQueue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  // Acquire this queue before chat barriers for bind/delete. Taking them in
  // the reverse order could leave a binder waiting behind a deletion that is
  // itself waiting for the binder's chat barrier.
  Future<T> _personaOperation<T>(Future<T> Function() action) {
    final result = _personaQueue.then((_) => action());
    _personaQueue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  // Preset operations take this queue before any chat mutation barrier.
  Future<T> _presetOperation<T>(FutureOr<T> Function() action) {
    final result = _presetQueue.then((_) => action());
    _presetQueue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<List<StoredCharacterSummary>> _characters() {
    final cached = _characterCache;
    if (cached != null) return cached;
    late final Future<List<StoredCharacterSummary>> result;
    result = Future<List<StoredCharacterSummary>>.sync(_library.list).then(
      (value) => value,
      onError: (Object error, StackTrace stack) {
        if (identical(_characterCache, result)) _characterCache = null;
        Error.throwWithStackTrace(error, stack);
      },
    );
    _characterCache = result;
    return result;
  }

  void _cacheCharacterDetail(String id, Future<StoredCharacter?> value) {
    _characterDetails.remove(id);
    _characterDetails[id] = value;
    if (_characterDetails.length > _detailCacheCapacity) _characterDetails.remove(_characterDetails.keys.first);
  }

  Future<StoredCharacter?> _record(String id) {
    if (!CharacterLibrary.isValidId(id)) return Future.value(null);
    final cached = _characterDetails.remove(id);
    if (cached != null) {
      _characterDetails[id] = cached;
      return cached;
    }
    late final Future<StoredCharacter?> result;
    result = Future<StoredCharacter?>.sync(() => _library.read(id)).then(
      (record) {
        if (record == null && identical(_characterDetails[id], result)) _characterDetails.remove(id);
        return record;
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_characterDetails[id], result)) _characterDetails.remove(id);
        Error.throwWithStackTrace(error, stack);
      },
    );
    _cacheCharacterDetail(id, result);
    return result;
  }

  List<TavernChatSummary> _chatSummaries({String? characterId}) => [
    for (final chat in _store.listChats(characterId: characterId))
      TavernChatSummary(
        id: chat.id,
        characterId: chat.characterId,
        title: chat.title,
        updatedAt: chat.updatedAt,
        lastText: chat.lastText == null ? null : _plainText(chat.lastText!),
        messageCount: chat.messageCount,
      ),
  ];

  Future<List<TavernCharacter>> _characterSummaries() async {
    final records = await _characters();
    if (_closed) return const [];
    final stats = _store.characterChatStats();
    final result = [
      for (final record in records)
        record.toCharacter(chatCount: stats[record.id]?.count ?? 0, lastChatAt: stats[record.id]?.lastAt),
    ];
    result.sort((a, b) {
      final chatOrder = (b.lastChatAt?.millisecondsSinceEpoch ?? -1).compareTo(
        a.lastChatAt?.millisecondsSinceEpoch ?? -1,
      );
      if (chatOrder != 0) return chatOrder;
      final importOrder = b.importedAt!.compareTo(a.importedAt!);
      return importOrder != 0 ? importOrder : a.id.compareTo(b.id);
    });
    return result;
  }

  void _notifyLists() {
    if (_closed || _closing) return;
    _charactersChanged.add(null);
    _chatsChanged.add(null);
  }

  @override
  Stream<List<TavernCharacter>> watchCharacters() {
    _ensureOpen();
    return _watch(_charactersChanged.stream, _characterSummaries);
  }

  @override
  Stream<List<TavernChatSummary>> watchChats({String? characterId}) {
    _ensureOpen();
    return _watch(_chatsChanged.stream, () => _chatSummaries(characterId: characterId));
  }

  @override
  Future<TavernCharacter?> character(String id) => _operation(
    () => _libraryOperation(() async {
      final record = await _record(id);
      if (record == null) return null;
      final stats = _store.characterChatStats()[id];
      return record.toCharacter(chatCount: stats?.count ?? 0, lastChatAt: stats?.lastAt);
    }),
  );

  @override
  Future<Map<String, Object?>?> characterFields(String characterId) =>
      _operation(() => _libraryOperation(() => _library.readFields(characterId)));

  @override
  Future<TavernCharacter> updateCharacterFields(String characterId, Map<String, Object?> fields) => _operation(() {
    if (_deletingCharacters.contains(characterId)) throw StateError('Character deletion is running.');
    // Only strings and string lists are accepted by the library. Snapshot the
    // lists now, before this edit waits behind another library operation.
    final patch = <String, Object?>{
      for (final entry in fields.entries)
        entry.key: entry.value is List<Object?> ? List<Object?>.of(entry.value! as List<Object?>) : entry.value,
    };
    return _libraryOperation(() async {
      final stored = await _library.updateFields(characterId, patch);
      _characterCache = null;
      _cacheCharacterDetail(characterId, Future.value(stored));
      _directors.characterChanged(characterId);
      _notifyLists();
      final stats = _store.characterChatStats()[characterId];
      return stored.toCharacter(chatCount: stats?.count ?? 0, lastChatAt: stats?.lastAt);
    });
  });

  @override
  Future<TavernCharacter> addCharacterBookEntry(String characterId, Map<String, Object?> entry) => _operation(() {
    final captured = _captureBookEntry(entry);
    return _editCharacterBook(characterId, () => _library.addBookEntry(characterId, captured));
  });

  @override
  Future<TavernCharacter> updateCharacterBookEntry(String characterId, int index, Map<String, Object?> fields) =>
      _operation(() {
        final captured = _captureBookEntry(fields);
        return _editCharacterBook(characterId, () => _library.updateBookEntry(characterId, index, captured));
      });

  @override
  Future<TavernCharacter> deleteCharacterBookEntry(String characterId, int index) =>
      _operation(() => _editCharacterBook(characterId, () => _library.deleteBookEntry(characterId, index)));

  Map<String, Object?> _captureBookEntry(Map<String, Object?> fields) {
    try {
      return jsonDecode(jsonEncode(fields)) as Map<String, Object?>;
    } on JsonUnsupportedObjectError {
      throw ArgumentError.value(fields, 'fields', 'Expected JSON entry fields');
    }
  }

  Future<TavernCharacter> _editCharacterBook(String characterId, Future<StoredCharacter> Function() save) {
    if (_deletingCharacters.contains(characterId)) {
      throw StateError('Character deletion is running.');
    }
    return _libraryOperation(() async {
      final stored = await save();
      _characterCache = null;
      _cacheCharacterDetail(characterId, Future.value(stored));
      _directors.characterChanged(characterId);
      _notifyLists();
      final stats = _store.characterChatStats()[characterId];
      return stored.toCharacter(chatCount: stats?.count ?? 0, lastChatAt: stats?.lastAt);
    });
  }

  @override
  Future<Map<String, Object?>> previewCharacterBook(String characterId, String text, {String? chatId, int seed = 0}) =>
      _operation(() async {
        final chat = chatId == null ? null : _store.chat(chatId);
        if (chat != null && chat.characterId != characterId) {
          throw ArgumentError.value(chatId, 'chatId', 'The chat belongs to another character.');
        }
        final leaf = chat?.currentLeafId;
        final metadata = chat == null ? <String, Object?>{} : _chatCodec.metadataForNode(_store, chat.id);
        final state = chat == null
            ? <String, Object?>{}
            : leaf == null
            ? _emptyChatState(metadata)
            : _stateAt(chat.id, leaf);
        final provenance =
            state['chatJsonlSourceFile'] ??
            (chat == null ? null : _map(_map(chat.metadata['dshgo'])['chatJsonl'])['rootFile']);
        final sourceFile = provenance is String ? provenance : null;
        final selection = _personas.resolve(personaId: chat?.personaId);
        final settings = _personaSettings(_effectiveSettings(chat, metadata), selection);
        final cached = chat == null ? null : _liveVariables[chat.id];
        final local = cached != null && cached.leaf == leaf
            ? _runtimeCopy(cached.values)
            : state.containsKey('variables')
            ? _map(state['variables'])
            : leaf != null && sourceFile != null
            ? <String, Object?>{}
            : _copy(chat?.variables ?? const {});
        final global = _runtimeCopy(_globalVariables);
        final history = chat == null ? <StoredNode>[] : _historyTo(chat.id, leaf);
        final siblingIndex = chat == null || text.isEmpty ? 0 : _store.children(chat.id, leaf).length;
        final config = _config;
        final at = _clock();
        final random = Random(seed).nextDouble;
        final identity = chat == null
            ? 'preview:$characterId'
            : _macroChatIdentity(chat, state, metadata, sourceFile, node: history.lastOrNull);
        // All mutable runtime inputs above were captured before the file read.
        // This query never owns a turn and never publishes its computed state.
        final record = await _record(characterId);
        if (record == null) {
          throw const TavernImportError('角色不存在。');
        }
        final data = _effectiveCard(record.card.data, settings);
        final rawPreset = _map(settings['preset']);
        final preset = ChatPreset({
          ...(rawPreset.isEmpty ? ChatPreset.stDefault().raw : rawPreset),
          'show_thoughts': config.thinking,
        });
        final environment = _MacroEnvironment(
          data,
          settings,
          local,
          global,
          history,
          config,
          at,
          random,
          identity,
          text,
          'normal',
          chatIdHash: _finiteNumber(metadata['chat_id_hash']),
          pickRerollSeed: metadata['pick_reroll_seed'],
          characterId: characterId,
          preset: preset,
        );
        if (text.isNotEmpty) {
          final regexed = environment.regex.apply(
            text,
            placement: RegexPlacement.userInput,
            expand: environment.regexExpand,
          );
          final input = environment.expand(regexed, const {});
          history.add(
            StoredNode(
              message: TavernMessage(
                nodeId: 'preview-user',
                parentId: leaf,
                role: TavernRole.user,
                speaker: environment.userName,
                text: input,
                at: at,
                siblingIndex: siblingIndex,
                siblingCount: siblingIndex + 1,
              ),
              depth: history.length + 1,
              extra: const {},
              original: const {},
            ),
          );
        }
        final prepared = prepareCharacterFields(data, persona: environment.persona, expand: environment.baseExpand);
        if (history.isNotEmpty) {
          history[0] = _nodeWithText(history.first, environment.expand(history.first.message.text, const {}));
        }
        final promptHistory = _preparePromptHistory(history, environment, continuing: false);
        final eligible = promptHistory.where((node) => !node.message.hidden && !_systemMessage(node)).toList();
        final injections = _configuredInjections(
          settings,
          prepared,
          data,
          userMessageCount: history.where((node) => node.message.role == TavernRole.user).length,
        );
        final scanInjections = <String>[];
        for (final injection in injections) {
          if (!injection.scan) {
            continue;
          }
          final content = environment.expand(injection.injection.fragment.content, const {});
          if (content.isNotEmpty) {
            scanInjections.add(content);
          }
        }
        final embedded = data['character_book'];
        final world = await _worldInfoEngine.evaluate(
          WorldInfoInput(
            books: [
              if (embedded is Map<String, Object?>)
                WorldInfoBook.fromJson(id: '$characterId:card', source: WorldInfoSource.character, json: embedded),
            ],
            messages: [for (final node in eligible) WorldInfoMessage(node.message.text, speaker: node.message.speaker)],
            maxContext: environment.maxContext - environment.maxResponse,
            tokenCount: _counter.countText,
            random: random,
            expand: (value) => environment.expand(value, const {}),
            settings: WorldInfoSettings.fromJson(_map(settings['worldInfo'])),
            scanInjections: scanInjections,
            personaDescription: prepared.persona,
            characterDescription: prepared['description'],
            characterPersonality: prepared['personality'],
            characterDepthPrompt: prepared['charDepthPrompt'],
            scenario: prepared['scenario'],
            creatorNotes: prepared['creator_notes'],
            characterName: _characterFilename(settings, characterId),
            characterTags: _characterTags(settings, characterId),
            timedWorldInfo: _map(state['timedWorldInfo']),
            decoratorState: _map(state['decoratorState']),
            assistantMessageCount: eligible.where((node) => node.message.role == TavernRole.character).length,
            greetingIndex: state['greetingIndex'] is int ? state['greetingIndex'] as int : null,
            userIconName: settings['userIconName'] as String?,
            // Evaluate normal effects on copies, then discard them. No complete
            // prompt was assembled, so contextAtCapacity deliberately stays null.
            availablePromptSections: _availableWorldSections(preset, 'normal'),
            postProcessContent: (entry, content, depth) => environment.regex.apply(
              content,
              placement: RegexPlacement.worldInfo,
              phase: RegexPhase.prompt,
              depth: depth,
              expand: environment.regexExpand,
            ),
          ),
        );
        return {
          'scope': 'character-book',
          'stage': 'world-info',
          'seed': seed,
          'chatId': chatId,
          'contextNodeId': leaf,
          ..._worldInfoTrace(world),
        };
      });

  @override
  Future<TavernCharacter> importCard(Uint8List bytes, {String? fileName}) => _operation(
    () => _libraryOperation(() async {
      var diagnostics = <TavernRegexDiagnostic>[];
      final stored = await _library.importCard(
        bytes,
        fileName: fileName,
        inspect: (card) async {
          diagnostics = await _checkCardRegex(card.data);
          return assessImport(
            kind: TavernImportKind.character,
            document: card.json,
            embeddedAssetPaths: card.assets.keys,
            regexDiagnostics: diagnostics,
            checkedAt: _clock().toUtc(),
          );
        },
      );
      _characterCache = null;
      _cacheCharacterDetail(stored.id, Future.value(stored));
      _notifyLists();
      return stored.toCharacter(regexDiagnostics: diagnostics);
    }),
  );

  @override
  Future<Uint8List> exportCard(String characterId, {TavernCardFormat format = TavernCardFormat.png}) =>
      _operation(() => _library.exportCard(characterId, format: format));

  @override
  Future<void> deleteCharacter(String characterId) {
    _ensureAdmission();
    if (!_deletingCharacters.add(characterId)) {
      return Future.error(StateError('Character deletion is already running.'));
    }
    return _operation(
      () => _libraryOperation(() async {
        try {
          final ids = _store.listChats(characterId: characterId).map((chat) => chat.id).toList();
          await Future.wait([for (final id in ids) _withMutation<void>(id, () {})]);
          await Future.wait([for (final id in ids) _directors.cancelChat(id)]);
          await _library.delete(characterId);
          _characterCache = null;
          unawaited(_characterDetails.remove(characterId));
          _store.deleteCharacterChats(characterId);
          for (final id in ids) {
            _inspections.remove(id);
            _latestInspections.remove(id);
            _liveVariables.remove(id);
          }
          _characterCache = null;
          _notifyLists();
        } finally {
          _deletingCharacters.remove(characterId);
          _notifyLists();
        }
      }),
    );
  }

  @override
  Stream<List<TavernPersona>> watchPersonas() {
    _ensureOpen();
    return _watch(_personas.changes, _personas.list);
  }

  @override
  Future<TavernPersona?> persona(String personaId) =>
      _operation(() => _personaOperation(() async => _personas.get(personaId)));

  @override
  Future<TavernPersona> createPersona({
    required String name,
    String description = '',
    String? avatarPath,
    int descriptionPosition = PersonaDescriptionPosition.inPrompt,
  }) => _operation(
    () => _personaOperation(
      () => _personas.create(
        name: name,
        description: description,
        avatarPath: avatarPath,
        descriptionPosition: descriptionPosition,
      ),
    ),
  );

  @override
  Future<TavernPersona> updatePersona(
    String personaId, {
    String? name,
    String? description,
    String? avatarPath,
    bool clearAvatar = false,
    int? descriptionPosition,
  }) => _operation(
    () => _personaOperation(
      () => _personas.update(
        personaId,
        name: name,
        description: description,
        avatarPath: avatarPath,
        clearAvatar: clearAvatar,
        descriptionPosition: descriptionPosition,
      ),
    ),
  );

  @override
  Future<PersonaSelection> personaSelection({String? chatId}) => _operation(
    () => _personaOperation(() async => chatId == null ? _personas.resolve() : _personas.forChat(_store, chatId)),
  );

  @override
  Future<void> setDefaultPersona(String? personaId) =>
      _operation(() => _personaOperation(() => _personas.setDefault(personaId)));

  @override
  Future<void> bindPersona(String chatId, String? personaId) => _operation(
    () => _personaOperation(() async {
      // Reject a missing profile before disturbing an otherwise valid turn.
      if (personaId != null && _personas.get(personaId) == null) throw StateError('Unknown persona: $personaId');
      if (_store.chat(chatId).personaId == personaId) return;
      await _withMutation(chatId, () => _personas.bindChat(_store, chatId, personaId));
    }),
  );

  @override
  Future<void> deletePersona(String personaId) => _operation(
    () => _personaOperation(() async {
      _deletingPersonas.add(personaId);
      try {
        final affected = <String>{};
        for (final chat in _store.listChatPersonaBindings()) {
          if (chat.personaId == personaId ||
              _personas.resolve(personaId: chat.personaId).persona?.id == personaId ||
              _turns[chat.id]?.personaSelection.persona?.id == personaId) {
            affected.add(chat.id);
          }
        }
        // Hold every affected chat gate until both profile and bindings have
        // been updated. The active turn may still use this profile even when
        // its chat has inherited a different default since that turn began.
        await _withMutations(affected, () async {
          await _personas.delete(personaId, chats: _store);
        });
      } finally {
        _deletingPersonas.remove(personaId);
      }
    }),
  );

  @override
  Future<String> createChat(String characterId, {int greeting = 0}) => _operation(
    () => _libraryOperation(() async {
      if (_deletingCharacters.contains(characterId)) throw StateError('Character deletion is running.');
      final record = await _record(characterId);
      if (record == null) throw const TavernImportError('角色不存在。');
      if (_deletingCharacters.contains(characterId)) throw StateError('Character deletion is running.');
      if (_globalPresetUpdate || _deletingPresets.contains(_resolvePreset().selection.effectivePresetId)) {
        throw StateError('Preset selection is changing.');
      }
      final data = record.card.data;
      final greetings = <String>[_string(data['first_mes']), ..._strings(data['alternate_greetings'])];
      RangeError.checkValidIndex(greeting, greetings, 'greeting');
      final selection = _personas.resolve();
      if (_deletingPersonas.contains(selection.persona?.id)) throw StateError('Persona deletion is running.');
      final settings = _personaSettings(_effectiveSettings(), selection);
      final variables = <String, Object?>{};
      final beforeGlobals = _jsonString(_globalVariables);
      late final String id;
      try {
        id = _store.transaction(() {
          final id = _store.createChat(characterId: characterId, title: record.card.name);
          final context = _MacroEnvironment(
            data,
            settings,
            variables,
            _globalVariables,
            [],
            _config,
            _clock(),
            _random,
            id,
            '',
            'normal',
            characterId: characterId,
          );
          final regexed = context.regex.apply(
            greetings[greeting],
            placement: RegexPlacement.aiOutput,
            expand: context.regexExpand,
          );
          final text = context.expand(regexed, const {}).replaceAll('\r', '');
          final state = <String, Object?>{
            'variables': _copy(variables),
            'timedWorldInfo': <String, Object?>{},
            'decoratorState': <String, Object?>{},
            'greetingIndex': greeting,
            'stChatId': id,
            'stChatIdHash': context.chatIdHash,
          };
          _initializeDshState(_stateDefinition(data), state, settings['stateEnabled'] != false);
          _store.append(
            id,
            parentId: null,
            role: TavernRole.character,
            speaker: record.card.promptName,
            text: text,
            state: state,
          );
          _store.updateChat(
            id,
            variables: _copy(variables),
            metadata: _runtimeMetadata(_store.chat(id).metadata, state),
          );
          return id;
        });
      } catch (createError, createStackTrace) {
        // SQL is rolled back, but preparation follows ST/T8 global-variable
        // semantics: preserve and save effects that happened before the error.
        try {
          if (beforeGlobals != _jsonString(_globalVariables)) await _saveDocument();
        } catch (saveError, saveStackTrace) {
          Error.throwWithStackTrace(
            _PreparationSaveFailure(createError, createStackTrace, saveError, saveStackTrace),
            saveStackTrace,
          );
        }
        Error.throwWithStackTrace(createError, createStackTrace);
      }
      _liveVariables[id] = (leaf: _store.chat(id).currentLeafId, values: _runtimeCopy(variables));
      if (beforeGlobals != _jsonString(_globalVariables)) await _saveDocument();
      _notifyLists();
      return id;
    }),
  );

  @override
  Future<TavernChatImportResult> importChats(
    String characterId,
    List<TavernChatFile> files, {
    Map<String, String> lorebookIds = const {},
  }) => _operation(() {
    final documents = [
      for (final file in List<TavernChatFile>.of(files)) StChatDocument.decode(file.fileName, file.bytes),
    ];
    final mapping = Map<String, String>.of(lorebookIds);
    for (final entry in mapping.entries) {
      if (entry.key.isEmpty) throw ArgumentError.value(entry.key, 'lorebookIds', 'ST names must not be empty.');
      _requireBookId(entry.value);
    }
    return _libraryOperation(() async {
      if (_deletingCharacters.contains(characterId)) throw StateError('Character deletion is running.');
      if (await _record(characterId) == null) throw const TavernImportError('角色不存在。');
      for (final id in mapping.values.toSet()) {
        if (await _readBook(id) == null) throw const TavernImportError('映射的世界书不存在。');
      }
      if (_deletingCharacters.contains(characterId)) throw StateError('Character deletion is running.');
      final extraNotices = <String>[];
      for (final document in documents) {
        final metadata = _map(document.header['chat_metadata']);
        final name = metadata['world_info'];
        if (name is String && name.isNotEmpty && !mapping.containsKey(name)) {
          extraNotices.add('${document.fileName}:${document.headerLineNumber}: 世界书“$name”没有本地映射；保留名称，暂不执行该绑定。');
        }
      }
      final imported = _store.transaction(() {
        final result = _chatCodec.importBatch(_store, characterId: characterId, documents: documents);
        if (mapping.isNotEmpty) {
          for (final chatId in result.chatIds) {
            _store.updateChat(chatId, settings: {'stLorebookIds': mapping});
          }
        }
        return result;
      });
      _notifyLists();
      return TavernChatImportResult(
        chatIds: imported.chatIds,
        chatsByFile: imported.chatsByFile,
        notices: [...imported.notices, ...extraNotices],
      );
    });
  });

  @override
  Future<List<TavernChatFile>> exportChat(String chatId, {String? fileName}) => _operation(
    () => List<TavernChatFile>.unmodifiable([
      for (final document in _chatCodec.exportChat(_store, chatId, fileName: fileName))
        TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ]),
  );

  @override
  Future<void> deleteChat(String chatId) => _operation(
    () => _withMutation(chatId, () async {
      await _directors.cancelChat(chatId);
      _store.deleteChat(chatId);
      _inspections.remove(chatId);
      _latestInspections.remove(chatId);
      _liveVariables.remove(chatId);
    }),
  );

  @override
  Future<List<TavernMessage>> path(String chatId, {int limit = 60, String? beforeNodeId}) => _operation(() {
    final messages = _store.path(chatId, limit: limit, beforeNodeId: beforeNodeId);
    final active = _turns[chatId];
    if (active == null || active.reply == null) return messages;
    return [
      for (final message in messages)
        if (message.nodeId == active.reply!.nodeId)
          _withReportedUsage(message, active.inspection.reportedUsage)
        else
          message,
    ];
  });

  @override
  Future<List<TavernTreeNode>> tree(String chatId) => _operation(() {
    final chat = _store.chat(chatId);
    final nodes = _store.allNodes(chatId);
    final byId = {for (final node in nodes) node.message.nodeId: node};
    final currentPath = <String>{};
    var id = chat.currentLeafId;
    while (id != null) {
      final node = byId[id];
      if (node == null || !currentPath.add(id)) {
        throw StateError('The selected message path is disconnected or cyclic.');
      }
      id = node.message.parentId;
    }
    final result = <TavernTreeNode>[];
    for (final node in nodes) {
      final message = node.message;
      final own = node.extra['dshgo'];
      final name = own is Map<String, Object?> ? own['branchName'] : null;
      result.add(
        TavernTreeNode(
          nodeId: message.nodeId,
          parentId: message.parentId,
          role: message.role,
          speaker: message.speaker,
          preview: String.fromCharCodes(message.text.runes.take(64)),
          at: message.at,
          isCurrentPath: currentPath.contains(message.nodeId),
          siblingIndex: message.siblingIndex,
          siblingCount: message.siblingCount,
          hidden: message.hidden,
          branchName: name is String ? name : null,
        ),
      );
    }
    return result;
  });

  @override
  Future<Map<String, Object?>> readVariables(String chatId) => _operation(() {
    final leaf = _store.chat(chatId).currentLeafId;
    if (leaf == null) {
      return <String, Object?>{};
    }
    return _runtimeCopy(_map(_stateAt(chatId, leaf)['variables']));
  });

  @override
  Future<TavernStateSnapshot> readState(String chatId) => _operation(() => _readSavedState(this, chatId));

  @override
  Future<TavernStateEditResult> setStateValue(String chatId, String path, Object? value, {String? expectedNodeId}) =>
      _editSavedState(this, chatId, path, value, expectedNodeId: expectedNodeId);

  @override
  Future<List<TavernAgentRun>> readAgentRuns(String chatId, {String? nodeId, int limit = 50}) => _operation(
    () => [
      for (final run in _store.agentRuns(chatId, nodeId: nodeId, limit: limit))
        TavernAgentRun(
          id: run.id,
          chatId: run.chatId,
          nodeId: run.nodeId,
          kind: run.kind,
          at: run.at,
          usage: run.usage,
          result: run.result,
        ),
    ],
  );

  @override
  Future<TavernDirectorSnapshot> readDirector(String chatId) => _operation(() => _directors.read(chatId));

  @override
  Stream<TavernDirectorSnapshot> watchDirector(String chatId) {
    _ensureOpen();
    return _directors.watch(chatId);
  }

  @override
  Future<TavernDirectorRun> runDirector(String chatId) => _operation(() => _directors.manual(chatId));

  @override
  Future<List<TavernDirectorEvent>> readDirectorEvents(String chatId, {int limit = 50, String? beforeEventId}) =>
      _operation(() => _directors.events(chatId, limit: limit, beforeEventId: beforeEventId));

  @override
  Stream<void> pathChanges(String chatId) {
    _ensureOpen();
    return _paths.stream.where((id) => id == chatId).map<void>((_) {});
  }

  List<TavernPresetSummary> _presetSummaries() => [
    for (final value in _store.listPresets())
      TavernPresetSummary(
        id: value.id,
        name: value.name,
        createdAt: value.createdAt,
        updatedAt: value.updatedAt,
        hasEnvelope: value.hasEnvelope,
      ),
  ];

  TavernPreset _presetView(StoredPreset value) => TavernPreset(
    id: value.id,
    name: value.name,
    sourceText: value.sourceText,
    raw: value.raw,
    envelope: value.envelope,
    createdAt: value.createdAt,
    updatedAt: value.updatedAt,
  );

  StoredPreset _requirePreset(String id) => _store.preset(id) ?? (throw StateError('Unknown preset: $id'));

  @override
  Future<List<TavernPresetSummary>> listPresets() => _operation(_presetSummaries);

  @override
  Stream<List<TavernPresetSummary>> watchPresets() {
    _ensureOpen();
    return _watch(_store.presetChanges, _presetSummaries);
  }

  @override
  Future<TavernPreset?> preset(String presetId) => _operation(() {
    final value = _store.preset(presetId);
    return value == null ? null : _presetView(value);
  });

  @override
  Future<TavernPresetImportResult> importPreset(String text, {String? fileName}) => _operation(() async {
    final decoded = _presetCodec.decode(text, fileName: fileName);
    final diagnostics = await inspectRegexScripts(_map(decoded.raw['extensions'])['regex_scripts'], _regexWorker);
    final report = assessImport(
      kind: TavernImportKind.preset,
      document: decoded.raw,
      envelope: decoded.envelope,
      regexDiagnostics: diagnostics,
      presetIssues: decoded.issues,
      checkedAt: _clock().toUtc(),
    );
    return _presetOperation(() {
      final value = _store.createPreset(
        name: decoded.name,
        sourceText: text,
        raw: decoded.raw,
        envelope: decoded.envelope,
        importReport: report,
      );
      return TavernPresetImportResult(_presetView(value), decoded.issues, regexDiagnostics: diagnostics);
    });
  });

  TavernPresetImportResult _savePresetEdit(StoredPreset original, Map<String, Object?> raw, {String? name}) {
    final envelope = original.envelope;
    if (name != null && envelope != null) envelope['metadata'] = {..._map(envelope['metadata']), 'name': name};
    final decoded = _presetCodec.validate(raw, envelope: envelope);
    final value = _store.updatePreset(
      original.id,
      name: name ?? original.name,
      raw: decoded.raw,
      envelope: decoded.envelope,
    );
    return TavernPresetImportResult(_presetView(value), decoded.issues);
  }

  @override
  Future<TavernPresetImportResult> updatePreset(String presetId, Map<String, Object?> patch, {String? name}) =>
      _operation(() {
        final captured = _copy(patch);
        return _presetOperation(() {
          final original = _requirePreset(presetId);
          final raw = _merge(original.raw, captured);
          _guardPresetCarrier(original.raw, raw);
          return _savePresetEdit(original, raw, name: name);
        });
      });

  @override
  Future<String> exportPreset(String presetId) => _operation(() {
    final value = _requirePreset(presetId);
    return _presetCodec.encode(value.raw, envelope: value.envelope);
  });

  Map<String, Object?> _knownPrompt(Map<String, Object?> raw, String identifier) {
    final definitions = ChatPreset(raw).settings['prompts']! as List<Object?>;
    for (final value in definitions.whereType<Map<String, Object?>>()) {
      if (value['identifier'] == identifier) return _copy(value);
    }
    throw ArgumentError.value(identifier, 'identifier', 'Unknown prompt');
  }

  void _guardPresetCarrier(Map<String, Object?> previous, Map<String, Object?> next) {
    final before = _map(_map(previous['extensions'])['dshgo']);
    final after = _map(_map(next['extensions'])['dshgo']);
    const key = 'presetEnvelope';
    if (before.containsKey(key) != after.containsKey(key) || !_presetJsonEquals(before[key], after[key])) {
      throw ArgumentError(
        'extensions.dshgo.presetEnvelope is an export-owned carrier; edit the preset fields instead.',
      );
    }
  }

  bool _presetJsonEquals(Object? left, Object? right) {
    if (left is Map<String, Object?> && right is Map<String, Object?>) {
      return left.length == right.length &&
          left.entries.every(
            (entry) => right.containsKey(entry.key) && _presetJsonEquals(entry.value, right[entry.key]),
          );
    }
    if (left is List<Object?> && right is List<Object?>) {
      if (left.length != right.length) return false;
      for (var i = 0; i < left.length; i++) {
        if (!_presetJsonEquals(left[i], right[i])) return false;
      }
      return true;
    }
    return left == right;
  }

  Map<String, Object?> _editableOrder(Map<String, Object?> raw) {
    final groups = raw['prompt_order'] is List<Object?>
        ? List<Object?>.of(raw['prompt_order']! as List<Object?>)
        : <Object?>[];
    raw['prompt_order'] = groups;
    for (final group in groups.whereType<Map<String, Object?>>()) {
      if (presetString(group['character_id']) == '100001') return group;
    }
    final effective = ChatPreset(raw).settings['prompt_order']! as List<Object?>;
    final group = _copy(
      effective.whereType<Map<String, Object?>>().firstWhere(
        (entry) => presetString(entry['character_id']) == '100001',
      ),
    );
    group['character_id'] = 100001;
    groups.add(group);
    return group;
  }

  @override
  Future<TavernPresetImportResult> updatePresetPrompt(String presetId, String identifier, Map<String, Object?> patch) =>
      _operation(() {
        final captured = _copy(patch);
        if (captured.containsKey('identifier') && captured['identifier'] != identifier) {
          throw ArgumentError('A prompt identifier is stable; replace prompts and order together to rename it.');
        }
        return _presetOperation(() {
          final original = _requirePreset(presetId);
          final raw = original.raw;
          final inherited = _knownPrompt(raw, identifier);
          final definitions = raw['prompts'] is List<Object?>
              ? List<Object?>.of(raw['prompts']! as List<Object?>)
              : <Object?>[];
          final index = definitions.indexWhere(
            (value) => value is Map<String, Object?> && value['identifier'] == identifier,
          );
          final previous = index < 0 ? inherited : definitions[index]! as Map<String, Object?>;
          final updated = _merge(previous, captured);
          if (index < 0) {
            definitions.add(updated);
          } else {
            definitions[index] = updated;
          }
          raw['prompts'] = definitions;
          if (captured.containsKey('content') && const ['main', 'nsfw', 'jailbreak'].contains(identifier)) {
            raw.remove('${identifier}_prompt');
          }
          return _savePresetEdit(original, raw);
        });
      });

  @override
  Future<TavernPresetImportResult> setPresetOrder(String presetId, List<String> identifiers) => _operation(() {
    final captured = List<String>.of(identifiers);
    if (captured.toSet().length != captured.length) throw ArgumentError('Prompt order identifiers must be unique.');
    return _presetOperation(() {
      final original = _requirePreset(presetId);
      final raw = original.raw;
      for (final id in captured) {
        _knownPrompt(raw, id);
      }
      final group = _editableOrder(raw);
      final old = group['order'] is List<Object?> ? group['order']! as List<Object?> : const <Object?>[];
      group['order'] = [
        for (final id in captured)
          {
            ...?old.whereType<Map<String, Object?>>().where((entry) => entry['identifier'] == id).firstOrNull,
            'identifier': id,
            if (!old.whereType<Map<String, Object?>>().any((entry) => entry['identifier'] == id)) 'enabled': true,
          },
      ];
      return _savePresetEdit(original, raw);
    });
  });

  @override
  Future<TavernPresetImportResult> setPresetPromptEnabled(String presetId, String identifier, bool enabled) =>
      _operation(
        () => _presetOperation(() {
          final original = _requirePreset(presetId);
          final raw = original.raw;
          _knownPrompt(raw, identifier);
          final group = _editableOrder(raw);
          final order = group['order'] is List<Object?>
              ? List<Object?>.of(group['order']! as List<Object?>)
              : <Object?>[];
          final index = order.indexWhere((entry) => entry is Map<String, Object?> && entry['identifier'] == identifier);
          if (index < 0) {
            order.add({'identifier': identifier, 'enabled': enabled});
          } else {
            order[index] = {...order[index]! as Map<String, Object?>, 'enabled': enabled};
          }
          group['order'] = order;
          return _savePresetEdit(original, raw);
        }),
      );

  ({StoredPreset? preset, TavernPresetSelection selection}) _resolvePreset([StoredChat? chat]) {
    final bound = chat?.presetId;
    final defaultId = _store.defaultPresetId;
    final missing = <String>[];
    ({StoredPreset? preset, TavernPresetSelection selection}) result(
      PresetSelectionSource source, [
      StoredPreset? value,
    ]) => (
      preset: value,
      selection: TavernPresetSelection(
        source: source,
        boundPresetId: bound,
        defaultPresetId: defaultId,
        effectivePresetId: value?.id,
        missingPresetIds: List<String>.unmodifiable(missing),
      ),
    );
    if (bound != null) {
      final value = _store.preset(bound);
      if (value != null) return result(PresetSelectionSource.chat, value);
      missing.add(bound);
    }
    if (chat != null && chat.settings.containsKey('preset')) return result(PresetSelectionSource.chatInline);
    if (defaultId != null) {
      final value = _store.preset(defaultId);
      if (value != null) return result(PresetSelectionSource.globalDefault, value);
      missing.add(defaultId);
    }
    if (_map(_document['settings']).containsKey('preset')) return result(PresetSelectionSource.globalInline);
    return result(PresetSelectionSource.stDefault);
  }

  @override
  Future<TavernPresetSelection> presetSelection({String? chatId}) =>
      _operation(() => _resolvePreset(chatId == null ? null : _store.chat(chatId)).selection);

  @override
  Future<void> setDefaultPreset(String? presetId) =>
      _operation(() => _presetOperation(() => _store.setDefaultPreset(presetId)));

  @override
  Future<void> bindPreset(String chatId, String? presetId) => _operation(
    () => _presetOperation(() async {
      if (presetId != null) _requirePreset(presetId);
      final chat = _store.chat(chatId);
      if (chat.presetId == presetId && !chat.settings.containsKey('preset')) return;
      await _withMutation(
        chatId,
        () => _store.transaction(() {
          final settings = _store.chat(chatId).settings;
          settings.remove('preset');
          _store.updateChat(chatId, settings: settings);
          _store.bindPreset(chatId, presetId);
        }),
      );
    }),
  );

  @override
  Future<void> deletePreset(String presetId) => _operation(
    () => _presetOperation(() async {
      _deletingPresets.add(presetId);
      try {
        final affected = <String>{};
        for (final summary in _store.listChats()) {
          final chat = _store.chat(summary.id);
          if (chat.presetId == presetId ||
              _resolvePreset(chat).selection.effectivePresetId == presetId ||
              _turns[chat.id]?.presetId == presetId) {
            affected.add(chat.id);
          }
        }
        await _withMutations(affected, () {
          _store.deletePreset(presetId);
        });
      } finally {
        _deletingPresets.remove(presetId);
      }
    }),
  );

  @override
  void configure(TavernModelConfig config) {
    _ensureOpen();
    _config = config;
  }

  /// Settings are JSON data. Per-chat documents overlay global settings.
  /// Unknown fields survive updates and reopening. Model credentials are never
  /// read from this document; use [configure] and its key callback.
  Map<String, Object?> settings({String? chatId}) {
    _ensureOpen();
    return _effectiveSettings(chatId == null ? null : _store.chat(chatId));
  }

  @override
  Future<Map<String, Object?>> readSettings({String? chatId}) => _operation(() => settings(chatId: chatId));

  Map<String, Object?> variables(String chatId) {
    _ensureOpen();
    return _runtimeCopy(_liveVariables[chatId]?.values ?? _store.chat(chatId).variables);
  }

  Map<String, Object?> get globalVariables {
    _ensureOpen();
    return _runtimeCopy(_globalVariables);
  }

  @override
  Future<void> setSettings(Map<String, Object?> patch, {String? chatId}) => _operation(() {
    final captured = _copy(patch);
    return _presetOperation(() => _setSettingsCaptured(captured, chatId: chatId));
  });

  Future<void> setPreset(ChatPreset preset, {String? chatId}) => _operation(() {
    final captured = preset.raw;
    return _presetOperation(() => _setSettingsCaptured({'preset': captured}, chatId: chatId, replacePreset: true));
  });

  Map<String, Object?> _mergeSettingsPatch(
    Map<String, Object?> previous,
    Map<String, Object?> patch, {
    String? scopePresetId,
    bool replacePreset = false,
  }) {
    final result = _merge(previous, patch);
    if (!patch.containsKey('preset')) return result;
    final value = patch['preset'];
    if (value is Map<String, Object?> && !replacePreset) {
      // An inherited global/default record is never the chat scope's base.
      final selected = scopePresetId == null ? null : _store.preset(scopePresetId);
      final raw = _merge(selected?.raw ?? _map(previous['preset']), value);
      if (selected?.envelope != null) _guardPresetCarrier(selected!.raw, raw);
      result['preset'] = raw;
    } else {
      result['preset'] = value;
    }
    return result;
  }

  void _selectLegacyPreset(Object? value, {String? chatId, Map<String, Object?>? envelope, String? inheritedName}) {
    String? id;
    if (value is Map<String, Object?>) {
      final suppliedName = value['name'];
      final name =
          inheritedName ??
          (suppliedName is String && suppliedName.trim().isNotEmpty
              ? suppliedName
              : (chatId == null ? '默认预设' : '对话预设'));
      if (envelope != null) envelope['preset'] = {..._map(envelope['preset']), 'data': _copy(value)};
      id = _store.createPreset(name: name, sourceText: jsonEncode(value), raw: value, envelope: envelope).id;
    }
    if (chatId == null) {
      _store.setDefaultPreset(id);
    } else {
      _store.bindPreset(chatId, id);
    }
  }

  Future<void> _setSettingsCaptured(Map<String, Object?> patch, {String? chatId, bool replacePreset = false}) async {
    try {
      if (chatId == null) {
        final hasPreset = patch.containsKey('preset');
        _globalPresetUpdate = hasPreset;
        try {
          final selectedId = _store.defaultPresetId;
          final inherited = !replacePreset && patch['preset'] is Map<String, Object?> && selectedId != null
              ? _store.preset(selectedId)
              : null;
          final settings = _mergeSettingsPatch(
            _map(_document['settings']),
            patch,
            scopePresetId: selectedId,
            replacePreset: replacePreset,
          );
          // This legacy mixed API has no transaction spanning a file and SQL.
          // Keep its established in-memory/file behavior, then commit selection.
          _document['settings'] = settings;
          await _saveDocument();
          if (hasPreset) {
            _store.transaction(
              () => _selectLegacyPreset(
                settings['preset'],
                envelope: inherited?.envelope,
                inheritedName: inherited?.name,
              ),
            );
          }
        } finally {
          _globalPresetUpdate = false;
        }
      } else {
        await _withMutation(
          chatId,
          () => _store.transaction(() {
            final chat = _store.chat(chatId);
            final inherited = !replacePreset && patch['preset'] is Map<String, Object?> && chat.presetId != null
                ? _store.preset(chat.presetId!)
                : null;
            final settings = _mergeSettingsPatch(
              chat.settings,
              patch,
              scopePresetId: chat.presetId,
              replacePreset: replacePreset,
            );
            _store.updateChat(chatId, settings: settings);
            if (patch.containsKey('preset')) {
              _selectLegacyPreset(
                settings['preset'],
                chatId: chatId,
                envelope: inherited?.envelope,
                inheritedName: inherited?.name,
              );
            }
          }),
        );
      }
    } catch (error, stack) {
      // Global legacy settings can already be effective in memory even when
      // their file or subsequent preset SQL fails. Honor that actual switch,
      // while preserving the caller's original storage failure.
      try {
        await _directors.settingsChanged(chatId);
      } catch (_) {
        // A second cleanup failure must not replace the original exception.
      }
      Error.throwWithStackTrace(error, stack);
    }
    await _directors.settingsChanged(chatId);
  }

  Future<void> setGlobalVariables(Map<String, Object?> variables) => _operation(() async {
    final copy = _copy(variables);
    _globalVariables
      ..clear()
      ..addAll(copy);
    await _saveDocument();
  });

  /// Reads the most recent real request. This has no variable/random effects.
  TavernInspection? inspect(String chatId) {
    _ensureOpen();
    return _inspections[chatId];
  }

  @override
  Future<TavernTurnInspection?> inspectTurn(String chatId, {String? nodeId}) => _operation(() {
    StoredChat chat;
    try {
      chat = _store.chat(chatId);
    } on StateError {
      return null;
    }
    if (nodeId != null) {
      final active = _turns[chatId]?.inspection;
      if (active != null && active.nodeId == nodeId && _inspectionAnchorExists(active)) return active;
      return _nodeInspection(chatId, nodeId);
    }
    if (_latestInspections.containsKey(chatId)) {
      final value = _latestInspections[chatId];
      if (value != null && !_inspectionAnchorExists(value)) _latestInspections[chatId] = null;
      return _latestInspections[chatId];
    }
    final value = _storedLatestInspection(chat);
    return value != null && _inspectionAnchorExists(value) ? value : null;
  });

  @override
  Future<TavernDisplayResult> displayText(
    String chatId, {
    String? nodeId,
    String? text,
    TavernRole? role,
    String? speaker,
    num? depth,
    bool reasoning = false,
  }) => _operation(() {
    _store.chat(chatId);
    if (nodeId == null && text == null) throw ArgumentError('Supply a stored node or original text.');
    if (depth != null && (!depth.isFinite || depth < 0)) throw ArgumentError.value(depth, 'depth');
    final node = nodeId == null ? null : _store.node(chatId, nodeId);
    final raw = text ?? (reasoning ? node!.message.reasoning ?? '' : node!.message.text);
    final displayRole = role ?? node?.message.role ?? TavernRole.character;
    final displaySpeaker =
        speaker ?? node?.message.speaker ?? (displayRole == TavernRole.system ? 'SillyTavern System' : null);
    final key = (chatId, nodeId, reasoning);
    final queue = _displayQueues.putIfAbsent(key, _DisplayQueue.new);
    final job = _DisplayJob(
      ++queue.version,
      chatId,
      nodeId,
      raw,
      displayRole,
      depth,
      reasoning,
      displaySpeaker,
      (role == TavernRole.system || (node != null && (node.message.hidden || _systemMessage(node)))) &&
          displaySpeaker == 'SillyTavern System',
    );
    // Advance before replacing pending work, so an already active job also
    // becomes stale at its next rule/await boundary.
    final previous = queue.pending;
    if (previous != null) previous.result.complete(TavernDisplayResult(text: previous.text, superseded: true));
    queue.pending = job;
    if (!queue.running) unawaited(_drainDisplay(key, queue));
    return job.result.future;
  });

  Future<void> _drainDisplay((String, String?, bool) key, _DisplayQueue queue) async {
    queue.running = true;
    try {
      while (queue.pending != null) {
        final job = queue.pending!;
        queue.pending = null;
        bool current() => !_closing && !_closed && queue.version == job.version;
        try {
          final result = current()
              ? await _display(job, current)
              : TavernDisplayResult(text: job.text, superseded: true);
          job.result.complete(
            TavernDisplayResult(
              text: result.text,
              warnings: result.warnings,
              replacements: result.replacements,
              superseded: result.superseded || !current(),
            ),
          );
        } catch (error, stack) {
          if (current()) {
            job.result.completeError(error, stack);
          } else {
            job.result.complete(TavernDisplayResult(text: job.text, superseded: true));
          }
        }
      }
    } finally {
      queue.running = false;
      if (identical(_displayQueues[key], queue)) _displayQueues.remove(key);
    }
  }

  Future<TavernDisplayResult> _display(_DisplayJob job, bool Function() current) async {
    // Fixed ST messageFormatting first reclassifies hidden/comment messages
    // as displayable; only is_system with its actual system speaker bypasses.
    if (job.isSystem) return TavernDisplayResult(text: job.text);
    final chat = _store.chat(job.chatId);
    final path = _historyTo(job.chatId, chat.currentLeafId);
    final targetIndex = job.nodeId == null ? -1 : path.indexWhere((node) => node.message.nodeId == job.nodeId);
    final history = job.nodeId != null && targetIndex < 0 ? _historyTo(job.chatId, job.nodeId) : path;
    final leaf = history.lastOrNull?.message.nodeId;
    final state = _stateAt(job.chatId, leaf);
    final metadata = _chatCodec.metadataForNode(_store, job.chatId, nodeId: leaf);
    final live = _liveVariables[job.chatId];
    final active = _turns[job.chatId];
    final onCurrentPath = job.nodeId == null || targetIndex >= 0;
    final activeVariables = onCurrentPath && active?.environment != null ? active!.variables : null;
    final local = _runtimeCopy(
      activeVariables ??
          (onCurrentPath && live != null && live.leaf == leaf
              ? live.values
              : leaf == null
              ? chat.variables
              : _map(state['variables'])),
    );
    final global = _runtimeCopy(_globalVariables);
    final settings = _personaSettings(_effectiveSettings(chat, metadata), _personas.resolve(personaId: chat.personaId));
    final config = _config;
    final now = _clock();
    final record = await _record(chat.characterId);
    if (!current()) return TavernDisplayResult(text: job.text, superseded: true);
    if (record == null) throw const TavernImportError('角色不存在。');
    final contextTarget = job.nodeId ?? active?.reply?.nodeId;
    if (!job.reasoning && contextTarget != null) {
      final index = history.indexWhere((node) => node.message.nodeId == contextTarget);
      if (index >= 0) history[index] = _nodeWithText(history[index], job.text);
    }
    final random = Random(_displaySeed('${job.chatId}\u0000${job.nodeId ?? ''}\u0000${job.reasoning}'));
    final environment = _MacroEnvironment(
      _effectiveCard(record.card.data, settings),
      settings,
      local,
      global,
      history,
      config,
      now,
      random.nextDouble,
      _macroChatIdentity(chat, state, metadata, state['chatJsonlSourceFile'] as String?, node: history.lastOrNull),
      '',
      active?.generationType ?? 'normal',
      chatIdHash: _finiteNumber(metadata['chat_id_hash']),
      pickRerollSeed: metadata['pick_reroll_seed'],
      characterId: chat.characterId,
    );
    final placement = job.reasoning
        ? RegexPlacement.reasoning
        : switch (job.role) {
            TavernRole.user => RegexPlacement.userInput,
            TavernRole.narrator => RegexPlacement.slashCommand,
            _ => RegexPlacement.aiOutput,
          };
    num? depth = job.depth;
    if (depth == null && job.nodeId != null) {
      final usable = history.where((node) => !node.message.hidden && !_systemMessage(node)).toList();
      final index = usable.indexWhere((node) => node.message.nodeId == job.nodeId);
      if (index >= 0) depth = usable.length - index - 1;
    }
    final rendered = await environment.regex.applyDisplay(
      job.text,
      placement: placement,
      worker: _regexWorker,
      depth: depth,
      characterOverride: job.characterOverride ?? (job.role == TavernRole.user ? environment.userName : null),
      expand: environment.regexExpand,
      isCancelled: () => !current(),
    );
    return TavernDisplayResult(
      text: rendered.text,
      warnings: rendered.warnings,
      replacements: rendered.replacements,
      superseded: rendered.cancelled || !current(),
    );
  }

  StoredNode? _inspectionNode(String chatId, String nodeId) {
    try {
      return _store.node(chatId, nodeId);
    } on StateError {
      return null;
    }
  }

  TavernTurnInspection? _nodeInspection(String chatId, String nodeId) {
    final node = _inspectionNode(chatId, nodeId);
    final json = node == null ? null : _map(node.extra['dshgo'])['inspection'];
    if (json is! Map<String, Object?>) return null;
    final value = TavernTurnInspection.fromJson(json);
    return value.chatId == chatId && value.nodeId == nodeId ? value : null;
  }

  TavernTurnInspection? _storedLatestInspection(StoredChat chat) {
    final latest = _map(_map(chat.metadata['dshgo'])['latestInspection']);
    final nodeId = latest['nodeId'];
    if (nodeId is String) return _nodeInspection(chat.id, nodeId);
    final json = latest['snapshot'];
    if (json is! Map<String, Object?>) return null;
    final value = TavernTurnInspection.fromJson(json);
    return value.chatId == chat.id && value.nodeId == null ? value : null;
  }

  bool _inspectionAnchorExists(TavernTurnInspection value) {
    final anchor = value.nodeId ?? value.contextNodeId;
    return anchor == null || _inspectionNode(value.chatId, anchor) != null;
  }

  void _setInspection(_Turn turn, TavernTurnInspection value) {
    turn.inspection = value;
    _latestInspections[turn.chat.id] = value;
  }

  Map<String, Object?> _inspectionExtra(Map<String, Object?> extra, TavernTurnInspection value) => {
    ...extra,
    'dshgo': {..._map(extra['dshgo']), 'inspection': value.toJson()},
  };

  Map<String, Object?> _latestInspectionMetadata(Map<String, Object?> metadata, TavernTurnInspection? value) {
    final own = _map(metadata['dshgo']);
    if (value == null) {
      own.remove('latestInspection');
    } else {
      own['latestInspection'] = value.nodeId == null ? {'snapshot': value.toJson()} : {'nodeId': value.nodeId};
    }
    return {...metadata, 'dshgo': own};
  }

  void _writeLatestInspection(String chatId, TavernTurnInspection? value) {
    _store.updateChat(chatId, metadata: _latestInspectionMetadata(_store.chat(chatId).metadata, value));
  }

  // The caller owns the transaction, so node evidence and the latest pointer
  // become visible together. Always merge with the current stored JSON.
  void _writeInspection(TavernTurnInspection value) {
    final nodeId = value.nodeId;
    if (nodeId != null) {
      final node = _store.node(value.chatId, nodeId);
      _store.updateMessage(value.chatId, nodeId, extra: _inspectionExtra(node.extra, value));
    }
    _writeLatestInspection(value.chatId, value);
  }

  void _captureAssembly(_Turn turn, PromptAssembly assembly) {
    try {
      _setInspection(turn, turn.inspection.copyWith(prompt: assembly, status: TavernInspectionStatus.ready));
    } on FormatException {
      // An internal recording error is not a malformed character card.
      throw StateError('Invalid assembled inspection data.');
    }
  }

  @override
  Future<TavernImportReport?> readImportReport(TavernImportKind kind, String assetId) => _operation(() async {
    switch (kind) {
      case TavernImportKind.character:
        return _libraryOperation(() => _library.readImportReport(assetId));
      case TavernImportKind.preset:
        return _presetOperation(() {
          final record = _store.preset(assetId);
          if (record == null) return null;
          return _currentImportReport(kind, record.importReport, record.raw, envelope: record.envelope);
        });
      case TavernImportKind.lorebook:
        return _bookOperation(() async {
          final raw = await _readBookNow(assetId);
          if (raw == null) return null;
          return _currentImportReport(kind, _bookImportReports[assetId], raw);
        });
      case TavernImportKind.regex:
        return _regexLibrary.readImportReport(assetId);
    }
  });

  @override
  Future<TavernImportReport> recheckImport(TavernImportKind kind, String assetId) => _operation(() async {
    switch (kind) {
      case TavernImportKind.character:
        return _libraryOperation(() => _library.recheckImport(assetId, _inspectCardReport));
      case TavernImportKind.preset:
        return _presetOperation(() async {
          final record = _requirePreset(assetId);
          final raw = record.raw;
          final envelope = record.envelope;
          List<TavernPresetIssue> issues;
          try {
            issues = _presetCodec.validate(raw, envelope: envelope).issues;
          } on TavernPresetImportError catch (error) {
            // Legacy permissive settings can contain values rejected by the
            // modern importer. Inspection must not normalize their live data.
            issues = error.issues;
          }
          final diagnostics = await inspectRegexScripts(_map(raw['extensions'])['regex_scripts'], _regexWorker);
          final report = assessImport(
            kind: kind,
            document: raw,
            envelope: envelope,
            regexDiagnostics: diagnostics,
            presetIssues: issues,
            checkedAt: _clock().toUtc(),
          );
          _store.savePresetImportReport(assetId, report);
          return report;
        });
      case TavernImportKind.lorebook:
        return _bookOperation(() async {
          final raw = await _readBookNow(assetId);
          if (raw == null) throw const TavernImportError('世界书不存在。');
          final book = WorldInfoBook.fromJson(id: assetId, source: WorldInfoSource.global, json: raw);
          final diagnostics = await _checkWorldBookRegex(book);
          final report = assessImport(
            kind: kind,
            document: raw,
            regexDiagnostics: diagnostics,
            checkedAt: _clock().toUtc(),
          );
          await _writeBookNow(assetId, raw, importReport: report);
          return report;
        });
      case TavernImportKind.regex:
        return _regexLibrary.recheckImport(assetId);
    }
  });

  Future<TavernImportReport> _inspectCardReport(TavernCard card) async {
    final diagnostics = await _checkCardRegex(card.data);
    return assessImport(
      kind: TavernImportKind.character,
      document: card.json,
      embeddedAssetPaths: card.assets.keys,
      regexDiagnostics: diagnostics,
      checkedAt: _clock().toUtc(),
    );
  }

  TavernImportReport? _currentImportReport(
    TavernImportKind kind,
    TavernImportReport? report,
    Map<String, Object?> raw, {
    Map<String, Object?>? envelope,
  }) {
    if (report == null) return null;
    if (report.kind != kind) throw const FormatException('Import report does not match its asset kind.');
    return report.withStale(report.fingerprint != importFingerprint(kind, raw, envelope: envelope));
  }

  @override
  Future<List<TavernRegexScript>> listRegexScripts() => _operation(() => _regexLibrary.scripts);
  @override
  Future<TavernRegexImportResult> importRegexScripts(String text) =>
      _operation(() => _regexLibrary.importScripts(text));
  @override
  Future<TavernRegexScript> updateRegexScript(String regexId, Map<String, Object?> patch) =>
      _operation(() => _regexLibrary.updateScript(regexId, patch));
  @override
  Future<TavernRegexScript> setRegexEnabled(String regexId, bool enabled) =>
      _operation(() => _regexLibrary.setEnabled(regexId, enabled));
  @override
  Future<void> deleteRegex(String regexId) => _operation(() => _regexLibrary.delete(regexId));
  @override
  Future<String> exportRegex({String? regexId}) => _operation(() => _regexLibrary.exportScripts(id: regexId));

  Future<List<TavernRegexDiagnostic>> _checkCardRegex(Map<String, Object?> data) async {
    final result = [
      ...await inspectRegexScripts(
        _map(data['extensions'])['regex_scripts'],
        _regexWorker,
        path: r'$.data.extensions.regex_scripts',
      ),
    ];
    final embedded = data['character_book'];
    if (embedded is Map<String, Object?>) {
      try {
        final book = WorldInfoBook.fromJson(id: 'card', source: WorldInfoSource.character, json: embedded);
        result.addAll(await _checkWorldBookRegex(book, path: r'$.data.character_book'));
      } on FormatException {
        result.add(
          const TavernRegexDiagnostic(
            path: r'$.data.character_book',
            status: TavernRegexCompatibility.skipped,
            code: 'invalid-world-book',
            message: '内嵌世界书结构无法解析，原始数据保留；无法完成关键词试编译。',
          ),
        );
      }
    }
    return List.unmodifiable(result);
  }

  Future<List<TavernRegexDiagnostic>> _checkWorldBookRegex(WorldInfoBook book, {String path = r'$'}) async {
    final result = <TavernRegexDiagnostic>[];
    for (final input in worldInfoRegexInputs(book)) {
      final checked = input.isDynamic
          ? const RegexCompileResult(
              status: RegexCompileStatus.skipped,
              code: 'runtime-check',
              message: '关键词依赖运行时宏，导入不展开；实际使用时再受控检查。',
            )
          : await _keywordWorker.compile(input.pattern, dialect: input.dialect, caseSensitive: input.caseSensitive);
      result.add(
        regexCompileDiagnostic(
          checked,
          path: '$path.${input.path}',
          identifier: input.uid,
          line: input.line,
          decorator: input.decorator,
          keyIndex: input.keyIndex,
          conditional: input.conditional,
          fallback: input.isFallback,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  Future<T> _bookOperation<T>(FutureOr<T> Function() action) {
    final result = _bookQueue.then((_) => action());
    _bookQueue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<List<TavernLorebookSummary>> listLorebooks() => _operation(
    () => _bookOperation(() async {
      final folder = Directory('${directory.path}/lorebooks');
      if (!await folder.exists()) return <TavernLorebookSummary>[];
      final result = <TavernLorebookSummary>[];
      await for (final entry in folder.list(followLinks: false)) {
        if (entry is! File || !entry.path.endsWith('.json')) continue;
        final name = entry.uri.pathSegments.last;
        final id = name.substring(0, name.length - 5);
        final raw = await _readBookNow(id);
        if (raw == null) continue;
        final book = WorldInfoBook.fromJson(id: id, source: WorldInfoSource.global, json: raw);
        result.add(
          TavernLorebookSummary(
            id: id,
            name: book.name,
            entryCount: book.entries.length,
            stWorldName: _bookSourceNames[id],
          ),
        );
      }
      result.sort((a, b) {
        final name = a.name.compareTo(b.name);
        return name != 0 ? name : a.id.compareTo(b.id);
      });
      return List<TavernLorebookSummary>.unmodifiable(result);
    }),
  );

  @override
  Future<TavernLorebookImportResult> importLorebook(String text, {String? fileName}) => _operation(() async {
    final WorldInfoBook parsed;
    final suppliedName = fileName
        ?.replaceAll('\\', '/')
        .split('/')
        .last
        .replaceFirst(RegExp(r'\.json$', caseSensitive: false), '');
    final sourceName = suppliedName == null || suppliedName.isEmpty ? null : suppliedName;
    try {
      final raw = _decodeObject(text.startsWith('\uFEFF') ? text.substring(1) : text, 'Lorebook');
      if (!raw.containsKey('name') && sourceName != null) {
        raw['name'] = sourceName;
      }
      parsed = WorldInfoBook.fromJson(id: 'import', source: WorldInfoSource.global, json: raw);
    } on FormatException {
      throw const TavernImportError('世界书JSON格式无效。');
    } on JsonUnsupportedObjectError {
      throw const TavernImportError('世界书只能包含合法JSON数值。');
    }
    final diagnostics = await _checkWorldBookRegex(parsed);
    final report = assessImport(
      kind: TavernImportKind.lorebook,
      document: parsed.raw,
      regexDiagnostics: diagnostics,
      checkedAt: _clock().toUtc(),
    );
    return _bookOperation(() async {
      final random = Random.secure();
      String id;
      do {
        id = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      } while (await FileSystemEntity.type('${directory.path}/lorebooks/$id.json', followLinks: false) !=
          FileSystemEntityType.notFound);
      await _writeBookNow(id, parsed.raw, stWorldName: sourceName, importReport: report);
      final book = WorldInfoBook.fromJson(id: id, source: WorldInfoSource.global, json: parsed.raw);
      return TavernLorebookImportResult(
        TavernLorebook(
          id: id,
          name: book.name,
          entryCount: book.entries.length,
          stWorldName: sourceName,
          raw: book.raw,
        ),
        diagnostics,
      );
    });
  });

  @override
  Future<void> putLorebook(String id, Map<String, Object?> json) => _operation(() {
    _requireBookId(id);
    final book = WorldInfoBook.fromJson(id: id, source: WorldInfoSource.global, json: json);
    return _bookOperation(() async {
      await _readBookNow(id);
      await _writeBookNow(id, book.raw);
    });
  });

  Future<void> _writeBookNow(
    String id,
    Map<String, Object?> raw, {
    String? stWorldName,
    TavernImportReport? importReport,
  }) async {
    final sourceName = stWorldName ?? _bookSourceNames[id];
    final report = importReport ?? _bookImportReports[id];
    // Source identity and raw data share one atomic file publication. Valid
    // legacy books have entries at the root; this local envelope does not.
    await _writeJson(
      File('${directory.path}/lorebooks/$id.json'),
      sourceName == null && report == null
          ? raw
          : {
              'format': 'dshgo-lorebook',
              'version': 1,
              'stWorldName': ?sourceName,
              if (report != null) 'importReport': report.toJson(),
              'book': raw,
            },
    );
    _bookRevisions.update(id, (revision) => revision + 1, ifAbsent: () => 1);
    _books[id] = _copy(raw);
    if (sourceName != null) _bookSourceNames[id] = sourceName;
    if (report != null) _bookImportReports[id] = report;
  }

  @override
  Future<Map<String, Object?>?> lorebook(String id) => _operation(() async {
    _requireBookId(id);
    final value = await _readBook(id);
    return value == null ? null : _copy(value);
  });

  @override
  Future<String> exportLorebook(String id) => _operation(() async {
    final raw = await _readBook(id);
    if (raw == null) throw const TavernImportError('世界书不存在。');
    return jsonEncode(raw);
  });

  @override
  Future<void> deleteLorebook(String id) => _operation(() {
    _requireBookId(id);
    return _bookOperation(() async {
      final file = File('${directory.path}/lorebooks/$id.json');
      if (await file.exists()) {
        await file.delete();
      } else {
        // exists can hide lookup errors. Preserve its link-following and
        // known non-file behavior, but do not acknowledge uncertain absence.
        final type = await FileSystemEntity.type(file.path, followLinks: true);
        if (type == FileSystemEntityType.file ||
            type == FileSystemEntityType.pipe ||
            type == FileSystemEntityType.unixDomainSock) {
          await file.delete();
        } else if (type == FileSystemEntityType.notFound) {
          // Linux delete can fold a lookup error into ENOENT. A read-only
          // open preserves that error without reading or creating the book.
          RandomAccessFile? probe;
          try {
            probe = await file.open(mode: FileMode.read);
          } on PathNotFoundException catch (error) {
            final code = error.osError?.errorCode;
            if (code != 2 && (!Platform.isWindows || code != 3)) rethrow;
          }
          if (probe != null) {
            // Neither close nor delete errors authorize the cache cleanup.
            await probe.close();
            await file.delete();
          }
        }
      }
      _bookRevisions.update(id, (revision) => revision + 1, ifAbsent: () => 1);
      _books.remove(id);
      _bookSourceNames.remove(id);
      _bookImportReports.remove(id);
    });
  });

  /// A global binding applies to all chats; a chat binding overrides that
  /// source's global list. Character-specific bindings may be set globally via
  /// settings.characterLorebooks[characterId]. Card-embedded books always join.
  @override
  Future<void> bindLorebooks(
    List<String> ids, {
    WorldInfoSource source = WorldInfoSource.global,
    String? chatId,
    String? characterId,
    String? personaId,
  }) {
    for (final id in ids) {
      _requireBookId(id);
    }
    final captured = List<String>.of(ids);
    if ([chatId, characterId, personaId].where((value) => value != null).length > 1 ||
        (characterId != null && source != WorldInfoSource.character) ||
        (personaId != null && source != WorldInfoSource.persona)) {
      throw ArgumentError('Select one matching chat, character or persona scope.');
    }
    if (characterId != null) {
      return _operation(
        () => _libraryOperation(
          () => _presetOperation(() async {
            if (_deletingCharacters.contains(characterId) || await _record(characterId) == null) {
              throw const TavernImportError('角色不存在或正在删除。');
            }
            await _setSettingsCaptured({
              'characterLorebooks': {characterId: captured},
            });
          }),
        ),
      );
    }
    if (personaId != null) {
      return _operation(
        () => _personaOperation(
          () => _presetOperation(() async {
            if (_deletingPersonas.contains(personaId) || _personas.get(personaId) == null) {
              throw const TavernImportError('人设不存在或正在删除。');
            }
            await _setSettingsCaptured({
              'personaLorebooks': {personaId: captured},
            });
          }),
        ),
      );
    }
    return setSettings({
      'lorebooks': {source.name: captured},
    }, chatId: chatId);
  }

  /// ST character filters use the avatar filename and independent tag-map ids,
  /// not a card's display name, library id, or descriptive tags. Importers/UI
  /// can supply that identity explicitly; absent tag-map data remains null.
  Future<void> setCharacterIdentity(String characterId, {required String avatarFilename, List<String>? tagIds}) =>
      setSettings({
        'characterIdentities': {
          characterId: {'avatarFilename': avatarFilename, 'tagIds': tagIds == null ? null : List<String>.of(tagIds)},
        },
      });

  Map<String, Object?> _effectiveSettings([StoredChat? chat, Map<String, Object?>? metadata]) {
    var result = _map(_document['settings']);
    if (chat != null) {
      final source = metadata ?? _chatCodec.metadataForNode(_store, chat.id);
      result = _merge(
        result,
        _chatMetadataSettings(source, _map(chat.settings['stLorebookIds']), _map(result['authorNote'])),
      );
      result = _merge(result, chat.settings);
    }
    // A selected preset is one complete preset, not a field-by-field mixture
    // with whichever global preset happened to be selected previously.
    final selection = _resolvePreset(chat);
    if (selection.preset != null) {
      result['preset'] = selection.preset!.raw;
    } else if (chat != null && chat.settings.containsKey('preset')) {
      result['preset'] = _map(chat.settings['preset']);
    }
    final overrides = _map(result['presetOverrides']);
    final sampling = <String, Object?>{
      for (final key in const [
        'temperature',
        'top_p',
        'presence_penalty',
        'frequency_penalty',
        'openai_max_tokens',
        'openai_max_context',
      ])
        if (overrides.containsKey(key)) key: overrides[key],
    };
    if (sampling.isNotEmpty) result['preset'] = {..._map(result['preset']), ...sampling};
    // Project only after every global/source/chat merge. A read->set roundtrip
    // cannot duplicate the collection or replace it with a supplied snapshot.
    result.remove('managedRegexScripts');
    final managed = _regexLibrary.executionScripts;
    if (managed.isNotEmpty) result['managedRegexScripts'] = managed;
    return result;
  }

  Future<Map<String, Object?>?> _readBook(String id) => _bookOperation(() => _readBookNow(id));

  Future<({Map<String, Object?> raw, String? stWorldName})?> _readBookSnapshot(String id) => _bookOperation(() async {
    final raw = await _readBookNow(id);
    return raw == null ? null : (raw: raw, stWorldName: _bookSourceNames[id]);
  });

  Future<Map<String, Object?>?> _readBookNow(String id) async {
    _requireBookId(id);
    final cached = _books[id];
    if (cached != null) return cached;
    final revision = _bookRevisions[id] ?? 0;
    final file = File('${directory.path}/lorebooks/$id.json');
    if (!await file.exists()) return null;
    final document = _decodeObject(await file.readAsString(), 'Lorebook');
    Map<String, Object?> value = document;
    String? sourceName;
    TavernImportReport? report;
    if (!document.containsKey('entries') && document['format'] == 'dshgo-lorebook') {
      if (document['version'] != 1 ||
          document['book'] is! Map<String, Object?> ||
          (document['stWorldName'] != null && document['stWorldName'] is! String)) {
        throw const FormatException('Unsupported or invalid stored lorebook.');
      }
      value = document['book']! as Map<String, Object?>;
      sourceName = document['stWorldName'] as String?;
      if (document['importReport'] != null) {
        report = TavernImportReport.fromJson(document['importReport']! as Map<String, Object?>);
      }
    }
    if ((_bookRevisions[id] ?? 0) == revision) {
      _books[id] = value;
      if (report == null) {
        _bookImportReports.remove(id);
      } else {
        _bookImportReports[id] = report;
      }
      if (sourceName == null) {
        _bookSourceNames.remove(id);
      } else {
        _bookSourceNames[id] = sourceName;
      }
    }
    return value;
  }

  Future<void> _saveDocument() {
    _document['globalVariables'] = _copy(_globalVariables);
    return _writeJson(File('${directory.path}/settings.json'), _document);
  }

  Future<void> _writeJson(File file, Map<String, Object?> json) {
    final text = jsonEncode(json);
    final result = _fileQueue.then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.writing');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(file.path);
    });
    _fileQueue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<T> _withMutation<T>(String chatId, FutureOr<T> Function() action) => _withMutations([chatId], action);

  Future<T> _withMutations<T>(Iterable<String> chatIds, FutureOr<T> Function() action) {
    final ids = chatIds.toSet();
    final previous = [for (final id in ids) _mutations[id] ?? Future<void>.value()];
    final released = Completer<void>();
    // Register every gate before awaiting any turn, including when one persona
    // deletion affects several chats. Later overlapping mutations wait behind
    // this same gate; none can enter while another affected chat is draining.
    for (final id in ids) {
      _mutations[id] = released.future;
      _turns[id]?.cancellation.cancel();
    }
    return () async {
      try {
        await Future.wait(previous);
        final running = ids.map((id) => _turns[id]).whereType<_Turn>().toList();
        for (final turn in running) {
          turn.cancellation.cancel();
        }
        await Future.wait([for (final turn in running) turn.done.future]);
        return await action();
      } finally {
        for (final id in ids) {
          if (identical(_mutations[id], released.future)) {
            // remove returns this same gate Future; complete it below. Waiting
            // for it here would deadlock the mutation's own finally block.
            unawaited(_mutations.remove(id));
          }
        }
        released.complete();
        _notifyLists();
      }
    }();
  }

  @override
  Future<void> selectSibling(String chatId, String nodeId, int index) => _operation(
    () => _withMutation(chatId, () {
      _store.transaction(() {
        _store.selectSibling(chatId, nodeId, index);
        _restoreVariables(chatId);
      });
      _liveVariables.remove(chatId);
    }),
  );

  @override
  Future<void> selectNode(String chatId, String nodeId, {bool restoreDescendants = false}) => _operation(
    () => _withMutation(chatId, () {
      _store.transaction(() {
        _store.selectNode(chatId, nodeId, restoreDescendants: restoreDescendants);
        _restoreVariables(chatId);
      });
      _liveVariables.remove(chatId);
    }),
  );

  @override
  Future<void> nameBranch(String chatId, String nodeId, String? name) => _operation(
    () => _withMutation(chatId, () {
      _store.transaction(() {
        final extra = _copy(_store.node(chatId, nodeId).extra);
        final own = _map(extra['dshgo']);
        final label = name?.trim();
        if (label == null || label.isEmpty) {
          if (!own.containsKey('branchName')) {
            return;
          }
          own.remove('branchName');
        } else {
          if (own['branchName'] == label) {
            return;
          }
          own['branchName'] = label;
        }
        extra['dshgo'] = own;
        _store.updateMessage(chatId, nodeId, extra: extra);
      });
    }),
  );

  @override
  Future<void> edit(String chatId, String nodeId, String text) => _operation(
    () => _withMutation(chatId, () async {
      final chat = _store.chat(chatId);
      final record = await _record(chat.characterId);
      if (record == null) throw const TavernImportError('角色不存在。');
      final target = _store.node(chatId, nodeId);
      final current = _historyTo(chatId, chat.currentLeafId).any((node) => node.message.nodeId == nodeId);
      var terminal = current ? _store.node(chatId, chat.currentLeafId!) : target;
      while (!current && terminal.selectedChildId != null) {
        terminal = _store.node(chatId, terminal.selectedChildId!);
      }
      final leaf = terminal.message.nodeId;
      final state = _stateAt(chatId, leaf);
      final cached = _liveVariables[chatId];
      final local = current && cached != null && cached.leaf == leaf
          ? _runtimeCopy(cached.values)
          : _map(state['variables']);
      final metadata = _chatCodec.metadataForNode(_store, chatId, nodeId: leaf);
      final settings = _personaSettings(
        _effectiveSettings(chat, metadata),
        _personas.resolve(personaId: chat.personaId),
      );
      final environment = _MacroEnvironment(
        _effectiveCard(record.card.data, settings),
        settings,
        local,
        _globalVariables,
        _historyTo(chatId, leaf),
        _config,
        _clock(),
        _random,
        _macroChatIdentity(chat, state, metadata, state['chatJsonlSourceFile'] as String?, node: terminal),
        '',
        'normal',
        chatIdHash: _finiteNumber(metadata['chat_id_hash']),
        pickRerollSeed: metadata['pick_reroll_seed'],
        characterId: chat.characterId,
      );
      final globals = _runtimeCopy(_globalVariables);
      try {
        final placement = switch (target.message.role) {
          TavernRole.user => RegexPlacement.userInput,
          TavernRole.narrator => RegexPlacement.slashCommand,
          _ => RegexPlacement.aiOutput,
        };
        final regexed = environment.regex.apply(
          text,
          placement: placement,
          isEdit: true,
          characterOverride: target.message.role == TavernRole.narrator ? null : target.message.speaker,
          expand: environment.regexExpand,
        );
        final expanded = environment.expand(regexed, const {});
        final nextState = <String, Object?>{
          ...state,
          'variables': _copy(local),
          'stChatId': environment.chatId,
          'stChatIdHash': environment.chatIdHash,
        };
        _store.transaction(() {
          _store.edit(chatId, nodeId, expanded);
          _writeNodeState(chatId, leaf, nextState);
          if (current) {
            _store.updateChat(
              chatId,
              variables: _copy(local),
              metadata: _runtimeMetadata(_store.chat(chatId).metadata, nextState),
            );
          }
        });
      } catch (_) {
        _globalVariables
          ..clear()
          ..addAll(globals);
        rethrow;
      }
      if (current) _liveVariables[chatId] = (leaf: leaf, values: _runtimeCopy(local));
      if (_jsonString(globals) != _jsonString(_globalVariables)) await _saveDocument();
    }),
  );

  void _writeNodeState(String chatId, String nodeId, Map<String, Object?> state) {
    final node = _store.node(chatId, nodeId);
    _store.updateMessage(
      chatId,
      nodeId,
      extra: {
        ...node.extra,
        'dshgo': {..._map(node.extra['dshgo']), 'tavernState': _copy(state)},
      },
    );
  }

  bool _impersonationStateChanged(String chatId, String nodeId, Map<String, Object?> state) {
    final previous = _stateAt(chatId, nodeId);
    final comparable = _copy(state);
    final beforeTimers = previous['timedWorldInfo'];
    final afterTimers = comparable['timedWorldInfo'];
    if (beforeTimers is Map<String, Object?> && afterTimers is Map<String, Object?>) {
      // Evaluation materializes these two containers even without any effect.
      // Ignore only newly added empty maps when deciding whether the old leaf
      // needs a write. Existing nulls, arrays, entries and unknown fields keep
      // their exact meaning; actual writes still use the complete new state.
      for (final key in const ['sticky', 'cooldown']) {
        final value = afterTimers[key];
        if (!beforeTimers.containsKey(key) && value is Map<String, Object?> && value.isEmpty) {
          afterTimers.remove(key);
        }
      }
    }
    return _jsonString(previous) != _jsonString(comparable);
  }

  @override
  Future<void> deleteMessage(String chatId, String nodeId) => _operation(
    () => _withMutation(chatId, () {
      final stored = _storedLatestInspection(_store.chat(chatId));
      final latest = _latestInspections.containsKey(chatId) ? _latestInspections[chatId] : stored;
      var clearLatest = false;
      _store.transaction(() {
        final chat = _store.chat(chatId);
        _store.deleteMessage(
          chatId,
          nodeId,
          capturePortableState: (child, physicalState) {
            final override = _map(child.extra['dshgo'])['tavernState'];
            final state = _copy(override is Map<String, Object?> ? override : physicalState);
            // Resolve the child's own old source before any edge or current
            // metadata changes. This callback never reads a hidden node via a
            // visibility-filtered API, and never writes or evaluates macros.
            return _withStateHash(chat, state);
          },
        );
        _restoreVariables(chatId);
        clearLatest = latest != null && !_inspectionAnchorExists(latest);
        if (clearLatest || (stored != null && !_inspectionAnchorExists(stored))) {
          _writeLatestInspection(chatId, null);
        }
      });
      if (clearLatest) {
        _latestInspections[chatId] = null;
      }
      _liveVariables.remove(chatId);
    }),
  );

  @override
  Future<String> deleteFrom(String chatId, String nodeId) => _operation(
    () => _withMutation(chatId, () {
      final stored = _storedLatestInspection(_store.chat(chatId));
      final latest = _latestInspections.containsKey(chatId) ? _latestInspections[chatId] : stored;
      var clearLatest = false;
      final deletionId = _store.transaction(() {
        final token = _store.softDeleteFrom(chatId, nodeId);
        _restoreVariables(chatId);
        clearLatest = latest != null && !_inspectionAnchorExists(latest);
        if (clearLatest || (stored != null && !_inspectionAnchorExists(stored))) {
          _writeLatestInspection(chatId, null);
        }
        return token;
      });
      if (clearLatest) _latestInspections[chatId] = null;
      _liveVariables.remove(chatId);
      return deletionId;
    }),
  );

  @override
  Future<bool> undoDeleteFrom(String chatId, String deletionId) => _operation(
    () => _withMutation(chatId, () {
      final restored = _store.transaction(() {
        if (!_store.undoDeleteFrom(chatId, deletionId)) return false;
        _restoreVariables(chatId);
        return true;
      });
      if (restored) _liveVariables.remove(chatId);
      return restored;
    }),
  );

  @override
  Future<List<TavernMessage>> searchChat(String chatId, String query, {int limit = 50}) => _operation(() {
    final activeId = _turns[chatId]?.reply?.nodeId;
    if (activeId == null || limit <= 0) return _store.searchChat(chatId, query, limit: limit);
    // Before the first body checkpoint, a continuation still has its old
    // committed text/report and no shadow marker. Do not expose that active
    // reply as finalized. One extra result keeps the requested visible limit.
    return _store
        .searchChat(chatId, query, limit: limit + 1)
        .where((message) => message.nodeId != activeId)
        .take(limit)
        .toList();
  });

  @override
  Future<void> setHidden(String chatId, String nodeId, bool hidden) => _operation(
    () => _withMutation(chatId, () {
      _store.transaction(() {
        final node = _store.node(chatId, nodeId);
        _store.updateMessage(chatId, nodeId, original: {...node.original, 'is_system': hidden});
        _store.setHidden(chatId, nodeId, hidden);
      });
    }),
  );

  void _restoreVariables(String chatId) {
    final leaf = _store.chat(chatId).currentLeafId;
    final state = _stateAt(chatId, leaf);
    final variables = _map(state['variables']);
    _store.updateChat(chatId, variables: variables, metadata: _runtimeMetadata(_store.chat(chatId).metadata, state));
  }

  Map<String, Object?> _stateAt(String chatId, String? nodeId) {
    if (nodeId == null) return <String, Object?>{};
    final node = _store.node(chatId, nodeId);
    final override = _map(node.extra['dshgo'])['tavernState'];
    final state = override is Map<String, Object?> ? _copy(override) : _store.nodeState(chatId, nodeId);
    // Older snapshots predate the explicit cache marker. Resolve their own
    // source header before a selection can replace the chat's current cache.
    if (!state.containsKey('stChatIdHash')) {
      _withStateHash(_store.chat(chatId), state);
    }
    return state;
  }

  Map<String, Object?> _withStateHash(StoredChat chat, Map<String, Object?> state) {
    state.putIfAbsent('stChatIdHash', () => _finiteNumber(_chatCodec.metadataForState(chat, state)['chat_id_hash']));
    return state;
  }

  List<StoredNode> _historyTo(String chatId, String? leaf) => _store.historyTo(chatId, leaf);

  @override
  Stream<TavernEvent> send(String chatId, String text) => _streamTurn(chatId, _TurnKind.send, input: text);

  @override
  Future<TavernMessage> sendOnly(String chatId, String text) =>
      _operation(() => _appendManualMessage(chatId, text, narrator: false));

  @override
  Future<TavernMessage> narrate(String chatId, String text, {String? speaker}) =>
      _operation(() => _appendManualMessage(chatId, text, narrator: true, speaker: speaker));

  Future<TavernMessage> _appendManualMessage(String chatId, String text, {required bool narrator, String? speaker}) =>
      _withMutation(chatId, () async {
        final chat = _store.chat(chatId);
        final record = await _record(chat.characterId);
        if (record == null) {
          throw const TavernImportError('角色不存在。');
        }
        final leaf = chat.currentLeafId;
        final metadata = _chatCodec.metadataForNode(_store, chatId);
        final state = leaf == null ? _emptyChatState(metadata) : _stateAt(chatId, leaf);
        final source = state['chatJsonlSourceFile'] ?? _map(_map(chat.metadata['dshgo'])['chatJsonl'])['rootFile'];
        final sourceFile = source is String ? source : null;
        if (sourceFile != null) {
          state['chatJsonlSourceFile'] = sourceFile;
        }
        final cached = _liveVariables[chatId];
        final local = cached != null && cached.leaf == leaf
            ? _runtimeCopy(cached.values)
            : state.containsKey('variables')
            ? _map(state['variables'])
            : leaf != null && sourceFile != null
            ? <String, Object?>{}
            : _copy(chat.variables);
        final settings = _personaSettings(
          _effectiveSettings(chat, metadata),
          _personas.resolve(personaId: chat.personaId),
        );
        final history = _historyTo(chatId, leaf);
        final presetRaw = _map(settings['preset']);
        final preset = ChatPreset({
          ...(presetRaw.isEmpty ? ChatPreset.stDefault().raw : presetRaw),
          'show_thoughts': _config.thinking,
        });
        final environment = _MacroEnvironment(
          _effectiveCard(record.card.data, settings),
          settings,
          local,
          _globalVariables,
          history,
          _config,
          _clock(),
          _random,
          _macroChatIdentity(chat, state, metadata, sourceFile, node: history.lastOrNull),
          text,
          'normal',
          chatIdHash: _finiteNumber(metadata['chat_id_hash']),
          pickRerollSeed: metadata['pick_reroll_seed'],
          characterId: chat.characterId,
          preset: preset,
        );
        final beforeGlobals = _jsonString(_globalVariables);
        late final String expanded;
        try {
          // Adapted from SillyTavern (AGPL-3.0), commit
          // 7e8663cd9c184a550b37238218bdd32c6efc68e9:
          // public/script.js::sendMessageAsUser and
          // public/scripts/slash-commands.js::sendNarratorMessage.
          // sendMessageAsUser applies USER_INPUT before substitution.
          // sendNarratorMessage instead substitutes text.trim(), without regex 3.
          final prepared = narrator
              ? trimJsWhitespace(text)
              : environment.regex.apply(text, placement: RegexPlacement.userInput, expand: environment.regexExpand);
          expanded = environment.expand(prepared, const {});
        } catch (prepareError, prepareStackTrace) {
          // Local state is detached, but preparation uses ST/T11's real globals.
          // Preserve both failures when those effects cannot be saved either.
          try {
            if (beforeGlobals != _jsonString(_globalVariables)) {
              await _saveDocument();
            }
          } catch (saveError, saveStackTrace) {
            Error.throwWithStackTrace(
              _PreparationSaveFailure(
                prepareError,
                prepareStackTrace,
                saveError,
                saveStackTrace,
                operation: narrator ? 'narrate' : 'sendOnly',
              ),
              saveStackTrace,
            );
          }
          Error.throwWithStackTrace(prepareError, prepareStackTrace);
        }
        // Save preparation effects before SQL: a failed write must not append a
        // manual message. Later SQL failure rolls back local state and the tree,
        // while already saved global preparation effects remain committed.
        if (beforeGlobals != _jsonString(_globalVariables)) {
          await _saveDocument();
        }
        final nextState = <String, Object?>{
          ...state,
          'variables': _copy(local),
          'stChatId': environment.chatId,
          'stChatIdHash': environment.chatIdHash,
        };
        _initializeDshState(_stateDefinition(record.card.data), nextState, settings['stateEnabled'] != false);
        final narratorName = metadata['narrator_name'];
        final name = narrator
            ? speaker ?? (narratorName is String && narratorName.isNotEmpty ? narratorName : 'System')
            : environment.userName;
        final message = _store.transaction(() {
          final message = _store.append(
            chatId,
            parentId: leaf,
            role: narrator ? TavernRole.narrator : TavernRole.user,
            speaker: name,
            text: expanded,
            extra: narrator ? const {'type': 'narrator'} : const {},
            state: nextState,
          );
          _store.updateChat(
            chatId,
            variables: _copy(local),
            metadata: _runtimeMetadata(_store.chat(chatId).metadata, nextState),
          );
          return message;
        });
        _liveVariables[chatId] = (leaf: message.nodeId, values: _runtimeCopy(local));
        return message;
      });

  @override
  Stream<TavernEvent> regenerate(String chatId, String nodeId) =>
      _streamTurn(chatId, _TurnKind.regenerate, nodeId: nodeId);
  @override
  Stream<TavernEvent> continueReply(String chatId, String nodeId) =>
      _streamTurn(chatId, _TurnKind.continueReply, nodeId: nodeId);
  @override
  Stream<TavernEvent> impersonate(String chatId) => _streamTurn(chatId, _TurnKind.impersonate);
  @override
  Stream<TavernEvent> resumeTurn(String chatId) {
    late StreamController<TavernEvent> controller;
    _Turn? observed;
    controller = StreamController<TavernEvent>(
      onListen: () {
        try {
          _ensureOpen();
          _store.chat(chatId);
          final turn = _turns[chatId];
          if (turn == null || turn.finished) {
            unawaited(controller.close());
            return;
          }
          // Registration and the complete snapshot are one synchronous
          // operation: no delta can slip between them or appear twice.
          observed = turn;
          turn.observers.add(controller);
          controller.add(
            TavernTurnSnapshot(
              chatId: chatId,
              generationType: turn.generationType,
              startedAt: turn.at,
              message: turn.reply == null ? null : _buffered(turn),
            ),
          );
        } catch (error) {
          controller.add(TavernTurnFailed(TavernFailure.server, detail: _safeDetail(error)));
          unawaited(controller.close());
        }
      },
      onCancel: () {
        observed?.observers.remove(controller);
      },
    );
    return controller.stream;
  }

  @override
  void stop(String chatId) {
    _turns[chatId]?.cancellation.cancel();
  }

  Stream<TavernEvent> _streamTurn(String chatId, _TurnKind kind, {String input = '', String? nodeId}) {
    late StreamController<TavernEvent> controller;
    _Turn? turn;
    controller = StreamController<TavernEvent>(
      onListen: () {
        try {
          _ensureOpen();
          if (_capturingBackup) {
            controller.add(const TavernTurnFailed(TavernFailure.busy, detail: 'backup_capture_in_progress'));
            unawaited(controller.close());
            return;
          }
          final chat = _store.chat(chatId);
          final selection = _personas.resolve(personaId: chat.personaId);
          final presetSelection = _resolvePreset(chat).selection;
          if (_turns.containsKey(chatId) ||
              _mutations.containsKey(chatId) ||
              _globalPresetUpdate ||
              _deletingPresets.contains(presetSelection.effectivePresetId) ||
              _deletingCharacters.contains(chat.characterId) ||
              _deletingPersonas.contains(selection.persona?.id)) {
            controller.add(const TavernTurnFailed(TavernFailure.busy, detail: 'chat_busy'));
            unawaited(controller.close());
            return;
          }
          final metadata = _chatCodec.metadataForNode(_store, chatId, nodeId: nodeId);
          final sourceState = _stateAt(chatId, nodeId ?? chat.currentLeafId);
          final sourceFile =
              sourceState['chatJsonlSourceFile'] ?? _map(_map(chat.metadata['dshgo'])['chatJsonl'])['rootFile'];
          final running = _Turn(
            chat,
            kind,
            input,
            nodeId,
            controller,
            _config,
            _personaSettings(_effectiveSettings(chat, metadata), selection),
            _clock(),
            selection,
            metadata,
            sourceFile is String ? sourceFile : null,
            presetSelection.effectivePresetId,
          );
          turn = running;
          running.directorCaptured = _directors.latestSuccess(chatId);
          if (_secretsEnabled(running.settings) && kind != _TurnKind.impersonate) {
            running.secretCaptured = _store.agentRunsByKind(chatId, const {
              'director.secret_proposal',
            }, limit: 1).firstOrNull;
          }
          _turns[chatId] = running;
          _setInspection(running, running.inspection);
          unawaited(_run(running));
        } catch (error) {
          controller.add(TavernTurnFailed(TavernFailure.server, detail: _safeDetail(error)));
          unawaited(controller.close());
        }
      },
      onCancel: () {
        // Leaving a page releases its observer, not the generation. A later
        // resumeTurn reads the current buffers without retaining old deltas.
        turn?.observers.remove(controller);
      },
    );
    return controller.stream;
  }

  Future<void> _run(_Turn turn) async {
    final chatId = turn.chat.id;
    var beforeGlobals = '';
    try {
      beforeGlobals = _jsonString(_globalVariables);
      turn.originalVariables = _runtimeCopy(_liveVariables[chatId]?.values ?? turn.chat.variables);
      turn.secretCardRevision = _directors._cardRevisions[turn.chat.characterId] ?? 0;
      // Cancellation releases the turn, not its actual local file work.
      // Keep the original read owned until every character file has drained.
      final record = await turn.cancellation.wait(_trackOperation(_record(turn.chat.characterId)));
      if (record == null) throw const TavernImportError('角色不存在。');
      turn.cancellation.check();
      final data = _effectiveCard(record.card.data, turn.settings);
      turn.directorCard = _copy(data);
      StoredNode? target;
      if (turn.nodeId != null) {
        target = _store.node(chatId, turn.nodeId!);
        if (target.message.role != TavernRole.character) throw ArgumentError('The target must be a character message.');
      }
      turn.originalTarget = target;
      var parent = turn.chat.currentLeafId;
      if (turn.kind == _TurnKind.regenerate) parent = target!.message.parentId;
      if (turn.kind == _TurnKind.continueReply) parent = target!.message.nodeId;
      _setInspection(turn, turn.inspection.copyWith(contextNodeId: parent, clearContextNodeId: parent == null));
      // A successful impersonation may update the terminal state of an empty
      // chat without adding a node. Only a turn starting at that empty current
      // end may resume it; an empty regenerate prefix has no such snapshot.
      var state = parent == null && turn.chat.currentLeafId == null && turn.kind != _TurnKind.regenerate
          ? _emptyChatState(turn.metadata)
          : _stateAt(chatId, parent);
      if (turn.sourceFile != null) state['chatJsonlSourceFile'] = turn.sourceFile;
      final cached = _liveVariables[chatId];
      final local = turn.kind != _TurnKind.regenerate && cached != null && cached.leaf == parent
          ? _runtimeCopy(cached.values)
          : state.containsKey('variables')
          ? _map(state['variables'])
          : turn.kind == _TurnKind.regenerate || (parent != null && turn.sourceFile != null)
          ? <String, Object?>{}
          : _copy(turn.chat.variables);
      turn.variables = local;
      turn.state = state;
      _bindSecretTurn(this, turn, data, parent, target, (next, restored) {
        state = next;
        turn.state = next;
        target = restored;
        turn.originalTarget = restored;
      });
      _prepareStateTurn(turn, data);
      final history = _historyTo(chatId, parent);
      turn.directorPrepared = _directors.prepare(turn, data, parent);
      _prepareCardEventTurn(this, turn, data);
      // An inactive target can rewrite remembered edges outside the old active
      // path. Preserve only edges activation can change, including a null
      // selection with still-stored, unselected children below it.
      for (var index = 0; index < history.length; index++) {
        final node = history[index];
        if (index == history.length - 1 || node.selectedChildId != history[index + 1].message.nodeId) {
          turn.previousSelections.add((node.message.nodeId, node.selectedChildId));
        }
      }
      final presetRaw = _map(turn.settings['preset']);
      final preset = ChatPreset({
        ...(presetRaw.isEmpty ? ChatPreset.stDefault().raw : presetRaw),
        'show_thoughts': turn.config.thinking,
      });
      final environment = _MacroEnvironment(
        data,
        turn.settings,
        local,
        _globalVariables,
        history,
        turn.config,
        turn.at,
        _random,
        _macroChatIdentity(
          turn.chat,
          _stateAt(chatId, turn.nodeId ?? parent),
          turn.metadata,
          turn.sourceFile,
          node: target ?? history.lastOrNull,
        ),
        turn.input,
        turn.generationType,
        chatIdHash: _finiteNumber(turn.metadata['chat_id_hash']),
        pickRerollSeed: turn.metadata['pick_reroll_seed'],
        characterId: turn.chat.characterId,
        preset: preset,
      );
      turn.environment = environment;
      if (turn.kind == _TurnKind.send && turn.input.isNotEmpty) {
        final regexed = environment.regex.apply(
          turn.input,
          placement: RegexPlacement.userInput,
          expand: environment.regexExpand,
        );
        final text = environment.expand(regexed, const {});
        final message = _store.transaction(() {
          final message = _store.append(
            chatId,
            parentId: parent,
            role: TavernRole.user,
            speaker: environment.userName,
            text: text,
            state: turn.currentState,
          );
          _store.updateChat(chatId, variables: _copy(local));
          return message;
        });
        turn.newUserId = message.nodeId;
        parent = message.nodeId;
        _liveVariables[chatId] = (leaf: parent, values: _runtimeCopy(local));
        history.add(_store.node(chatId, message.nodeId));
      }
      final prepared = prepareCharacterFields(data, persona: environment.persona, expand: environment.baseExpand);
      // ST expands chat[0].mes after eager card fields, before WI and before
      // filtering hidden/system messages. Keep the same per-turn history for
      // later macros; commit text changes with the ready reply below.
      if (history.isNotEmpty) {
        final first = history.first;
        final expanded = environment.expand(first.message.text, const {});
        if (expanded != first.message.text) {
          history[0] = _nodeWithText(first, expanded);
          if (turn.kind != _TurnKind.impersonate) {
            turn.originalFirstMessage = first;
            turn.expandedFirstMessage = expanded;
          }
        }
      }
      final promptHistory = _preparePromptHistory(
        history,
        environment,
        continuing: turn.kind == _TurnKind.continueReply,
      );
      final eligibleHistory = promptHistory.where((node) => !node.message.hidden && !_systemMessage(node)).toList();
      final activeWorldName = turn.metadata['world_info'];
      final activeBookId = activeWorldName is String
          ? _map(turn.chat.settings['stLorebookIds'])[activeWorldName]
          : null;
      // Own the complete walk, and stop before admitting its next book read.
      final books = await turn.cancellation.wait(
        _trackOperation(
          _loadBooks(
            turn.chat.characterId,
            data,
            turn.settings,
            personaId: turn.personaSelection.persona?.id,
            stWorldNames: {if (activeWorldName is String && activeBookId is String) activeBookId: activeWorldName},
            checkCancelled: turn.cancellation.check,
          ),
        ),
      );
      turn.cancellation.check();
      final directorBooks = _directorBooks(this, turn, books.loaded);
      if (books.missing.isNotEmpty) {
        _setInspection(turn, turn.inspection.copyWith(worldInfo: {'missing': books.missing}));
      }
      final initialInjections = _configuredInjections(
        turn.settings,
        prepared,
        data,
        userMessageCount: history.where((node) => node.message.role == TavernRole.user).length,
      );
      final scanInjections = <String>[];
      for (final item in initialInjections) {
        if (item.scan) {
          final content = environment.expand(item.injection.fragment.content, const {});
          if (content.isNotEmpty) scanInjections.add(content);
        }
      }
      var world = await _worldInfoEngine.evaluate(
        WorldInfoInput(
          books: directorBooks,
          externalActivations: turn.directorPrepared?.external ?? const {},
          messages: [
            for (final node in eligibleHistory) WorldInfoMessage(node.message.text, speaker: node.message.speaker),
          ],
          // ST script.js passes getMaxPromptTokens(), excluding the response.
          maxContext: environment.maxContext - environment.maxResponse,
          tokenCount: _counter.countText,
          random: _random,
          checkCancelled: turn.cancellation.check,
          expand: (text) => environment.expand(text, const {}),
          settings: WorldInfoSettings.fromJson(_map(turn.settings['worldInfo'])),
          scanInjections: scanInjections,
          personaDescription: prepared.persona,
          characterDescription: prepared['description'],
          characterPersonality: prepared['personality'],
          characterDepthPrompt: prepared['charDepthPrompt'],
          scenario: prepared['scenario'],
          creatorNotes: prepared['creator_notes'],
          trigger: turn.generationType,
          characterName: _characterFilename(turn.settings, turn.chat.characterId),
          characterTags: _characterTags(turn.settings, turn.chat.characterId),
          timedWorldInfo: _map(state['timedWorldInfo']),
          decoratorState: _map(state['decoratorState']),
          assistantMessageCount: eligibleHistory.where((node) => node.message.role == TavernRole.character).length,
          greetingIndex: state['greetingIndex'] is int ? state['greetingIndex'] as int : null,
          userIconName: turn.settings['userIconName'] as String?,
          contextAtCapacity: false,
          availablePromptSections: _availableWorldSections(preset, turn.generationType),
          postProcessContent: (entry, content, depth) => environment.regex.apply(
            content,
            placement: RegexPlacement.worldInfo,
            phase: RegexPhase.prompt,
            depth: depth,
            expand: environment.regexExpand,
          ),
        ),
      );
      final preparedUiHits = world.activated.where((hit) => hit.disabledUiPrompt != null).toList();
      _setInspection(
        turn,
        turn.inspection.copyWith(
          worldInfo: _worldInfoTrace(world, preparedUiHits: preparedUiHits, missingBooks: books.missing),
        ),
      );
      environment.outlets.addAll({
        for (final entry in world.outlets.entries) entry.key: entry.value.map((hit) => hit.content).join('\n'),
      });
      final injections = [
        ..._finishInjections(initialInjections, world, deepseek: turn.config.deepseek),
        ..._stateTurnInjections(turn),
        ..._cardEventTurnInjections(turn),
        ..._secretTurnInjections(this, turn, data),
        ..._directorInjections(turn),
      ];
      final examples = [for (var index = 0; index < world.activated.length; index++) (index, world.activated[index])];
      examples.sort((a, b) {
        final aOrder = a.$2.order;
        final bOrder = b.$2.order;
        final byOrder = aOrder == bOrder ? 0 : bOrder.compareTo(aOrder);
        return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
      });
      final assembly = PromptAssembler(counter: _counter).assemble(
        PromptInput(
          preset: preset,
          card: data,
          history: [for (final node in promptHistory) _promptHistory(node)],
          model: turn.config.model,
          userName: environment.userName,
          characterId: turn.chat.characterId,
          generationType: turn.generationType,
          deepseek: turn.config.deepseek,
          persona: environment.persona,
          personaInPrompt: turn.settings['personaInPrompt'] != false,
          worldBefore: world.before.map(_worldFragment).toList(),
          worldAfter: world.after.map(_worldFragment).toList(),
          worldSections: {
            for (final entry in world.sections.entries) entry.key: entry.value.map(_worldFragment).toList(),
          },
          disabledUiPrompts: world.disabledUiPrompts,
          assistantPrefill: [
            if (turn.config.deepseek)
              for (final depth in world.depths)
                for (final hit in depth.entries)
                  if (_worldPrefill(hit)) _worldFragment(hit),
          ],
          injections: injections,
          tools: _stateTurnTools(turn),
          worldExamples: [
            for (final item in examples.reversed)
              if (item.$2.content.isNotEmpty &&
                  item.$2.section == null &&
                  (item.$2.position == 5 || item.$2.position == 6))
                PromptExample(fragment: _worldFragment(item.$2), before: item.$2.position == 5),
          ],
          pinExamples: turn.settings['pinExamples'] == true,
          stripExamples: turn.settings['stripExamples'] == true,
          bias: _string(turn.settings['bias']),
          stops: _strings(turn.settings['stops']),
          expansion: environment.expand,
          cardExpansion: environment.baseExpand,
          preparedFields: prepared,
        ),
      );
      final excludedWorldEntries = <(String, String)>{
        for (final exclusion in assembly.excluded)
          if (exclusion.reason == 'v3-ignore-on-max-context')
            for (final source in exclusion.sources)
              if (source.kind == 'worldInfo' && source.details['bookId'] is String && source.details['uid'] is String)
                (source.details['bookId']! as String, source.details['uid']! as String),
      };
      world = world.withoutEntries(excludedWorldEntries);
      state['timedWorldInfo'] = _copy(world.timedWorldInfo);
      state['decoratorState'] = _copy(world.decoratorState);
      _setInspection(
        turn,
        turn.inspection.copyWith(
          worldInfo: _worldInfoTrace(world, preparedUiHits: preparedUiHits, missingBooks: books.missing),
        ),
      );
      _inspections[chatId] = TavernInspection(
        prompt: assembly,
        worldInfo: world,
        generationType: turn.generationType,
        at: turn.at,
        preparedUiHits: preparedUiHits,
        missingBooks: books.missing,
      );
      _captureAssembly(turn, assembly);
      _captureStateAssembly(turn, assembly);
      _captureCardEventAssembly(turn, assembly);
      _captureSecretAssembly(turn, assembly);
      _captureDirectorAssembly(this, turn, assembly, world);
      if (turn.stateDefinition != null || _hasSecretTrace(turn)) {
        _setInspection(turn, turn.inspection.copyWith(state: _statePreparationTrace(turn)));
      }
      turn.cancellation.check();
      turn.postfix = presetString(preset.settings['continue_postfix']);
      TavernMessage reply;
      if (turn.kind == _TurnKind.impersonate) {
        reply = TavernMessage(
          nodeId: 'temporary-${++_temporaryId}',
          parentId: parent,
          role: TavernRole.user,
          speaker: environment.userName,
          text: '',
          at: turn.at,
        );
      } else {
        final created = _store.transaction(() {
          if (turn.originalFirstMessage case final first?) {
            _store.updateMessage(chatId, first.message.nodeId, text: turn.expandedFirstMessage);
          }
          _store.updateChat(chatId, variables: _copy(local));
          TavernMessage message;
          if (turn.kind == _TurnKind.continueReply) {
            final continuationTarget = target!;
            message = continuationTarget.message;
            // Descendants remain stored. The selected path ends at the node
            // whose continuation is now being generated.
            _store.selectNode(chatId, message.nodeId, restoreDescendants: false);
            final extra = _copy(continuationTarget.extra);
            extra['dshgo'] = {..._map(extra['dshgo']), 'tavernState': turn.currentState};
            message = _store.updateMessage(chatId, message.nodeId, extra: extra);
          } else {
            message = _store.append(
              chatId,
              parentId: parent,
              role: TavernRole.character,
              speaker: record.card.promptName,
              text: '',
              state: turn.currentState,
            );
          }
          final inspection = turn.inspection.copyWith(nodeId: message.nodeId);
          return (message, inspection);
        });
        turn.firstMessageCommitted = turn.originalFirstMessage != null;
        reply = created.$1;
        _setInspection(turn, created.$2);
      }
      turn.begin(reply);
      if (turn.kind != _TurnKind.impersonate) {
        _liveVariables[chatId] = (leaf: reply.nodeId, values: _runtimeCopy(local));
      }
      turn.emit(TavernTurnStarted(_buffered(turn)));
      await _consume(turn, _copy(assembly.body));
      turn.cancellation.check();
      _finishRegex(turn);
      if (beforeGlobals != _jsonString(_globalVariables)) await _saveDocument();
      turn.cancellation.check();
      final stateSettlement = _settleStateTurn(this, turn, successful: true);
      turn.stateAttempt = stateSettlement;
      final storySettlement = _settleStoryTurn(this, turn, stateSettlement?.state ?? turn.currentState);
      turn.storyAttempt = storySettlement;
      _commitTurn(
        turn,
        turn.inspection.copyWith(status: TavernInspectionStatus.completed, finishedAt: _clock()),
        stateSettlement: stateSettlement,
        storySettlement: storySettlement,
      );
      turn.emit(TavernTurnDone(_latest(turn), finishReason: turn.finishReason));
      turn.terminal = true;
      _directors.afterTurn(turn);
    } catch (error) {
      var failure = error is TavernModelException
          ? error.kind
          : error is PromptBudgetExceeded
          ? TavernFailure.contextTooLong
          : error is TavernImportError || error is FormatException
          ? TavernFailure.invalidCard
          : TavernFailure.server;
      var detail = error is TavernModelException ? error.detail : _safeDetail(error);
      TavernMessage? partial;
      var inspection = turn.inspection.copyWith(
        status: TavernInspectionStatus.failed,
        finishedAt: _clock(),
        failure: failure,
        detail: detail,
      );
      try {
        _finishRegex(turn);
      } catch (writeError) {
        failure = TavernFailure.server;
        detail = 'writeback_failed (${writeError.runtimeType})';
        inspection = inspection.copyWith(failure: failure, detail: detail);
      }
      // Resolve the asynchronous file result before publishing one SQL
      // terminal snapshot. A file failure must not prevent an empty rollback.
      try {
        if (beforeGlobals != _jsonString(_globalVariables)) await _saveDocument();
      } catch (fileError) {
        failure = TavernFailure.server;
        detail = 'turn_storage_failure (${fileError.runtimeType})';
        inspection = inspection.copyWith(failure: failure, detail: detail);
      }
      try {
        final stateSettlement = _failedStateSettlement(this, turn, inspection);
        final storySettlement = _failedStorySettlement(turn, inspection);
        if (stateSettlement != null) inspection = inspection.copyWith(state: stateSettlement.trace);
        if (turn.hasOutput) {
          _commitTurn(turn, inspection, stateSettlement: stateSettlement, storySettlement: storySettlement);
          partial = _latest(turn);
        } else {
          inspection = inspection.copyWith(clearNodeId: true);
          _rollbackEmpty(turn, inspection, stateSettlement: stateSettlement, storySettlement: storySettlement);
          if (turn.kind == _TurnKind.continueReply) partial = turn.originalTarget?.message;
        }
        // Terminal storage has added the state/story/event failure traces.
        // Keep that published snapshot instead of replacing it below with
        // the pre-storage inspection captured by this catch block.
        inspection = turn.inspection;
      } catch (storageError) {
        // Do not return partial=null after a failed rollback: that would invite
        // the UI to reinsert a user line that might still be in the database.
        failure = TavernFailure.server;
        detail = 'turn_storage_failure (${storageError.runtimeType})';
        partial = turn.lastCommitted;
        if (partial == null && turn.newUserId != null) {
          try {
            partial = _store.message(chatId, turn.newUserId!);
          } catch (_) {
            /* Original failure is retained. */
          }
        }
        inspection = inspection.copyWith(
          status: TavernInspectionStatus.failed,
          finishedAt: _clock(),
          failure: failure,
          detail: detail,
        );
      }
      _setInspection(turn, inspection);
      turn.emit(TavernTurnFailed(failure, detail: detail, partial: partial));
      turn.terminal = true;
    } finally {
      turn.flushTimer?.cancel();
      turn.finished = true;
      if (identical(_turns[chatId], turn)) _turns.remove(chatId);
      if (!turn.done.isCompleted) turn.done.complete();
      // A paused consumer can delay stream.close forever. It must not hold the
      // database, a mutation, or engine.close hostage.
      for (final observer in turn.observers) {
        unawaited(observer.close());
      }
      turn.observers.clear();
      _notifyLists();
    }
  }

  Future<({List<WorldInfoBook> loaded, List<Map<String, Object?>> missing})> _loadBooks(
    String characterId,
    Map<String, Object?> data,
    Map<String, Object?> settings, {
    String? personaId,
    Map<String, String> stWorldNames = const {},
    void Function()? checkCancelled,
  }) async {
    final result = <WorldInfoBook>[];
    final missing = <Map<String, Object?>>[];
    final bindings = _map(settings['lorebooks']);
    for (final source in WorldInfoSource.values) {
      final ids = <String>[
        ..._strings(bindings[source.name]),
        if (source == WorldInfoSource.character) ..._strings(_map(settings['characterLorebooks'])[characterId]),
        if (source == WorldInfoSource.persona && personaId != null)
          ..._strings(_map(settings['personaLorebooks'])[personaId]),
      ];
      for (final id in ids) {
        checkCancelled?.call();
        final saved = await _readBookSnapshot(id);
        checkCancelled?.call();
        if (saved == null) {
          missing.add({'bookId': id, 'source': source.name, 'reason': 'missing'});
          continue;
        }
        result.add(
          WorldInfoBook.fromJson(
            id: id,
            source: source,
            json: saved.raw,
            stWorldName: stWorldNames[id] ?? saved.stWorldName,
          ),
        );
      }
    }
    checkCancelled?.call();
    final embedded = data['character_book'];
    if (embedded is Map<String, Object?>) {
      result.add(WorldInfoBook.fromJson(id: '$characterId:card', source: WorldInfoSource.character, json: embedded));
    }
    return (loaded: result, missing: missing);
  }

  Future<void> _consume(_Turn turn, Map<String, Object?> body) async {
    final completed = Completer<void>();
    void fail(Object error, StackTrace stack) {
      if (!completed.isCompleted) completed.completeError(error, stack);
    }

    unawaited(
      turn.cancellation.whenCancelled.then<void>((_) {
        fail(const TavernModelException(TavernFailure.cancelled, 'cancelled'), StackTrace.current);
      }),
    );
    StreamSubscription<ModelDelta>? subscription;
    var streamingWrites = false;
    try {
      turn.cancellation.check();
      if (turn.kind != _TurnKind.impersonate) {
        _store.beginStreamingWrites();
        streamingWrites = true;
        turn.flushTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
          if (completed.isCompleted) return;
          try {
            _checkpointBody(turn);
          } catch (error, stack) {
            fail(error, stack);
          }
        });
      }
      final secretInspection = _prepareSecretRequest(this, turn);
      turn.cancellation.check();
      if (secretInspection != null) {
        turn.secretRequestAttempted = true;
        _setInspection(turn, secretInspection);
      }
      subscription = _modelClient
          .generate(config: turn.config, body: body, cancellation: turn.cancellation)
          .listen(
            (delta) {
              if (completed.isCompleted || turn.cancellation.isCancelled) return;
              try {
                switch (delta) {
                  case ModelToolFragment():
                    turn.stateTools.add(delta);
                    turn.stateWatch ??= Stopwatch()..start();
                    return;
                  case ModelText(:final text):
                    if (text.isEmpty) return;
                    var addition = text;
                    if (turn.kind == _TurnKind.continueReply && !turn.receivedText) {
                      if (!turn.text!.toString().endsWith(' ')) addition = '${turn.postfix}$text';
                    }
                    turn.receivedText = true;
                    turn.text!.write(addition);
                    turn.dirty = true;
                    turn.emit(TavernTextDelta(turn.reply!.nodeId, addition));
                  case ModelReasoning(:final text):
                    if (text.isEmpty || (turn.config.deepseek && !turn.config.thinking)) return;
                    turn.reasoning!.write(text);
                    turn.dirty = true;
                    turn.emit(TavernReasoningDelta(turn.reply!.nodeId, text));
                  case ModelUsage(:final usage):
                    turn.usage = usage;
                    _setInspection(turn, turn.inspection.copyWith(reportedUsage: usage));
                  case ModelFinished(:final reason):
                    turn.finishReason = reason;
                    completed.complete();
                    return;
                }
                turn.hasOutput = true;
              } catch (error, stack) {
                fail(error, stack);
              }
            },
            onError: (Object error, StackTrace stack) => fail(error, stack),
            onDone: () {
              if (!completed.isCompleted) completed.complete();
            },
            cancelOnError: true,
          );
      await completed.future;
    } finally {
      turn.flushTimer?.cancel();
      // The transport owns its HTTP client. Cancelling an async* subscription
      // can itself wait for I/O, so no tree mutation depends on this Future.
      subscription?.cancel().ignore();
      if (streamingWrites) _store.endStreamingWrites();
    }
  }

  void _finishRegex(_Turn turn) {
    final environment = turn.environment;
    if (turn.writeBackAttempted || !turn.hasOutput || turn.reply == null || environment == null) return;
    // A finish, stop, failed transport and late onDone may converge here. Mark
    // before evaluating user scripts, including scripts that later throw.
    turn.writeBackAttempted = true;
    final local = _runtimeCopy(environment.local);
    final global = _runtimeCopy(environment.global);
    final history = List<StoredNode>.of(environment.history);
    final hash = environment.chatIdHash;
    final raw = _buffered(turn);
    try {
      final index = environment.history.indexWhere((node) => node.message.nodeId == raw.nodeId);
      final node = StoredNode(
        message: raw,
        depth: index < 0 ? history.length : index,
        extra: const {},
        original: const {},
      );
      if (index < 0) {
        environment.history.add(node);
      } else {
        environment.history[index] = node;
      }
      final text = environment.regex.apply(
        raw.text,
        placement: turn.kind == _TurnKind.impersonate ? RegexPlacement.userInput : RegexPlacement.aiOutput,
        expand: environment.regexExpand,
      );
      final reasoning = environment.regex.apply(
        raw.reasoning ?? '',
        placement: RegexPlacement.reasoning,
        expand: environment.regexExpand,
      );
      turn.text = StringBuffer(text);
      turn.reasoning = StringBuffer(reasoning);
      turn.dirty = true;
    } catch (_) {
      environment.local
        ..clear()
        ..addAll(local);
      environment.global
        ..clear()
        ..addAll(global);
      environment.history
        ..clear()
        ..addAll(history);
      environment.chatIdHash = hash;
      // Buffers are still the complete raw response. The preparation-stage
      // effects present in the saved snapshots above are intentionally kept.
      rethrow;
    }
  }

  void _checkpointBody(_Turn turn) {
    if (!turn.dirty || turn.reply == null || turn.kind == _TurnKind.impersonate) return;
    final message = _buffered(turn, includeUsage: false);
    _store.writeStreamingBody(turn.chat.id, message.nodeId, text: message.text, reasoning: message.reasoning);
    turn.lastCommitted = message;
    turn.dirty = false;
  }

  // Ordinary completion/cancellation writes the inspection and indexes the
  // final body once, in the same FULL transaction as usage and runtime state.
  // A failed transaction can be retried by the terminal failure path.
  void _commitTurn(
    _Turn turn,
    TavernTurnInspection inspection, {
    _StateSettlement? stateSettlement,
    _StorySettlement? storySettlement,
  }) {
    final message = _buffered(turn);
    final state = storySettlement?.state ?? stateSettlement?.state ?? turn.currentState;
    final ownAudit = stateSettlement?.ownAudit;
    if (stateSettlement != null) inspection = inspection.copyWith(state: stateSettlement.trace);
    final events = stateSettlement?.events;
    if (events != null) {
      inspection = inspection.copyWith(director: {...inspection.director, 'eventRules': events.trace});
    }
    if (storySettlement != null) {
      inspection = inspection.copyWith(director: {...inspection.director, 'story': storySettlement.trace});
    }
    if (turn.kind != _TurnKind.impersonate) {
      turn.lastCommitted = _store.transaction(() {
        final extra = _inspectionExtra(_store.node(turn.chat.id, message.nodeId).extra, inspection);
        extra['dshgo'] = {..._map(extra['dshgo']), ...?ownAudit, ...?storySettlement?.ownAudit, 'tavernState': state};
        final stored = _store.updateMessage(
          turn.chat.id,
          message.nodeId,
          text: message.text,
          reasoning: message.reasoning,
          clearReasoning: message.reasoning == null,
          usage: message.usage,
          clearUsage: message.usage == null,
          extra: extra,
        );
        _store.updateChat(
          turn.chat.id,
          variables: _copy(turn.variables),
          metadata: _latestInspectionMetadata(_runtimeMetadata(_store.chat(turn.chat.id).metadata, state), inspection),
        );
        _writeStateRuns(_store, turn, stateSettlement, message.nodeId);
        _writeStoryRun(_store, turn, storySettlement, message.nodeId);
        return stored;
      });
      _liveVariables[turn.chat.id] = (leaf: message.nodeId, values: _runtimeCopy(turn.variables));
    } else {
      _store.transaction(() {
        final leaf = turn.chat.currentLeafId;
        if (leaf != null && _impersonationStateChanged(turn.chat.id, leaf, state)) {
          _writeNodeState(turn.chat.id, leaf, state);
        }
        _store.updateChat(
          turn.chat.id,
          variables: _copy(turn.variables),
          metadata: _latestInspectionMetadata(_runtimeMetadata(_store.chat(turn.chat.id).metadata, state), inspection),
        );
        _writeStateRuns(_store, turn, stateSettlement, null);
        _writeStoryRun(_store, turn, storySettlement, null);
      });
      _liveVariables[turn.chat.id] = (leaf: turn.chat.currentLeafId, values: _runtimeCopy(turn.variables));
      turn.lastCommitted = message;
    }
    if (stateSettlement != null || storySettlement != null) {
      turn.state = _copy(state);
    }
    if (stateSettlement != null) turn.stateRunsWritten = true;
    if (storySettlement != null) turn.storyRunWritten = true;
    _setInspection(turn, inspection);
    turn.dirty = false;
  }

  TavernMessage _buffered(_Turn turn, {bool includeUsage = true}) {
    final reply = turn.reply!;
    final reasoning = turn.reasoning!.toString();
    return TavernMessage(
      nodeId: reply.nodeId,
      parentId: reply.parentId,
      role: reply.role,
      speaker: reply.speaker,
      text: turn.text!.toString(),
      reasoning: reasoning.isEmpty && reply.reasoning == null ? null : reasoning,
      at: reply.at,
      siblingIndex: reply.siblingIndex,
      siblingCount: reply.siblingCount,
      hidden: reply.hidden,
      usage: includeUsage ? turn.usage : null,
      reportedUsage: includeUsage ? turn.inspection.reportedUsage : null,
    );
  }

  TavernMessage _latest(_Turn turn) =>
      turn.kind == _TurnKind.impersonate ? _buffered(turn) : _store.message(turn.chat.id, turn.reply!.nodeId);

  void _rollbackEmpty(
    _Turn turn,
    TavernTurnInspection failed, {
    _StateSettlement? stateSettlement,
    _StorySettlement? storySettlement,
  }) {
    if (stateSettlement != null) failed = failed.copyWith(state: stateSettlement.trace);
    final events = stateSettlement?.events;
    if (events != null) {
      failed = failed.copyWith(director: {...failed.director, 'eventRules': events.trace});
    }
    if (storySettlement != null) {
      failed = failed.copyWith(director: {...failed.director, 'story': storySettlement.trace});
    }
    if (turn.kind == _TurnKind.impersonate) {
      _store.transaction(() {
        _writeInspection(failed);
        _writeStateRuns(_store, turn, stateSettlement, null);
        _writeStoryRun(_store, turn, storySettlement, null);
      });
      if (stateSettlement != null) turn.stateRunsWritten = true;
      if (storySettlement != null) turn.storyRunWritten = true;
      _setInspection(turn, failed);
      return;
    }
    _store.transaction(() {
      final original = turn.originalTarget;
      if (turn.kind == _TurnKind.continueReply && turn.reply != null && original != null) {
        final message = original.message;
        _store.updateMessage(
          turn.chat.id,
          message.nodeId,
          text: message.text,
          reasoning: message.reasoning,
          clearReasoning: message.reasoning == null,
          usage: message.usage,
          clearUsage: message.usage == null,
          extra: original.extra,
        );
      } else if (turn.reply != null) {
        _store.deleteFrom(turn.chat.id, turn.reply!.nodeId);
      }
      if (turn.newUserId != null) _store.deleteFrom(turn.chat.id, turn.newUserId!);
      final first = turn.originalFirstMessage;
      if (turn.firstMessageCommitted && first != null && first.message.nodeId != turn.newUserId) {
        _store.updateMessage(turn.chat.id, first.message.nodeId, text: first.message.text);
      }
      // Restore deepest choices first, then the old active leaf. Selecting a
      // child only rewrites its ancestors, never its remembered descendants.
      for (final selection in turn.previousSelections.reversed) {
        _store.selectNode(turn.chat.id, selection.$2 ?? selection.$1, restoreDescendants: selection.$2 != null);
      }
      if (turn.chat.currentLeafId != null) {
        _store.selectNode(turn.chat.id, turn.chat.currentLeafId!, restoreDescendants: false);
      } else {
        // Deleting a temporary root can select a surviving sibling. An old
        // empty path is an explicit selection too, even with roots retained.
        _store.clearSelection(turn.chat.id);
      }
      _store.updateChat(turn.chat.id, variables: turn.chat.variables);
      _writeLatestInspection(turn.chat.id, failed);
      _writeStateRuns(
        _store,
        turn,
        stateSettlement,
        turn.kind == _TurnKind.continueReply ? original?.message.nodeId : null,
      );
      _writeStoryRun(
        _store,
        turn,
        storySettlement,
        turn.kind == _TurnKind.continueReply ? original?.message.nodeId : null,
      );
    });
    if (stateSettlement != null) turn.stateRunsWritten = true;
    if (storySettlement != null) turn.storyRunWritten = true;
    _setInspection(turn, failed);
    _liveVariables[turn.chat.id] = (leaf: turn.chat.currentLeafId, values: _runtimeCopy(turn.originalVariables));
  }

  Stream<T> _watch<T>(Stream<void> changes, FutureOr<T> Function() snapshot) {
    late StreamController<T> controller;
    StreamSubscription<void>? subscription;
    var ended = false;
    var dirty = false;
    var pumping = false;
    Future<void> refresh() async {
      dirty = true;
      if (pumping) return;
      pumping = true;
      try {
        while (dirty && !ended && !_closing && !_closed) {
          // A watcher can rebuild derived character indexes. Reads that
          // already started belong to the backup's admitted operations;
          // later reads wait outside that set, avoiding a backup/self wait.
          final captureDone = _backupCaptureDone;
          if (captureDone != null) {
            await captureDone.future;
            continue;
          }
          dirty = false;
          try {
            final value = await _trackOperation(Future<T>.sync(snapshot));
            // A change during the first asynchronous file load must not be
            // lost, nor should it publish a knowingly stale initial snapshot.
            if (!ended && !_closing && !_closed && !dirty) controller.add(value);
          } catch (error, stack) {
            if (!ended && !_closing && !_closed) controller.addError(error, stack);
          }
        }
      } finally {
        pumping = false;
      }
    }

    controller = StreamController<T>(
      onListen: () {
        if (_closing || _closed) {
          ended = true;
          unawaited(controller.close());
          return;
        }
        subscription = changes.listen(
          (_) => unawaited(refresh()),
          onDone: () {
            ended = true;
            unawaited(controller.close());
          },
        );
        unawaited(refresh());
      },
      onCancel: () {
        ended = true;
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<TavernBackupInfo> backup(String destinationPath) {
    _ensureOpen();
    if (_backupInProgress || _turns.isNotEmpty || _directors.hasJobs) {
      return Future.error(const TavernModelException(TavernFailure.busy, 'backup_busy'));
    }
    // Close admission before draining. Capture the prior operations BEFORE
    // tracking this backup, otherwise it would wait on its own completion.
    _capturingBackup = true;
    _backupInProgress = true;
    _backupCaptureDone = Completer<void>();
    final admitted = List<Future<void>>.of(_operations);
    return _trackOperation(_createBackup(destinationPath, admitted));
  }

  Future<TavernBackupInfo> _createBackup(String destinationPath, List<Future<void>> admitted) async {
    backup_io.TavernBackupSnapshot? snapshot;
    try {
      try {
        await Future.wait(admitted);
        snapshot = await backup_io.captureTavernBackup(
          directory,
          backupDatabase: _store.backupToFile,
          createdAt: _clock(),
        );
      } finally {
        _capturingBackup = false;
        final captureDone = _backupCaptureDone;
        _backupCaptureDone = null;
        captureDone?.complete();
      }
      return await snapshot.writeZip(File(destinationPath));
    } finally {
      try {
        await snapshot?.dispose();
      } finally {
        _backupInProgress = false;
      }
    }
  }

  static Future<void> _validateBackupStaging(Directory staging, int sourceSchemaVersion) async {
    await ChatStore.validateBackup(File('${staging.path}/tavern.sqlite3'), sourceSchemaVersion: sourceSchemaVersion);
    final probe = await TavernEngine.openDirectory(staging);
    try {
      // Use the existing versioned loaders; never reimport opaque card bytes,
      // recompile regex scripts, or replace recorded intake reports.
      final characters = await probe._library.list();
      for (final character in characters) {
        await probe._library.readImportReport(character.id);
      }
      probe._personas.list();
      for (final preset in probe._presetSummaries()) {
        probe._store.preset(preset.id);
      }
      await probe.listLorebooks();
    } finally {
      await probe.close();
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    for (final turn in _turns.values) {
      turn.cancellation.cancel();
    }
    await _directors.close();
    // Unblock guarded work before waiting for operations that may own it.
    await Future.wait([_regexWorker.close(), _keywordWorker.close()]);
    while (_turns.isNotEmpty || _operations.isNotEmpty) {
      await Future.wait<void>([..._operations, for (final turn in _turns.values) turn.done.future]);
    }
    await _fileQueue;
    await _libraryQueue;
    await _personaQueue;
    await _presetQueue;
    await _bookQueue;
    await _personaSubscription.cancel();
    await _storeSubscription.cancel();
    _liveVariables.clear();
    _latestInspections.clear();
    _inspections.clear();
    _closed = true;
    unawaited(_charactersChanged.close());
    unawaited(_chatsChanged.close());
    unawaited(_paths.close());
    await _personas.close();
    await _store.close();
    _ownedTavernRoots.remove(_directoryOwnerKey);
  }
}

class _DisplayQueue {
  int version = 0;
  bool running = false;
  _DisplayJob? pending;
}

class _DisplayJob {
  _DisplayJob(
    this.version,
    this.chatId,
    this.nodeId,
    this.text,
    this.role,
    this.depth,
    this.reasoning,
    this.characterOverride,
    this.isSystem,
  );
  final int version;
  final String chatId;
  final String? nodeId;
  final String text;
  final TavernRole role;
  final num? depth;
  final bool reasoning;
  final String? characterOverride;
  final bool isSystem;
  final result = Completer<TavernDisplayResult>();
}

int _displaySeed(String identity) {
  var hash = 2166136261;
  for (final unit in identity.codeUnits) {
    hash = ((hash ^ unit) * 16777619) & 0x7fffffff;
  }
  return hash;
}

class _PreparationSaveFailure implements Exception {
  const _PreparationSaveFailure(
    this.createError,
    this.createStackTrace,
    this.saveError,
    this.saveStackTrace, {
    this.operation = 'createChat',
  });
  final String operation;
  // Keep the original createChat error/stack fields for callers inspecting
  // both failures; manual-message preparation uses the same carrier.
  final Object createError;
  final StackTrace createStackTrace;
  final Object saveError;
  final StackTrace saveStackTrace;
  @override
  String toString() =>
      '$operation failed: $createError\n'
      'Saving global variables also failed: $saveError';
}

enum _TurnKind { send, regenerate, continueReply, impersonate }

class _Turn {
  _Turn(
    this.chat,
    this.kind,
    this.input,
    this.nodeId,
    StreamController<TavernEvent> controller,
    this.config,
    this.settings,
    this.at,
    this.personaSelection,
    this.metadata,
    this.sourceFile,
    this.presetId,
  ) {
    observers.add(controller);
    inspection = TavernTurnInspection(
      chatId: chat.id,
      contextNodeId: chat.currentLeafId,
      generationType: generationType,
      startedAt: at,
    );
  }
  late TavernTurnInspection inspection;
  final StoredChat chat;
  final _TurnKind kind;
  final String input;
  final String? nodeId;
  final observers = <StreamController<TavernEvent>>{};
  final TavernModelConfig config;
  final Map<String, Object?> settings;
  final DateTime at;
  final PersonaSelection personaSelection;
  final Map<String, Object?> metadata;
  final String? sourceFile;
  final String? presetId;
  final cancellation = ModelCancellation();
  final done = Completer<void>();
  bool finished = false;
  bool terminal = false;
  bool hasOutput = false;
  bool receivedText = false;
  bool dirty = false;
  String? newUserId;
  StoredNode? originalTarget;
  StoredNode? originalFirstMessage;
  String? expandedFirstMessage;
  bool firstMessageCommitted = false;
  TavernMessage? reply;
  TavernMessage? lastCommitted;
  StringBuffer? text;
  StringBuffer? reasoning;
  TavernUsage? usage;
  String? finishReason;
  Timer? flushTimer;
  String postfix = '';
  Map<String, Object?> variables = {};
  Map<String, Object?> state = {};
  Map<String, Object?> originalVariables = {};
  final previousSelections = <(String, String?)>[];
  _MacroEnvironment? environment;
  bool writeBackAttempted = false;
  state_core.StateDefinition? stateDefinition;
  bool stateAutomatic = false;
  bool stateToolAllowed = false;
  String? stateInvocationId;
  Stopwatch? stateWatch;
  final stateTools = ModelToolAccumulator();
  final statePreparationIssues = <Map<String, Object?>>[];
  final stateOfferedPrompts = <String, String>{};
  final stateSentPrompts = <String>{};
  _StateSettlement? stateAttempt;
  state_core.StateSession? stateSession;
  state_core.StateSecretPrepared? secretPrepared;
  StoredAgentRun? secretCaptured;
  Map<String, Object?>? secretAttempt;
  int? secretCardRevision;
  bool stateSettlementStarted = false;
  final secretIssues = <Map<String, Object?>>[];
  _SecretProtection? secretProtection;
  final secretOffered = <String, Map<String, Object?>>{};
  final secretIncluded = <String>{};
  bool secretRequestAttempted = false;
  bool stateRunsWritten = false;
  StoredAgentRun? directorCaptured;
  _DirectorPrepared? directorPrepared;
  Map<String, Object?>? directorCard;
  state_core.CardEventDefinition? cardEventDefinition;
  final cardEventAuthorizedHandlers = <String>{};
  final cardEventProposals = <state_core.CardEventProposal>[];
  final cardEventPreparationIssues = <Map<String, Object?>>[];
  final cardEventOfferedPrompts = <String, String>{};
  final cardEventSentPrompts = <String>{};
  Map<String, Object?>? cardEventSource;
  String? cardEventInvocationId;
  bool cardEventTerminalEnabled = false;
  String? storyInvocationId;
  _StorySettlement? storyAttempt;
  bool storyRunWritten = false;
  Map<String, Object?> get currentState => {
    ..._copy(state),
    'variables': _copy(variables),
    if (environment != null) 'stChatId': environment!.chatId,
    if (environment != null) 'stChatIdHash': environment!.chatIdHash,
  };
  String get generationType => switch (kind) {
    _TurnKind.send => 'normal',
    _TurnKind.regenerate => 'regenerate',
    _TurnKind.continueReply => 'continue',
    _TurnKind.impersonate => 'impersonate',
  };
  void begin(TavernMessage message) {
    reply = message;
    lastCommitted = message;
    text = StringBuffer(message.text);
    reasoning = StringBuffer(message.reasoning ?? '');
    usage = message.usage;
  }

  void emit(TavernEvent event) {
    if (terminal) return;
    for (final observer in observers) {
      if (!observer.isClosed) observer.add(event);
    }
  }
}

TavernMessage _withReportedUsage(TavernMessage message, TavernUsage? usage) => TavernMessage(
  nodeId: message.nodeId,
  parentId: message.parentId,
  role: message.role,
  speaker: message.speaker,
  text: message.text,
  reasoning: message.reasoning,
  at: message.at,
  siblingIndex: message.siblingIndex,
  siblingCount: message.siblingCount,
  hidden: message.hidden,
  usage: message.usage,
  reportedUsage: usage,
);

class _MacroEnvironment {
  _MacroEnvironment(
    this.card,
    this.settings,
    this.local,
    this.global,
    this.history,
    this.config,
    this.now,
    this.random,
    this.chatId,
    this.input,
    this.generationType, {
    this.chatIdHash,
    this.pickRerollSeed,
    this.characterId = '',
    ChatPreset? preset,
  }) {
    final raw = _map(settings['preset']);
    _presetSettings = (preset ?? (raw.isEmpty ? ChatPreset.stDefault() : ChatPreset(raw))).settings;
  }
  final Map<String, Object?> card;
  final Map<String, Object?> settings;
  final Map<String, Object?> local;
  final Map<String, Object?> global;
  final List<StoredNode> history;
  final TavernModelConfig config;
  final DateTime now;
  final double Function() random;
  final String chatId;
  num? chatIdHash;
  final Object? pickRerollSeed;
  final String characterId;
  final String input;
  final String generationType;
  final outlets = <String, String>{};
  late final Map<String, Object?> _presetSettings;
  late final RegexEngine regex = RegexEngine(
    globalScripts: [
      ...RegexEngine.readScripts(settings['globalRegexScripts'] ?? settings['regex']),
      ...RegexEngine.readScripts(settings['managedRegexScripts']),
    ],
    presetScripts: settings['presetRegexEnabled'] == false
        ? const []
        : RegexEngine.readScripts(_map(_presetSettings['extensions'])['regex_scripts']),
    characterScripts:
        settings['characterRegexEnabled'] == false || _strings(settings['disabledCharacterRegex']).contains(characterId)
        ? const []
        : RegexEngine.readScripts(_map(card['extensions'])['regex_scripts']),
    enabled: settings['regexEnabled'] != false,
  );

  bool get legacy =>
      settings['macroEngine'] == 'legacy' ||
      (settings['macroEngine'] == null && settings['experimental_macro_engine'] == false);
  String get userName => settings['userName'] is String ? settings['userName'] as String : 'User';
  String get persona => _string(settings['persona']);
  int get maxContext => presetNumber(_presetSettings['openai_max_context'], 4095).toInt();
  int get maxResponse => presetNumber(_presetSettings['openai_max_tokens'], 300).toInt();

  String expand(String text, Map<String, String> overrides) => _expand(text, overrides, true);
  String baseExpand(String text, Map<String, String> overrides) => _expand(text, overrides, false);
  String regexExpand(String text, {String? characterOverride, Object? Function(Object?)? postProcess}) =>
      _expand(text, const {}, true, characterOverride: characterOverride, postProcess: postProcess);

  late final MacroContext _context = MacroContext(
    localVariables: local,
    globalVariables: global,
    card: card,
    userName: userName,
    persona: persona,
    history: _MacroHistory(history),
    model: config.model,
    input: input,
    maxContext: maxContext,
    maxResponse: maxResponse,
    lastGenerationType: generationType,
    now: now,
    timeZoneOffset: now.timeZoneOffset,
    locale: _string(settings['locale']).isEmpty ? 'en' : _string(settings['locale']),
    random: random,
    chatId: chatId,
    chatIdHash: chatIdHash,
    onChatIdHash: (value) {
      if (chatIdHash == null || (legacy && chatIdHash == 0)) chatIdHash = value;
    },
    pickRerollSeed: pickRerollSeed,
    outlets: outlets,
    extensions: _strings(settings['extensions']).toSet(),
    preferCharacterPrompt: _presetSettings['prefer_character_prompt'] != false,
    preferCharacterJailbreak: _presetSettings['prefer_character_jailbreak'] != false,
    collapseNewlines: settings['collapseNewlines'] == true,
    systemPromptOverride: settings['systemPromptOverride'] as String?,
    scenarioOverride: settings['scenarioOverride'] as String?,
    mesExamplesOverride: settings['mesExamplesOverride'] as String?,
  );

  String _expand(
    String text,
    Map<String, String> overrides,
    bool replaceCard, {
    String? characterOverride,
    Object? Function(Object?)? postProcess,
  }) {
    return legacy
        ? const LegacyMacroEngine().expand(
            text,
            _context,
            overrides: overrides,
            postProcess: postProcess,
            replaceCharacterCard: replaceCard,
            characterOverride: characterOverride,
          )
        : const MacroEngine().expand(
            text,
            _context,
            overrides: overrides,
            postProcess: postProcess,
            replaceCharacterCard: replaceCard,
            characterOverride: characterOverride,
          );
  }
}

/// A turn keeps its stored-node list live as input, greeting and write-back
/// preparation append or replace nodes. Project each unchanged node once, not
/// the entire path on every macro call. Rollback is visible by node identity.
class _MacroHistory extends ListBase<MacroMessage> {
  _MacroHistory(this._nodes);
  final List<StoredNode> _nodes;
  final _cache = <({StoredNode node, MacroMessage message})?>[];

  @override
  int get length => _nodes.length;
  @override
  set length(int value) => throw UnsupportedError('Macro history is read-only.');

  @override
  MacroMessage operator [](int index) {
    RangeError.checkValidIndex(index, _nodes);
    if (_cache.length != _nodes.length) _cache.length = _nodes.length;
    final node = _nodes[index];
    final cached = _cache[index];
    if (cached != null && identical(cached.node, node)) return cached.message;
    final message = MacroMessage(
      text: node.message.text,
      isUser: node.message.role == TavernRole.user,
      isSystem: node.message.hidden || _systemMessage(node),
      swipeId: node.message.siblingIndex,
      swipeCount: node.message.siblingCount,
      sentAt: node.message.at,
    );
    _cache[index] = (node: node, message: message);
    return message;
  }

  @override
  void operator []=(int index, MacroMessage value) => throw UnsupportedError('Macro history is read-only.');
}

class _ConfiguredInjection {
  const _ConfiguredInjection(this.injection, {this.scan = false, this.authorNote = false});
  final PromptInjection injection;
  final bool scan;
  final bool authorNote;
}

List<_ConfiguredInjection> _configuredInjections(
  Map<String, Object?> settings,
  PreparedCharacterFields prepared,
  Map<String, Object?> card, {
  required int userMessageCount,
}) {
  final result = <_ConfiguredInjection>[];
  final note = _map(settings['authorNote']);
  final interval = note['interval'];
  final noteDue =
      interval == null ||
      interval == 1 ||
      (interval is num && interval > 0 && userMessageCount > 0 && userMessageCount % interval == 0);
  if (note.isNotEmpty && note['enabled'] != false && noteDue) {
    result.add(
      _ConfiguredInjection(
        _injection(note, '2_floating_prompt', kind: 'authorNote'),
        scan: note['scan'] == true,
        authorNote: true,
      ),
    );
  }
  final depth = _map(_map(card['extensions'])['depth_prompt']);
  if (prepared['charDepthPrompt'].isNotEmpty) {
    result.add(
      _ConfiguredInjection(
        PromptInjection(
          fragment: PromptFragment(prepared['charDepthPrompt'], const PromptSource('card', 'DEPTH_PROMPT')),
          depth: _injectionDepth(depth['depth']),
          role: _role(depth['role']),
        ),
        scan: settings['scanDepthPrompt'] == true,
      ),
    );
  }
  final injections = settings['injections'];
  if (injections is List<Object?>) {
    for (var index = 0; index < injections.length; index++) {
      final value = injections[index];
      if (value is! Map<String, Object?> || value['enabled'] == false) continue;
      final id = _string(value['id']);
      result.add(
        _ConfiguredInjection(_injection(value, id.isEmpty ? 'custom-$index' : id), scan: value['scan'] == true),
      );
    }
  }
  return result;
}

PromptInjection _injection(Map<String, Object?> value, String id, {String kind = 'extension'}) => PromptInjection(
  fragment: PromptFragment(_string(value['content']), PromptSource(kind, id)),
  role: _role(value['role']),
  depth: _injectionDepth(value['depth']),
  order: _integer(value['order'], 100),
  placement: switch (value['placement']) {
    'beforeMain' => PromptPlacement.beforeMain,
    'afterMain' => PromptPlacement.afterMain,
    _ => PromptPlacement.inChat,
  },
);

List<PromptInjection> _finishInjections(
  List<_ConfiguredInjection> initial,
  WorldInfoResult world, {
  bool deepseek = false,
}) {
  final result = <PromptInjection>[];
  for (final item in initial) {
    final injection = item.injection;
    if (!item.authorNote) {
      result.add(injection);
      continue;
    }
    final before = world.authorNoteBefore.map((hit) => hit.content).join('\n');
    final after = world.authorNoteAfter.map((hit) => hit.content).join('\n');
    // ST removes one leading/trailing newline, not arbitrary whitespace.
    final content = '$before\n${injection.fragment.content}\n$after'.replaceAll(RegExp(r'(^\n)|(\n$)'), '');
    result.add(
      PromptInjection(
        fragment: PromptFragment(
          content,
          PromptSource(
            'authorNote',
            injection.fragment.source.id,
            details: {
              'worldInfo': [
                for (final hit in [...world.authorNoteBefore, ...world.authorNoteAfter]) _worldSource(hit).toJson(),
              ],
            },
          ),
        ),
        placement: injection.placement,
        role: injection.role,
        depth: injection.depth,
        order: injection.order,
        fragments: [...world.authorNoteBefore, ...world.authorNoteAfter].any(_decoratedWorldHit)
            ? [
                ...world.authorNoteBefore.map(_worldFragment),
                injection.fragment,
                ...world.authorNoteAfter.map(_worldFragment),
              ]
            : const [],
      ),
    );
  }
  for (final depth in world.depths) {
    // Only explicit V3 prefill entries move to the tail. Native entries in
    // the same depth/role group keep ST's original depth-injection ordering.
    final entries = deepseek ? depth.entries.where((hit) => !_worldPrefill(hit)).toList() : depth.entries;
    if (entries.isEmpty) continue;
    result.add(
      PromptInjection(
        fragment: PromptFragment(
          entries.map((hit) => hit.content).join('\n'),
          PromptSource(
            'worldInfo',
            'customDepthWI_${depth.depth}_${depth.role}',
            details: {'entries': entries.map((hit) => _worldSource(hit).toJson()).toList()},
          ),
        ),
        depth: depth.depth,
        role: _role(depth.role),
        v3Depth: entries.any((hit) => hit.depthOverride != null),
        fragments: entries.any(_decoratedWorldHit) ? entries.map(_worldFragment).toList() : const [],
      ),
    );
  }
  return result;
}

bool _worldPrefill(WorldInfoHit hit) => hit.assistantPrefill;

bool _decoratedWorldHit(WorldInfoHit hit) => hit.roleOverride != null || hit.ignoreOnMaxContext;

PromptFragment _worldFragment(WorldInfoHit hit) => PromptFragment(
  hit.content,
  _worldSource(hit),
  role: hit.roleOverride == null ? null : _role(hit.roleOverride),
  trimOnOverflow: hit.ignoreOnMaxContext,
);
Map<String, Object?> _worldInfoTrace(
  WorldInfoResult world, {
  List<WorldInfoHit> preparedUiHits = const [],
  List<Map<String, Object?>> missingBooks = const [],
}) => _copy({
  if (missingBooks.isNotEmpty) 'missing': missingBooks,
  if (world.regexDiagnostics.isNotEmpty)
    'regexDiagnostics': [for (final value in world.regexDiagnostics) value.toJson()],
  if (world.externalActivations.isNotEmpty)
    'externalActivations': [for (final value in world.externalActivations) value.toJson()],
  if (world.externalActivationsOmitted != 0) 'externalActivationsOmitted': world.externalActivationsOmitted,
  'budget': world.budget,
  'overflowed': world.overflowed,
  'scanRounds': world.scanRounds,
  'activated': [
    for (final hit in world.activated)
      {
        'bookId': hit.bookId,
        'uid': hit.uid,
        'source': hit.source.name,
        'reason': hit.reason,
        'content': hit.content,
        'originalContent': hit.originalContent,
        'order': hit.order,
        'position': hit.position,
        'depth': hit.depth,
        'role': hit.role,
        'section': hit.section,
        'outlet': hit.entry.outlet,
        'phase': hit.phase.name,
        'round': hit.round,
        'primaryKey': hit.primaryKey,
        'secondaryMatches': hit.secondaryMatches,
        'probabilityRoll': hit.probabilityRoll,
        'ignoreOnMaxContext': hit.ignoreOnMaxContext,
        'disabledUiPrompt': hit.disabledUiPrompt,
        'unappliedDecorators': [
          if (hit.position == 7 && hit.section == null) ...[
            if (hit.roleOverride != null) 'role',
            if (hit.ignoreOnMaxContext) 'ignore_on_max_context',
          ],
        ],
      },
  ],
  'preparedEffects': [
    for (final hit in preparedUiHits)
      {
        'kind': 'disable_ui_prompt',
        'prompt': hit.disabledUiPrompt,
        'stage': 'before-assembly',
        'source': _worldSource(hit).toJson(),
        'contentRetained': world.activated.any((retained) => retained.entry.identity == hit.entry.identity),
      },
  ],
});

PromptSource _worldSource(WorldInfoHit hit) => PromptSource(
  'worldInfo',
  '${hit.bookId}:${hit.uid}',
  label: hit.entry.comment,
  details: {
    'bookId': hit.bookId,
    'uid': hit.uid,
    'source': hit.source.name,
    'order': hit.order,
    'reason': hit.reason,
    'originalContent': hit.originalContent,
  },
);

bool _systemMessage(StoredNode node) => node.message.role == TavernRole.system || node.original['is_system'] == true;

// ST script.js prepares body regex oldest-first, then reasoning newest-first.
// The latter visits the latest eligible message even when add_to_prompts=false;
// a continuation's existing reasoning prefix remains available in that case.
List<StoredNode> _preparePromptHistory(
  List<StoredNode> history,
  _MacroEnvironment environment, {
  required bool continuing,
}) {
  final visible = history.where((node) => !node.message.hidden && !_systemMessage(node)).toList();
  final transformed = <StoredNode>[];
  for (var index = 0; index < visible.length; index++) {
    final node = visible[index];
    final depth = visible.length - index - (continuing ? 2 : 1);
    final text = environment.regex.apply(
      node.message.text,
      placement: node.message.role == TavernRole.user ? RegexPlacement.userInput : RegexPlacement.aiOutput,
      phase: RegexPhase.prompt,
      depth: depth,
      expand: environment.regexExpand,
    );
    transformed.add(_nodeWithText(node, text));
  }
  final options = _map(environment.settings['reasoning']);
  final add = options['add_to_prompts'] == true;
  final maximum = _finiteNumber(options['max_additions']) ?? 1;
  var additions = 0;
  for (var index = transformed.length - 1; index >= 0; index--) {
    final node = transformed[index];
    final depth = transformed.length - index - (continuing ? 2 : 1);
    final reasoning = environment.regex.apply(
      node.message.reasoning ?? '',
      placement: RegexPlacement.reasoning,
      phase: RegexPhase.prompt,
      depth: depth,
      expand: environment.regexExpand,
    );
    final prefixMessage = continuing && index == transformed.length - 1;
    if ((prefixMessage || (add && additions < maximum)) && reasoning.isNotEmpty && reasoning != '\u200B') {
      additions++;
      final prefix = environment.expand(_string(options['prefix'] ?? '<think>'), const {});
      final separator = environment.expand(_string(options['separator'] ?? '\n'), const {});
      final suffix = environment.expand(_string(options['suffix'] ?? '</think>'), const {});
      final text = prefixMessage && node.message.text.isEmpty
          ? '$prefix$reasoning'
          : '$prefix$reasoning$suffix$separator${node.message.text}';
      transformed[index] = _nodeWithText(node, text);
    }
    if (!add || additions >= maximum) break;
  }
  final byId = {for (final node in transformed) node.message.nodeId: node};
  return [for (final node in history) byId[node.message.nodeId] ?? node];
}

Set<String> _availableWorldSections(ChatPreset preset, String generationType) {
  final settings = preset.settings;
  final definitions = (settings['prompts']! as List<Object?>).whereType<Map<String, Object?>>();
  final groups = (settings['prompt_order']! as List<Object?>).whereType<Map<String, Object?>>();
  final order = groups.firstWhere((group) => '${group['character_id']}' == '100001')['order']! as List<Object?>;
  final enabled = <String>{};
  for (final entry in order.whereType<Map<String, Object?>>()) {
    if (entry['enabled'] != true) continue;
    final definition = definitions.where((item) => item['identifier'] == entry['identifier']).firstOrNull;
    if (definition == null) continue;
    final triggers = definition['injection_trigger'];
    if (triggers is List<Object?> && triggers.isNotEmpty && !triggers.contains(generationType)) continue;
    if (entry['identifier'] == 'charPersonality') enabled.add('personality');
    if (entry['identifier'] == 'scenario') enabled.add('scenario');
  }
  return enabled;
}

num? _finiteNumber(Object? value) => value is num && value.isFinite ? value : null;

Map<String, Object?> _emptyChatState(Map<String, Object?> metadata) => {
  'variables': _map(metadata['variables']),
  for (final key in const ['timedWorldInfo', 'decoratorState', 'greetingIndex'])
    if (metadata.containsKey(key)) key: _runtimeValue(metadata[key]),
  'stChatIdHash': _finiteNumber(metadata['chat_id_hash']),
};

Map<String, Object?> _runtimeMetadata(Map<String, Object?> metadata, Map<String, Object?> state) {
  final result = _copy(metadata);
  for (final key in const ['timedWorldInfo', 'decoratorState', 'greetingIndex']) {
    if (state.containsKey(key)) {
      result[key] = _runtimeValue(state[key]);
    } else {
      result.remove(key);
    }
  }
  if (state.containsKey('stChatIdHash')) {
    final hash = _finiteNumber(state['stChatIdHash']);
    if (hash == null) {
      result.remove('chat_id_hash');
    } else {
      result['chat_id_hash'] = hash;
    }
  }
  return result;
}

String _macroChatIdentity(
  StoredChat chat,
  Map<String, Object?> state,
  Map<String, Object?> metadata,
  String? sourceFile, {
  StoredNode? node,
}) {
  if (state['stChatId'] case final String value) return value;
  final own = _map(_map(chat.metadata['dshgo'])['chatJsonl']);
  final files = own['files'] is List<Object?>
      ? (own['files']! as List<Object?>).whereType<Map<String, Object?>>()
      : const Iterable<Map<String, Object?>>.empty();
  final nodeOwn = _map(_map(node?.extra['dshgo'])['chatJsonl']);
  final originalName = nodeOwn['sourceFileName'];
  Map<String, Object?>? file = files.where((item) => item['key'] == sourceFile).firstOrNull;
  file ??= files.where((item) => originalName is String && item['fileName'] == originalName).firstOrNull;
  if (file == null && node != null) {
    file = files
        .where(
          (item) => item['path'] is List<Object?> && (item['path']! as List<Object?>).contains(node.message.nodeId),
        )
        .firstOrNull;
  }
  if (file != null) {
    final header = _map(file['header']);
    final originalMetadata = _map(header['chat_metadata']);
    if (originalMetadata['main_chat'] case final String identity) return identity;
    final label = _map(_map(originalMetadata['dshgo'])['chatJsonl'])['sourceFileName'] ?? file['fileName'];
    if (label is String) return _chatLabel(label);
  }
  if (metadata['main_chat'] case final String identity) return identity;
  final oldMetadata = _map(_map(nodeOwn['sourceHeader'])['chat_metadata']);
  if (oldMetadata['main_chat'] case final String identity) return identity;
  if (originalName is String) return _chatLabel(originalName);
  return sourceFile == null ? chat.id : _chatLabel(sourceFile);
}

String _chatLabel(String fileName) {
  final label = fileName.replaceAll('\\', '/').split('/').last;
  return label.toLowerCase().endsWith('.jsonl') ? label.substring(0, label.length - 6) : label;
}

StoredNode _nodeWithText(StoredNode node, String text) {
  final value = node.message;
  return StoredNode(
    message: TavernMessage(
      nodeId: value.nodeId,
      parentId: value.parentId,
      role: value.role,
      speaker: value.speaker,
      text: text,
      reasoning: value.reasoning,
      at: value.at,
      siblingIndex: value.siblingIndex,
      siblingCount: value.siblingCount,
      hidden: value.hidden,
      usage: value.usage,
      reportedUsage: value.reportedUsage,
    ),
    depth: node.depth,
    selectedChildId: node.selectedChildId,
    extra: node.extra,
    original: node.original,
  );
}

PromptHistoryMessage _promptHistory(StoredNode node) => PromptHistoryMessage(
  id: node.message.nodeId,
  role: switch (node.message.role) {
    TavernRole.user => 'user',
    TavernRole.character => 'assistant',
    TavernRole.narrator => 'narrator',
    TavernRole.system => 'system',
  },
  content: node.message.text,
  name: node.message.speaker,
  hidden: node.message.hidden,
  isSystem: node.original['is_system'] == true,
  forceAvatar: _jsTruthy(node.original['force_avatar']),
  toolCalls: node.original['tool_calls'] is List<Object?>
      ? (node.original['tool_calls'] as List<Object?>).whereType<Map<String, Object?>>().map(_copy).toList()
      : null,
  toolCallId: node.original['tool_call_id'] as String?,
);

Map<String, Object?> _decodeObject(String text, String description) {
  final value = jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
  if (value is! Map<String, Object?>) throw FormatException('$description must be a JSON object.');
  return value;
}

// Variable arithmetic follows JS Number, including non-finite values. JS
// JSON.stringify writes those as null; keep that boundary in both SQLite and
// settings rather than letting a legal macro poison every subsequent turn.
Object? _jsonCompatible(Object? value) {
  if (value is num && !value.isFinite) return null;
  if (value is List<Object?>) return value.map(_jsonCompatible).toList();
  if (value is Map<String, Object?>) {
    return {for (final entry in value.entries) entry.key: _jsonCompatible(entry.value)};
  }
  return value;
}

String _jsonString(Map<String, Object?> value) => jsonEncode(_jsonCompatible(value));
Map<String, Object?> _copy(Map<String, Object?> value) => jsonDecode(_jsonString(value)) as Map<String, Object?>;
Object? _runtimeValue(Object? value) {
  if (value is List<Object?>) return value.map(_runtimeValue).toList();
  if (value is Map<String, Object?>) return _runtimeCopy(value);
  return value;
}

Map<String, Object?> _runtimeCopy(Map<String, Object?> value) => {
  for (final entry in value.entries) entry.key: _runtimeValue(entry.value),
};
bool _jsTruthy(Object? value) =>
    value != null && value != false && value != '' && !(value is num && (value == 0 || value.isNaN));
Map<String, Object?> _personaSettings(Map<String, Object?> settings, PersonaSelection selection) {
  final persona = selection.persona;
  if (persona == null) return settings;
  return {...settings, 'userName': persona.name, 'persona': persona.description, 'personaInPrompt': persona.inPrompt};
}

// ST public/script.js getCharacterCardFields and scripts/authors-note.js
// loadSettings/setFloatingPrompt, fixed 1.19.0 commit cited at the file top.
// These values are projected from the selected source, not copied into every
// branch's mutable chat settings. Explicit local settings are merged last.
Map<String, Object?> _chatMetadataSettings(
  Map<String, Object?> metadata,
  Map<String, Object?> lorebookIds,
  Map<String, Object?> defaultNote,
) {
  final result = <String, Object?>{};
  for (final entry in const {
    'scenario': 'scenarioOverride',
    'system_prompt': 'systemPromptOverride',
    'mes_example': 'mesExamplesOverride',
  }.entries) {
    final value = metadata[entry.key];
    if (value is String) result[entry.value] = value;
  }
  const noteKeys = ['note_prompt', 'note_interval', 'note_depth', 'note_position', 'note_role'];
  if (noteKeys.any(metadata.containsKey)) {
    final position = metadata['note_position'];
    final placement = position == null
        ? defaultNote['placement'] ?? 'inChat'
        : switch (position) {
            2 => 'beforeMain',
            0 => 'afterMain',
            _ => 'inChat',
          };
    result['authorNote'] = {
      'content': metadata['note_prompt'] ?? defaultNote['content'] ?? '',
      'interval': metadata['note_interval'] ?? defaultNote['interval'] ?? 1,
      'depth': metadata['note_depth'] ?? defaultNote['depth'] ?? 4,
      'placement': placement,
      'role': metadata['note_role'] == null ? defaultNote['role'] ?? 'system' : _role(metadata['note_role']),
      'enabled': position == null || position == 0 || position == 1 || position == 2,
    };
  }
  if (metadata.containsKey('world_info')) {
    final name = metadata['world_info'];
    final mapped = name is String ? lorebookIds[name] : null;
    result['lorebooks'] = {
      'chat': [if (mapped is String) mapped],
    };
  }
  return result;
}

Map<String, Object?> _effectiveCard(Map<String, Object?> raw, Map<String, Object?> settings) {
  final card = _copy(raw);
  for (final key in const {
    'scenarioOverride': 'scenario',
    'systemPromptOverride': 'system_prompt',
    'mesExamplesOverride': 'mes_example',
  }.entries) {
    final value = settings[key.key];
    if (value is String && value.isNotEmpty) card[key.value] = value;
  }
  return card;
}

Map<String, Object?> _map(Object? value) => value is Map<String, Object?> ? _copy(value) : <String, Object?>{};
Map<String, Object?> _merge(Map<String, Object?> base, Map<String, Object?> patch) {
  final result = _copy(base);
  for (final entry in _copy(patch).entries) {
    final previous = result[entry.key];
    result[entry.key] = previous is Map<String, Object?> && entry.value is Map<String, Object?>
        ? _merge(previous, entry.value! as Map<String, Object?>)
        : entry.value;
  }
  return result;
}

String _string(Object? value) => value is String ? value : '';
List<String> _strings(Object? value) => value is List<Object?> ? value.whereType<String>().toList() : <String>[];
int _integer(Object? value, int fallback) => value is num && value.isFinite ? value.toInt() : fallback;
// An invalid in-chat depth remains non-injectable. In particular 4.5 must not
// silently become depth 4. The -1 sentinel is rejected by PromptAssembler but
// retains the extension's independent scan flag for world-info scanning.
int _injectionDepth(Object? value) {
  if (value == null) return 4;
  if (value is! num || !value.isFinite || value != value.truncateToDouble() || value < 0 || value > 10000) return -1;
  return value.toInt();
}

Map<String, Object?> _characterIdentity(Map<String, Object?> settings, String characterId) =>
    _merge(_map(_map(settings['characterIdentities'])[characterId]), _map(settings['characterIdentity']));
String _characterFilename(Map<String, Object?> settings, String characterId) {
  final filename = _string(_characterIdentity(settings, characterId)['avatarFilename']);
  final extension = filename.lastIndexOf('.');
  return extension > 0 ? filename.substring(0, extension) : filename;
}

List<String>? _characterTags(Map<String, Object?> settings, String characterId) {
  final value = _characterIdentity(settings, characterId)['tagIds'];
  return value is List<Object?> ? _strings(value) : null;
}

String _role(Object? value) => switch (value) {
  1 || 'user' => 'user',
  2 || 'assistant' => 'assistant',
  _ => 'system',
};
void _requireBookId(String id) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(id)) {
    throw ArgumentError.value(id, 'id', 'Use a filename-safe lorebook id.');
  }
}

String _safeDetail(Object error) => error is TavernImportError
    ? error.message
    : error is PromptBudgetExceeded
    ? error.toString()
    : 'turn_failed (${error.runtimeType})';
String _plainText(String text) => text
    .replaceAll(RegExp(r'<(?:script|style)\b[^>]*>[\s\S]*?</(?:script|style)>', caseSensitive: false), '')
    .replaceAll(RegExp(r'</?[A-Za-z][^>]*>'), '')
    .replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (match) => match[1]!)
    .replaceAll(RegExp(r'(^|\n)\s{0,3}(?:#{1,6}\s+|>\s*|[-*+]\s+)'), ' ')
    .replaceAll(RegExp(r'[`*_~]'), '')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
