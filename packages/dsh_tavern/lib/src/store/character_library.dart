// Uses the staging/rename and serialized-operation approach of
// app/lib/pets/pet_library.dart at dsh-Go 1c5b220093295f8d069f6bfb06d8b4fc97b9e9c2.
// Pure Dart: the Flutter provider and image work stay outside the UI isolate.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import '../api.dart';
import '../import_report.dart';
import '../io/card_codec.dart';
import '../regex_library.dart';
import '../worldinfo/world_info.dart';

class StoredCharacter {
  const StoredCharacter({
    required this.id,
    required this.card,
    required this.importedAt,
    this.avatarPath,
    this.directoryPath,
  });

  final String id;
  final TavernCard card;
  final DateTime importedAt;
  final String? avatarPath;

  /// The published character directory, used only for runtime asset paths.
  /// It is never written into the card, library metadata or summary index.
  final String? directoryPath;

  TavernCharacter toCharacter({
    int chatCount = 0,
    DateTime? lastChatAt,
    String? language,
    List<TavernRegexDiagnostic> regexDiagnostics = const [],
  }) => card.toCharacter(
    id,
    importedAt: importedAt,
    avatarPath: avatarPath,
    resolveAssetPath: _resolveAssetPath,
    chatCount: chatCount,
    lastChatAt: lastChatAt,
    language: language,
    regexDiagnostics: regexDiagnostics,
  );

  String? _resolveAssetPath(String uri) {
    final directory = directoryPath;
    if (directory == null) {
      return null;
    }
    if (uri == 'ccdefault:') {
      return card.png == null ? null : '$directory/source.png';
    }
    final path = embeddedCardAssetPath(uri) ?? (isSafeCardAssetPath(uri) ? uri : null);
    if (path == null || !card.assets.containsKey(path)) {
      return null;
    }
    return '$directory/resources/$path';
  }
}

/// The small, immutable projection used by character lists. Full card text,
/// original bytes, resource bytes and compatibility reports are read on demand.
class StoredCharacterSummary {
  StoredCharacterSummary({
    required this.id,
    required this.name,
    required List<String> tags,
    required this.importedAt,
    required this.regexCount,
    required this.scriptCount,
    required this.hasLorebook,
    this.nickname,
    this.creator,
    this.avatarPath,
  }) : tags = List.unmodifiable(tags);

  final String id;
  final String name;
  final String? nickname;
  final String? creator;
  final List<String> tags;
  final String? avatarPath;
  final DateTime importedAt;
  final int regexCount;
  final int scriptCount;
  final bool hasLorebook;

  /// Detail-only fields keep their empty defaults; use [CharacterLibrary.read]
  /// for description, greetings, creator notes, theme or declared assets.
  TavernCharacter toCharacter({int chatCount = 0, DateTime? lastChatAt}) => TavernCharacter(
    id: id,
    name: name,
    nickname: nickname,
    creator: creator,
    tags: tags,
    avatarPath: avatarPath,
    importedAt: importedAt,
    regexCount: regexCount,
    scriptCount: scriptCount,
    hasLorebook: hasLorebook,
    chatCount: chatCount,
    lastChatAt: lastChatAt,
  );
}

/// File-backed character library. [root] is `<app support>/tavern`.
///
/// Each import creates a new id. A complete directory is published by rename,
/// so interrupted writes never become visible as a half-imported character.
/// Only one instance should own a root, just as one Tavern owns the app store.
class CharacterLibrary {
  CharacterLibrary(this.root, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// Allows nullable facade lookups to reject unknown identifiers without
  /// opening paths. Strict file operations still call [_requireId].
  static bool isValidId(String id) => _idPattern.hasMatch(id);

  final Directory root;
  final DateTime Function() _now;
  Future<void> _queue = Future.value();

  Directory get _characters => Directory('${root.path}/characters');
  Directory get _indexes => Directory('${root.path}/character-index');
  File _indexFile(String id) => File('${_indexes.path}/$id.json');

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final run = _queue.then((_) => action());
    _queue = run.then((_) {}, onError: (Object _, StackTrace _) {});
    return run;
  }

