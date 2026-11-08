// The companion's downloaded assets (docs/design/companion.md): a zip with the
// Live2D runtime (`runtime/`) and one character (`character/`). Neither is in
// the repository; a build may carry one inside (companionBundledPack below).
//
// What's checked on the way in, because the page runs this content in a WebView:
//  - `runtime/` is code, so it must match the digest pinned below, whoever made
//    the zip. That's what lets a character come from anywhere.
//  - `character/` is data only: an extension allow-list, no scripts or HTML.
//  - every path stays inside its folder; size and count are capped.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// `runtime digest` printed by tooling/companion/build-pack.mjs.
const companionRuntimeDigest = '20e4e35ce1de09bd9017197363a96afdb4d9fc045d574fb669ebf21b4bc92e81';

/// Where the pack downloads from. Null until one is published: import works
/// without it. (url, bytes, sha256)
const CompanionPackSource? companionPackSource = null;

/// A pack that comes inside the app, unpacked the first time the room opens.
/// It isn't in the repository (its model's terms aren't settled for that):
/// builds made with the zip in place carry it, the others simply have none.
const companionBundledPack = 'assets/companion/whale-girl.zip';

/// Whether this build carries the pack, without reading it.
Future<bool> hasBundledCompanionPack([AssetBundle? bundle]) async {
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(bundle ?? rootBundle);
    return manifest.listAssets().contains(companionBundledPack);
  } on Object {
    return false;
  }
}

/// The bundled pack's bytes, or null when this build has none.
Future<Uint8List?> loadBundledCompanionPack([AssetBundle? bundle]) async {
  final assets = bundle ?? rootBundle;
  try {
    if (!await hasBundledCompanionPack(assets)) return null;
    final data = await assets.load(companionBundledPack);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } on Object {
    return null;
  }
}

@immutable
class CompanionPackSource {
  const CompanionPackSource({required this.urls, required this.bytes, required this.sha256});
  final List<String> urls;
  final int bytes;
  final String sha256;
}

enum CompanionPackProblem {
  notAPack,
  unsafePath,
  tooLarge,
  forbiddenFile,
  runtimeMismatch,
  noRuntime,
  noModel,

  /// A Cubism 2 model (`.moc` and `model.json`): the runtime only reads moc3.
  legacyModel,
  storage,
}

class CompanionPackException implements Exception {
  const CompanionPackException(this.problem, [this.detail]);
  final CompanionPackProblem problem;
  final String? detail;

  @override
  String toString() => 'CompanionPackException(${problem.name}${detail == null ? '' : ': $detail'})';
}

/// What the page shows about the installed character.
@immutable
class CompanionCharacter {
  const CompanionCharacter({this.name, this.author, this.license, this.source});

  factory CompanionCharacter.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    String? text(String key) =>
        map[key] is String && (map[key] as String).trim().isNotEmpty ? map[key] as String : null;
    return CompanionCharacter(
      name: text('name'),
      author: text('author'),
      license: text('license'),
      source: text('source'),
    );
  }

  final String? name;
  final String? author;
  final String? license;
  final String? source;
}

const _maxBytes = 400 * 1024 * 1024;
const _maxFiles = 4000;
const _dataExtensions = {'.json', '.moc3', '.png', '.jpg', '.jpeg', '.webp', '.wav', '.mp3', '.txt', '.md'};

/// The recipe in build-pack.mjs: over sorted `name\0sha256hex\n`.
String runtimeDigest(Map<String, String> sha256ByName) {
  final names = sha256ByName.keys.toList()..sort();
  return sha256.convert(utf8.encode([for (final n in names) '$n\u0000${sha256ByName[n]}\n'].join())).toString();
}

/// Whether [path] is a plain relative path with no way out of its folder.
bool isSafePackPath(String path) {
  if (path.isEmpty || path.contains('\\') || path.startsWith('/') || path.contains('\u0000')) return false;
  return path.split('/').every((part) => part.isNotEmpty && part != '.' && part != '..');
}

class CompanionPackStore {
  CompanionPackStore(this.root, {this.expectedRuntime = companionRuntimeDigest});

  /// The app's private folder for this; the pack lands in `<root>/pack`.
  final Directory root;
  final String expectedRuntime;

  Directory get pack => Directory('${root.path}/pack');

  Future<bool> installed() async =>
      await File('${pack.path}/runtime/live2dcubismcore.min.js').exists() &&
      await File('${pack.path}/character/index.json').exists();

  Future<CompanionCharacter> character() async {
    try {
      return CompanionCharacter.fromJson(
        jsonDecode(await File('${pack.path}/character/character.json').readAsString()),
      );
    } catch (_) {
      return const CompanionCharacter();
    }
  }

  /// Unpacks [zip] next to the current pack and swaps it in. If the swap fails,
  /// attempts to restore the old pack; a failed restoration leaves it in
  /// `pack.previous`. A zip with only `character/` keeps the installed runtime.
  Future<void> install(String zip) => compute(_install, (zip, root.path, expectedRuntime));

  Future<void> remove() async {
    if (await pack.exists()) await pack.delete(recursive: true);
  }
}