  Future<StoredCharacter> importCard(
    Uint8List bytes, {
    String? fileName,
    Future<void> Function(TavernCard card)? beforeSave,
    Future<TavernImportReport> Function(TavernCard card)? inspect,
  }) => _exclusive(() async {
    await _tidy();
    // Decode/ZIP inflate/portrait conversion cannot stall Flutter's isolate.
    final decoded = await _decodeImport(bytes);
    final (card, portrait) = decoded;
    await beforeSave?.call(card);
    final report = await inspect?.call(card);
    final importedAt = _now().toUtc();
    final id = _newId();
    final staging = await _characters.createTemp('.staging-');
    final destination = Directory('${_characters.path}/$id');
    try {
      await File('${staging.path}/card.json').writeAsString(jsonEncode(card.json), flush: true);
      if (report != null) {
        await File('${staging.path}/import-report.json').writeAsString(jsonEncode(report.toJson()), flush: true);
      }
      // Keep the source from this decode, even if the caller reuses its input
      // buffer while the completed card is being inspected or published.
      await File('${staging.path}/original.${card.sourceFormat.name}').writeAsBytes(card.originalBytes!, flush: true);
      if (card.png != null) await File('${staging.path}/source.png').writeAsBytes(card.png!, flush: true);
      if (portrait != null) await File('${staging.path}/portrait.png').writeAsBytes(portrait, flush: true);
      for (final entry in card.assets.entries) {
        if (!isSafeCardAssetPath(entry.key)) throw const TavernImportError('角色卡资源路径无效。');
        final file = File('${staging.path}/resources/${entry.key}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value, flush: true);
      }
      await File('${staging.path}/library.json').writeAsString(
        jsonEncode({
          'version': 1,
          'importedAt': importedAt.toIso8601String(),
          'sourceFormat': card.sourceFormat.name,
          'sourceFileName': fileName,
          'hasPng': card.png != null,
          'hasPortrait': portrait != null,
          'resources': card.assets.keys.toList(),
        }),
        flush: true,
      );
      // Never overwrite an existing import, even on a random-id collision.
      if (await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.notFound) {
        throw const FileSystemException('Character id already exists');
      }
      // An orphaned derived index must never describe a new import, even if a
      // random id happens to be reused. Invalidate before publishing the card.
      await _invalidateSummary(id);
      await staging.rename(destination.path);
    } finally {
      if (await staging.exists()) await _discard(staging);
    }
    final record = StoredCharacter(
      id: id,
      card: card,
      importedAt: importedAt,
      avatarPath: portrait == null ? null : '${destination.path}/portrait.png',
      directoryPath: destination.absolute.path,
    );
    await _writeSummary(_summarize(record));
    return record;
  });

  Future<StoredCharacter?> read(String id) => _exclusive(() async {
    _requireId(id);
    await _tidy();
    return _read(id);
  });

  Future<TavernImportReport?> readImportReport(String id) => _exclusive(() async {
    _requireId(id);
    await _tidy();
    final directory = Directory('${_characters.path}/$id');
    final type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) throw const FileSystemException('Character folder is not a directory');
    final file = File('${_characters.path}/$id/import-report.json');
    if (!await file.exists()) return null;
    final report = TavernImportReport.fromJson(jsonDecode(await file.readAsString()) as Map<String, Object?>);
    if (report.kind != TavernImportKind.character) throw const FormatException('Invalid character import report.');
    // Staleness needs JSON and the resource manifest, not original/portrait or
    // embedded file bytes. Opening the report must not load every card asset.
    final json = jsonDecode(await File('${directory.path}/card.json').readAsString()) as Map<String, Object?>;
    final metadata = jsonDecode(await File('${directory.path}/library.json').readAsString()) as Map<String, Object?>;
    if (metadata['version'] != 1 || metadata['resources'] is! List<Object?>) {
      throw const TavernImportError('资料库元数据无效。');
    }
    final resources = (metadata['resources']! as List<Object?>).cast<String>();
    return report.withStale(
      report.fingerprint != importFingerprint(TavernImportKind.character, json, embeddedAssetPaths: resources),
    );
  });

  /// The same queue protects edits/deletion and the inspected snapshot, so a
  /// slow compatibility probe cannot publish a report for a newer revision.
  Future<TavernImportReport> recheckImport(String id, Future<TavernImportReport> Function(TavernCard card) inspect) =>
      _exclusive(() async {
        _requireId(id);
        await _tidy();
        final record = await _read(id);
        if (record == null) throw const TavernImportError('角色不存在。');
        final report = await inspect(record.card);
        final file = File('${_characters.path}/$id/import-report.json');
        final pending = File('${file.path}.writing');
        try {
          await pending.writeAsString(jsonEncode(report.toJson()), flush: true);
          await pending.rename(file.path);
        } finally {
          if (await pending.exists()) await pending.delete();
        }
        return report;
      });

  /// Returns the complete V3 `data` object, detached from the stored card.
  /// Unknown and read-only fields stay available to a character editor.
  Future<Map<String, Object?>?> readFields(String id) async {
    final record = await read(id);
    if (record == null) return null;
    return jsonDecode(jsonEncode(record.card.data)) as Map<String, Object?>;
  }

  /// Changes only the supplied editable fields. Empty strings/lists clear a
  /// field; null, unknown keys and values of the wrong type are rejected.
  ///
  /// A nonempty patch updates `modification_date` in Unix seconds. An empty
  /// patch reads the existing record without rewriting it. The original
  /// import, portrait, resources, metadata and every other JSON value remain
  /// intact. Publish the complete JSON by rename so an interrupted write
  /// cannot expose a truncated card.
  Future<StoredCharacter> updateFields(String id, Map<String, Object?> fields) async {
    _requireId(id);
    // Snapshot and validate before queueing: callers may reuse their form map.
    final updates = _fieldUpdates(fields);
    return _exclusive(() async {
      await _tidy();
      final record = await _read(id);
      if (record == null) throw const TavernImportError('角色不存在。');
      if (updates.isEmpty) return record;
      final json = jsonDecode(jsonEncode(record.card.json)) as Map<String, Object?>;
      final data = json['data'] as Map<String, Object?>;
      data.addAll(updates);
      return _saveCard(record, json);
    });
  }

  /// Adds one CC book entry, assigning an unused integer id. Input is copied
  /// before queueing. The caller cannot supply `id`; omitted known fields use
  /// ordinary CC defaults. A missing book starts with an empty entries array.
  Future<StoredCharacter> addBookEntry(String id, Map<String, Object?> entry) async {
    _requireId(id);
    final updates = _bookEntryUpdates(entry);
    return _editBook(id, (entries) {
      entries.add({
        'id': _nextBookEntryId(entries),
        'keys': <String>[],
        'secondary_keys': <String>[],
        'content': '',
        'enabled': true,
        'constant': false,
        'selective': false,
        'insertion_order': 100,
        'position': 'before_char',
        'use_regex': false,
        'extensions': <String, Object?>{},
        ...updates,
      });
      return true;
    });
  }

  /// Patches the entry at its stored array [index], not its potentially
  /// duplicate id. Extensions merge recursively; other supplied fields
  /// replace their old value. Unknown omitted JSON values remain intact.
  /// An empty patch validates the target and returns the unchanged character
  /// without writing.
  Future<StoredCharacter> updateBookEntry(String id, int index, Map<String, Object?> fields) async {
    _requireId(id);
    final updates = _bookEntryUpdates(fields);
    return _editBook(id, (entries) {
      _requireBookIndex(index, entries);
      if (updates.isEmpty) {
        return false;
      }
      final entry = entries[index]! as Map<String, Object?>;
      for (final update in updates.entries) {
        final old = entry[update.key];
        entry[update.key] = update.key == 'extensions'
            ? _mergeBookExtensions(old is Map<String, Object?> ? old : {}, update.value! as Map<String, Object?>)
            : update.value;
      }
      return true;
    });
  }

  /// Removes only the addressed array entry. Non-null existing ids, including
  /// duplicates, retain their original order and values. Before a real edit,
  /// missing/null ids are fixed to their old fallback array index so deletion
  /// cannot shift the logical identities of later entries. Normalizing a
  /// stored null can change that entry's native ST timer key and hash.
  Future<StoredCharacter> deleteBookEntry(String id, int index) async {
    _requireId(id);
    return _editBook(id, (entries) {
      _requireBookIndex(index, entries);
      entries.removeAt(index);
      return true;
    });
  }