Future<void> _install((String, String, String) args) async {
  final (zipPath, rootPath, expected) = args;
  final staging = Directory('$rootPath/pack.staging');
  final previous = Directory('$rootPath/pack.previous');
  final live = Directory('$rootPath/pack');
  final input = InputFileStream(zipPath);
  try {
    await _forget(staging);
    await staging.create(recursive: true);

    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } on Object {
      throw const CompanionPackException(CompanionPackProblem.notAPack);
    }

    // What an archiver adds on its own (macOS's resource forks, Finder's notes).
    bool junk(String name) => name.startsWith('__MACOSX/') || name.split('/').last == '.DS_Store';
    final files = archive.files.where((f) => f.isFile && !junk(f.name)).toList();
    if (files.isEmpty) throw const CompanionPackException(CompanionPackProblem.notAPack);
    if (files.length > _maxFiles) throw const CompanionPackException(CompanionPackProblem.tooLarge);

    // A pack (runtime/ and character/), or a model as it comes: its folder
    // zipped, model3.json and all, which goes under character/ beside the
    // installed runtime. What the stage can't use in a bare model (the
    // editor's .cmo3, a .psd) is left behind rather than refused.
    final pack = files.any((f) => f.name.startsWith('runtime/') || f.name.startsWith('character/'));
    final targets = <(ArchiveFile, String)>[];
    if (pack) {
      for (final file in files) {
        targets.add((file, file.name));
      }
    } else {
      if (!files.any((f) => f.name.toLowerCase().endsWith('.model3.json'))) {
        final legacy = files.any((f) => f.name.toLowerCase().endsWith('.moc'));
        throw CompanionPackException(legacy ? CompanionPackProblem.legacyModel : CompanionPackProblem.noModel);
      }
      final tops = {for (final f in files) f.name.split('/').first};
      final strip = tops.length == 1 && files.every((f) => f.name.contains('/')) ? '${tops.single}/' : '';
      for (final file in files) {
        final name = file.name.substring(strip.length);
        if (!_dataExtensions.contains(_extension(name))) continue;
        targets.add((file, 'character/$name'));
      }
    }

    var declared = 0;
    for (final (file, name) in targets) {
      if (!isSafePackPath(name) || (!name.startsWith('runtime/') && !name.startsWith('character/'))) {
        throw CompanionPackException(CompanionPackProblem.unsafePath, file.name);
      }
      if (file.isSymbolicLink) throw CompanionPackException(CompanionPackProblem.forbiddenFile, file.name);
      if (name.startsWith('character/') && !_dataExtensions.contains(_extension(name))) {
        throw CompanionPackException(CompanionPackProblem.forbiddenFile, file.name);
      }
      declared += file.size;
      if (declared > _maxBytes) throw const CompanionPackException(CompanionPackProblem.tooLarge);
    }

    final runtimeHashes = <String, String>{};
    final characterFiles = <String>[];
    var written = 0;
    for (final (file, name) in targets) {
      final target = File('${staging.path}/$name');
      await target.parent.create(recursive: true);
      final output = OutputFileStream(target.path);
      try {
        file.writeContent(output);
      } on Object {
        await output.close();
        throw CompanionPackException(CompanionPackProblem.notAPack, file.name);
      }
      await output.close();
      // A header can lie about the size; what landed on disk can't.
      written += await target.length();
      if (written > _maxBytes) throw const CompanionPackException(CompanionPackProblem.tooLarge);
      if (name.startsWith('runtime/')) {
        runtimeHashes[name] = (await sha256.bind(target.openRead()).first).toString();
      } else {
        characterFiles.add(name.substring('character/'.length));
      }
    }

    if (runtimeHashes.isNotEmpty) {
      if (runtimeDigest(runtimeHashes) != expected) {
        throw const CompanionPackException(CompanionPackProblem.runtimeMismatch);
      }
    } else {
      final current = Directory('${live.path}/runtime');
      if (!await current.exists()) throw const CompanionPackException(CompanionPackProblem.noRuntime);
      await _copy(current, Directory('${staging.path}/runtime'));
    }
    if (!characterFiles.any((f) => f.toLowerCase().endsWith('.model3.json'))) {
      throw const CompanionPackException(CompanionPackProblem.noModel);
    }
    // A bare model has no character.json: its model3.json (the shallowest)
    // and a name from it; the rest the person sets in the app.
    if (!characterFiles.contains('character.json')) {
      final model = characterFiles.where((f) => f.toLowerCase().endsWith('.model3.json')).toList()
        ..sort((a, b) => '/'.allMatches(a).length.compareTo('/'.allMatches(b).length));
      final name = model.first.split('/').last.replaceFirst(RegExp(r'\.model3\.json$', caseSensitive: false), '');
      await File('${staging.path}/character/character.json')
          .writeAsString(jsonEncode({'schema': 1, 'name': name, 'model': model.first}));
      characterFiles.add('character.json');
    }
    await File('${staging.path}/character/index.json').writeAsString(jsonEncode(characterFiles));

    // Discard the old pack only after the new one is live. If promotion fails,
    // restore it; if that also fails, keep pack.previous for recovery.
    await _forget(previous);
    final hadLive = await live.exists();
    if (hadLive) await live.rename(previous.path);
    try {
      await staging.rename(live.path);
    } on FileSystemException {
      if (hadLive) await previous.rename(live.path);
      rethrow;
    }
    await _forget(previous);
  } on CompanionPackException {
    await _forget(staging);
    rethrow;
  } on FileSystemException catch (error) {
    await _forget(staging);
    throw CompanionPackException(CompanionPackProblem.storage, error.osError?.message);
  } finally {
    await input.close();
  }
}

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot).toLowerCase();
}

Future<void> _copy(Directory from, Directory to) async {
  await for (final entity in from.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final target = File('${to.path}/${entity.path.substring(from.path.length + 1)}');
    await target.parent.create(recursive: true);
    await entity.copy(target.path);
  }
}

Future<void> _forget(Directory staging) async {
  try {
    if (await staging.exists()) await staging.delete(recursive: true);
  } on FileSystemException {
    // The next install starts by clearing it again.
  }
}