  Future<StoredCharacter> _editBook(String id, bool Function(List<Object?> entries) edit) => _exclusive(() async {
    await _tidy();
    final record = await _read(id);
    if (record == null) {
      throw const TavernImportError('角色不存在。');
    }
    final json = jsonDecode(jsonEncode(record.card.json)) as Map<String, Object?>;
    final data = json['data']! as Map<String, Object?>;
    final book = _editableBook(data['character_book']);
    final entries = book['entries']! as List<Object?>;
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index]! as Map<String, Object?>;
      entry['id'] ??= index;
    }
    if (!edit(entries)) {
      return record;
    }
    data['character_book'] = book;
    return _saveCard(record, json);
  });

  Future<StoredCharacter> _saveCard(StoredCharacter record, Map<String, Object?> json) async {
    (json['data']! as Map<String, Object?>)['modification_date'] = _now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final updated = StoredCharacter(
      id: record.id,
      card: TavernCard(
        json: json,
        assets: record.card.assets,
        png: record.card.png,
        originalBytes: record.card.originalBytes,
        sourceFormat: record.card.sourceFormat,
      ),
      importedAt: record.importedAt,
      avatarPath: record.avatarPath,
      directoryPath: record.directoryPath,
    );
    final summary = _summarize(updated);
    final cardFile = File('${_characters.path}/${record.id}/card.json');
    final pending = File('${cardFile.path}.writing');
    // No committed source revision may retain a readable older index. If
    // saving the card fails, the next list rebuilds the old source summary.
    await _invalidateSummary(record.id);
    try {
      await pending.writeAsString(jsonEncode(json), flush: true);
      await pending.rename(cardFile.path);
    } finally {
      try {
        if (await pending.exists()) {
          await pending.delete();
        }
      } on FileSystemException {
        // A later save overwrites this uncommitted file. Reads only use
        // card.json, so cleanup failure cannot publish an incomplete edit.
      }
    }
    await _writeSummary(summary);
    return updated;
  }

  /// Reads only derived summaries for current character directories. Old or
  /// damaged indexes are rebuilt from library.json and card.json, without
  /// opening the original import, images or embedded resource files.
  Future<List<StoredCharacterSummary>> list() => _exclusive(() async {
    await _tidy();
    final records = <StoredCharacterSummary>[];
    await for (final entity in _characters.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = _name(entity);
      if (!_idPattern.hasMatch(id)) continue;
      records.add(await _readSummary(id));
    }
    records.sort((a, b) {
      final byTime = b.importedAt.compareTo(a.importedAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return records;
  });

  Future<Uint8List> exportCard(String id, {TavernCardFormat format = TavernCardFormat.png}) => _exclusive(() async {
    _requireId(id);
    await _tidy();
    final record = await _read(id);
    if (record == null) throw const TavernImportError('角色不存在。');
    final modifiedAt = _now().toUtc();
    final card = record.card;
    return _encodeCard(card, format, modifiedAt);
  });

  /// The Tavern layer deletes this character's chats as part of its operation.
  /// This method owns only the files; it cannot reach an unrelated character.
  Future<void> delete(String id) => _exclusive(() async {
    _requireId(id);
    await _tidy();
    final directory = Directory('${_characters.path}/$id');
    final type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      try {
        // type() also hides lookup errors. Only confirmed absence may let the
        // facade remove this character's chats without renaming its directory.
        await FileSystemEntity.identical(directory.path, directory.path);
      } on PathNotFoundException catch (error) {
        final code = error.osError?.errorCode;
        if (code != 2 && !(Platform.isWindows && code == 3)) {
          rethrow;
        }
        if (await FileSystemEntity.type(directory.path, followLinks: false) != FileSystemEntityType.notFound) {
          rethrow;
        }
        await _discardSummary(id);
        return;
      }
      throw FileSystemException('The character folder could not be identified as absent.', directory.path);
    }
    if (type != FileSystemEntityType.directory) throw const FileSystemException('Character folder is not a directory');
    final trash = await directory.rename('${_characters.path}/.trash-${_newId()}');
    await _discard(trash);
    await _discardSummary(id);
  });

  Future<StoredCharacterSummary> _readSummary(String id) async {
    final directory = Directory('${_characters.path}/$id');
    try {
      // A cache is optional. Ignore links and non-files rather than following
      // them or recursively removing something that is not our index file.
      if (await FileSystemEntity.type(_indexes.path, followLinks: false) == FileSystemEntityType.directory) {
        final file = _indexFile(id);
        if (await FileSystemEntity.type(file.path, followLinks: false) == FileSystemEntityType.file) {
          return _summaryFromJson(jsonDecode(await file.readAsString()), id, directory.path);
        }
      }
    } on FileSystemException {
      // Source JSON below remains authoritative when the cache is unreadable.
    } on FormatException {
      // Includes invalid JSON/UTF-8, wrong versions and wrong summary types.
    }

    // Validate the same stored metadata contract as _read, but do not load
    // any file named in the resource manifest or the original/image flags.
    final value = jsonDecode(await File('${directory.path}/library.json').readAsString());
    if (value is! Map<String, Object?> || value['version'] != 1) {
      throw const TavernImportError('资料库元数据版本无效。');
    }
    if (!const {'png', 'json', 'charx'}.contains(value['sourceFormat'])) {
      throw const TavernImportError('资料库原件格式无效。');
    }
    final resources = value['resources'];
    if (resources is! List<Object?>) throw const TavernImportError('资料库资源目录无效。');
    for (final path in resources) {
      if (path is! String || !isSafeCardAssetPath(path)) throw const TavernImportError('资料库资源路径无效。');
    }
    final importedAtValue = value['importedAt'];
    if (importedAtValue is! String) throw const TavernImportError('资料库导入时间无效。');
    final importedAt = DateTime.tryParse(importedAtValue);
    if (importedAt == null) throw const TavernImportError('资料库导入时间无效。');
    final card = await _decodeStored(await File('${directory.path}/card.json').readAsBytes());
    final summary = _summarize(
      StoredCharacter(
        id: id,
        card: card,
        importedAt: importedAt,
        avatarPath: value['hasPortrait'] == true ? '${directory.path}/portrait.png' : null,
      ),
    );
    await _writeSummary(summary);
    return summary;
  }

  Future<void> _invalidateSummary(String id) async {
    final parentType = await FileSystemEntity.type(_indexes.path, followLinks: false);
    if (parentType != FileSystemEntityType.directory && parentType != FileSystemEntityType.notFound) return;
    final file = _indexFile(id);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      if (type != FileSystemEntityType.notFound) return;
      // type also reports lookup errors as notFound. On Linux, delete can
      // remap the same error to ENOENT, so probe with a read-only open first.
      final RandomAccessFile probe;
      try {
        probe = await file.open(mode: FileMode.read);
      } on PathNotFoundException catch (error) {
        final code = error.osError?.errorCode;
        // Accept only ENOENT / Windows file-or-path-not-found. Other Windows
        // PathNotFoundException codes include unavailable network paths.
        if (code == 2 || (Platform.isWindows && code == 3)) return;
        rethrow;
      }
      await probe.close();
    }
    // A readable index must be removed before source publication. Close and
    // delete failures must not be mistaken for absence by the open catch.
    await file.delete();
  }

  Future<void> _discardSummary(String id) async {
    try {
      await _invalidateSummary(id);
    } on FileSystemException {
      // Membership comes from committed card directories, so an orphaned
      // derived file cannot resurrect a deleted character.
    }
  }

  Future<void> _writeSummary(StoredCharacterSummary summary) async {
    final file = _indexFile(summary.id);
    final pending = File('${file.path}.writing');
    var cleanPending = false;
    try {
      final type = await FileSystemEntity.type(_indexes.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await _indexes.create(recursive: true);
      } else if (type != FileSystemEntityType.directory) {
        return;
      }
      final pendingType = await FileSystemEntity.type(pending.path, followLinks: false);
      if (pendingType != FileSystemEntityType.notFound && pendingType != FileSystemEntityType.file) return;
      cleanPending = true;
      await pending.writeAsString(jsonEncode(_summaryJson(summary)), flush: true);
      await pending.rename(file.path);
    } on FileSystemException {
      // Derived-cache failure cannot undo a successfully committed card or
      // turn a successful source-JSON read into a failed list operation.
    } finally {
      try {
        if (cleanPending &&
            await FileSystemEntity.type(pending.path, followLinks: false) == FileSystemEntityType.file) {
          await pending.delete();
        }
      } on FileSystemException {
        // A later write can replace a leftover uncommitted regular file.
      }
    }
  }

  Future<StoredCharacter?> _read(String id) async {
    final directory = Directory('${_characters.path}/$id');
    final type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) throw const FileSystemException('Character folder is not a directory');
    final metadataValue = jsonDecode(await File('${directory.path}/library.json').readAsString());
    if (metadataValue is! Map<String, Object?> || metadataValue['version'] != 1) {
      throw const TavernImportError('资料库元数据版本无效。');
    }
    final formatValue = metadataValue['sourceFormat'];
    final sourceFormat = switch (formatValue) {
      'png' => TavernCardFormat.png,
      'json' => TavernCardFormat.json,
      'charx' => TavernCardFormat.charx,
      _ => throw const TavernImportError('资料库原件格式无效。'),
    };
    final resourcePaths = metadataValue['resources'];
    if (resourcePaths is! List<Object?>) throw const TavernImportError('资料库资源目录无效。');
    final assets = <String, Uint8List>{};
    for (final path in resourcePaths) {
      if (path is! String || !isSafeCardAssetPath(path)) throw const TavernImportError('资料库资源路径无效。');
      assets[path] = await File('${directory.path}/resources/$path').readAsBytes();
    }
    final cardJson = await File('${directory.path}/card.json').readAsBytes();
    final parsed = await _decodeStored(cardJson);
    final importedAtValue = metadataValue['importedAt'];
    if (importedAtValue is! String) throw const TavernImportError('资料库导入时间无效。');
    final importedAt = DateTime.tryParse(importedAtValue);
    if (importedAt == null) throw const TavernImportError('资料库导入时间无效。');
    final card = TavernCard(
      json: parsed.json,
      assets: assets,
      png: metadataValue['hasPng'] == true ? await File('${directory.path}/source.png').readAsBytes() : null,
      originalBytes: await File('${directory.path}/original.${sourceFormat.name}').readAsBytes(),
      sourceFormat: sourceFormat,
    );
    return StoredCharacter(
      id: id,
      card: card,
      importedAt: importedAt,
      avatarPath: metadataValue['hasPortrait'] == true ? '${directory.path}/portrait.png' : null,
      directoryPath: directory.absolute.path,
    );
  }

  Future<void> _tidy() async {
    await _characters.create(recursive: true);
    await for (final entity in _characters.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = _name(entity);
      if (name.startsWith('.staging-') || name.startsWith('.trash-')) await _discard(entity);
    }
  }
}

StoredCharacterSummary _summarize(StoredCharacter record) {
  // Project only list fields. Do not clone theme, greetings or asset DTOs just
  // to discard them while recovering an old library's missing summary index.
  final card = record.card;
  final data = card.data;
  final tags = data['tags'];
  return StoredCharacterSummary(
    id: record.id,
    name: card.name,
    nickname: data['nickname'] is String ? data['nickname'] as String : null,
    creator: data['creator'] is String ? data['creator'] as String : null,
    tags: tags is List<Object?> ? tags.whereType<String>().toList() : const [],
    avatarPath: record.avatarPath,
    importedAt: record.importedAt,
    regexCount: card.regexCount,
    scriptCount: card.scriptCount,
    hasLorebook: data['character_book'] is Map<String, Object?>,
  );
}

Map<String, Object?> _summaryJson(StoredCharacterSummary summary) => {
  'version': 1,
  'id': summary.id,
  'name': summary.name,
  'nickname': summary.nickname,
  'creator': summary.creator,
  'tags': summary.tags,
  'importedAt': summary.importedAt.toIso8601String(),
  // Derive the path from the current root when loading, so moving a complete
  // library does not leave absolute paths pointing at its previous location.
  'hasPortrait': summary.avatarPath != null,
  'regexCount': summary.regexCount,
  'scriptCount': summary.scriptCount,
  'hasLorebook': summary.hasLorebook,
};

StoredCharacterSummary _summaryFromJson(Object? value, String id, String directoryPath) {
  const fields = {
    'version',
    'id',
    'name',
    'nickname',
    'creator',
    'tags',
    'importedAt',
    'hasPortrait',
    'regexCount',
    'scriptCount',
    'hasLorebook',
  };
  if (value is! Map<String, Object?> ||
      !value.keys.toSet().containsAll(fields) ||
      value['version'] is! int ||
      value['version'] != 1 ||
      value['id'] != id) {
    throw const FormatException('Invalid character summary index.');
  }
  final name = value['name'];
  final nickname = value['nickname'];
  final creator = value['creator'];
  final tags = value['tags'];
  final importedAtValue = value['importedAt'];
  final hasPortrait = value['hasPortrait'];
  final regexCount = value['regexCount'];
  final scriptCount = value['scriptCount'];
  final hasLorebook = value['hasLorebook'];
  if (name is! String ||
      (nickname != null && nickname is! String) ||
      (creator != null && creator is! String) ||
      tags is! List<Object?> ||
      tags.any((tag) => tag is! String) ||
      importedAtValue is! String ||
      hasPortrait is! bool ||
      hasLorebook is! bool ||
      regexCount is! int ||
      regexCount < 0 ||
      scriptCount is! int ||
      scriptCount < 0) {
    throw const FormatException('Invalid character summary fields.');
  }
  final importedAt = DateTime.tryParse(importedAtValue);
  if (importedAt == null) throw const FormatException('Invalid character summary time.');
  return StoredCharacterSummary(
    id: id,
    name: name,
    nickname: nickname as String?,
    creator: creator as String?,
    tags: List<String>.from(tags),
    importedAt: importedAt,
    avatarPath: hasPortrait ? '$directoryPath/portrait.png' : null,
    regexCount: regexCount,
    scriptCount: scriptCount,
    hasLorebook: hasLorebook,
  );
}

final _idPattern = RegExp(r'^card-[0-9a-f]{32}$');

const _editableTextFields = {
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
const _editableListFields = {'alternate_greetings', 'tags'};

Map<String, Object?> _fieldUpdates(Map<String, Object?> fields) {
  final updates = <String, Object?>{};
  for (final entry in fields.entries) {
    final value = entry.value;
    if (_editableTextFields.contains(entry.key)) {
      if (value is! String) throw ArgumentError.value(value, entry.key, 'Expected a string');
      updates[entry.key] = value;
    } else if (_editableListFields.contains(entry.key)) {
      if (value is! List<Object?> || value.any((item) => item is! String)) {
        throw ArgumentError.value(value, entry.key, 'Expected a list of strings');
      }
      updates[entry.key] = List<String>.from(value);
    } else {
      throw ArgumentError.value(entry.key, 'fields', 'This character field is read-only or unknown');
    }
  }
  return updates;
}

Map<String, Object?> _editableBook(Object? value) {
  if (value == null) {
    return {'extensions': <String, Object?>{}, 'entries': <Object?>[]};
  }
  if (value is! Map<String, Object?>) {
    throw ArgumentError.value(value, 'character_book', 'Expected a CC book object');
  }
  final entries = value['entries'];
  if (entries == null) {
    value['entries'] = <Object?>[];
  } else if (entries is! List<Object?> || entries.any((entry) => entry is! Map<String, Object?>)) {
    // Native ST maps remain readable by WorldInfoBook. This editor addresses
    // CC array indices and must not silently convert or drop a native map.
    throw ArgumentError.value(entries, 'entries', 'Book editing requires an array of entry objects');
  }
  return value;
}

void _requireBookIndex(int index, List<Object?> entries) {
  if (index < 0 || index >= entries.length) {
    throw RangeError.index(index, entries, 'index');
  }
}

int _nextBookEntryId(List<Object?> entries) {
  // Use the same JS-string identity as T6, including numeric 1.0 == 1 and
  // existing unusual ids. Never write the normalized execution view back.
  final occupied = WorldInfoBook.fromJson(
    id: 'library-edit',
    source: WorldInfoSource.character,
    json: {'entries': entries},
  ).entries.map((entry) => entry.uid).toSet();
  var id = 0;
  while (occupied.contains('$id')) {
    id++;
  }
  return id;
}

Map<String, Object?> _bookEntryUpdates(Map<String, Object?> fields) {
  if (fields.containsKey('id')) {
    throw ArgumentError.value(fields['id'], 'id', 'Entry ids cannot be edited');
  }
  final Map<String, Object?> updates;
  try {
    updates = jsonDecode(jsonEncode(fields)) as Map<String, Object?>;
  } on JsonUnsupportedObjectError {
    throw ArgumentError.value(fields, 'fields', 'Expected JSON entry fields');
  }
  for (final field in updates.entries) {
    final value = field.value;
    if (const {'keys', 'secondary_keys'}.contains(field.key)) {
      if (value is! List<Object?> || value.any((item) => item is! String)) {
        throw ArgumentError.value(value, field.key, 'Expected a list of strings');
      }
    } else if (const {'enabled', 'constant', 'selective', 'use_regex'}.contains(field.key)) {
      if (value is! bool) {
        throw ArgumentError.value(value, field.key, 'Expected a boolean');
      }
    } else if (const {'content', 'comment', 'name', 'position'}.contains(field.key)) {
      if (value is! String) {
        throw ArgumentError.value(value, field.key, 'Expected a string');
      }
    } else if (field.key == 'insertion_order') {
      if (value is! num || !value.isFinite) {
        throw ArgumentError.value(value, field.key, 'Expected a finite number');
      }
    } else if (field.key == 'extensions') {
      if (value is! Map<String, Object?>) {
        throw ArgumentError.value(value, field.key, 'Expected an object');
      }
      _validateBookExtensions(value);
    }
  }
  return updates;
}

void _validateBookExtensions(Map<String, Object?> fields) {
  for (final field in fields.entries) {
    final value = field.value;
    if (const {'selectiveLogic', 'position', 'depth', 'role'}.contains(field.key)) {
      if (value is! num || !value.isFinite || value != value.truncateToDouble()) {
        throw ArgumentError.value(value, 'extensions.${field.key}', 'Expected a finite integer');
      }
    } else if (const {'probability', 'group_weight'}.contains(field.key)) {
      if (value is! num || !value.isFinite) {
        throw ArgumentError.value(value, 'extensions.${field.key}', 'Expected a finite number');
      }
    } else if (const {'useProbability', 'group_override', 'use_group_scoring'}.contains(field.key)) {
      if (value is! bool) {
        throw ArgumentError.value(value, 'extensions.${field.key}', 'Expected a boolean');
      }
    } else if (const {'group', 'outlet_name'}.contains(field.key)) {
      if (value is! String) {
        throw ArgumentError.value(value, 'extensions.${field.key}', 'Expected a string');
      }
    }
  }
}

Map<String, Object?> _mergeBookExtensions(Map<String, Object?> current, Map<String, Object?> updates) => {
  ...current,
  for (final entry in updates.entries)
    entry.key: current[entry.key] is Map<String, Object?> && entry.value is Map<String, Object?>
        ? _mergeBookExtensions(current[entry.key]! as Map<String, Object?>, entry.value! as Map<String, Object?>)
        : entry.value,
};

// Top-level helpers keep an isolate callback from capturing the library's
// operation queue (and its unsendable Futures) through a surrounding closure.
Future<(TavernCard, Uint8List?)> _decodeImport(Uint8List bytes) => Isolate.run(() {
  const codec = CardCodec();
  final card = codec.decode(bytes);
  return (card, codec.portraitPng(card));
});

Future<TavernCard> _decodeStored(Uint8List bytes) => Isolate.run(() => const CardCodec().decode(bytes));

Future<Uint8List> _encodeCard(TavernCard card, TavernCardFormat format, DateTime modifiedAt) =>
    Isolate.run(() => const CardCodec().encode(card, format: format, modifiedAt: modifiedAt));

String _newId() {
  final random = Random.secure();
  return 'card-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

void _requireId(String id) {
  if (!CharacterLibrary.isValidId(id)) throw ArgumentError.value(id, 'id', 'Invalid character id');
}

String _name(FileSystemEntity entity) => entity.uri.pathSegments.lastWhere((part) => part.isNotEmpty);

Future<void> _discard(Directory directory) async {
  try {
    await directory.delete(recursive: true);
  } on FileSystemException {
    // The rename already made deletion final. Retry residual cleanup on the
    // next operation; never restore a character the user deleted.
  }
}
