// Pets the person brings: a schema-1 pack (docs/design/pets.md §3) zipped,
// unpacked into `<app support>/pets/<id>/`, which on Android is the very
// `files/pets/<id>/` the overlay falls back to (PetSprites.kt `sourceFor`:
// pack.json and the sheets side by side, nothing in folders).
//
// A pack from outside goes through the same parse as the built-in ones
// (PetPack.parse), then what the overlay's stricter parser (PetPack.kt) asks
// of it, then what a file nobody here made needs: safe names, whole PNG
// sheets with every cell inside them, and the format's size caps. Only
// pack.json and the sheets it names are kept; anything else in the zip is
// left behind.
//
// Installs and removals swap whole folders by rename, one at a time; what an
// interrupted one leaves (`.old-*`, `.trash-*`, `.staging-*`) is put right
// before the folder is next listed or read.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

// dart:io's ZLibDecoder streams into a sink, so a sheet is never inflated past its rows.
import 'package:archive/archive_io.dart' hide ZLibDecoder;
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'overlay_channel.dart' show petOverlayChannelProvider;
import 'pet_pack.dart';

/// Ids of brought pets start with this; the built-in ones never do.
const userPetPrefix = 'user-';

bool isUserPet(String id) => id.startsWith(userPetPrefix);

/// Why a zip was turned away.
enum PetImportProblem {
  /// Not a zip at all.
  notAZip,

  /// No pack.json at its top (or in its one top folder).
  noPack,

  /// pack.json didn't parse as a schema-1 pack; [PetImportException.detail] says where.
  badPack,

  /// A sheet pack.json names isn't in the zip.
  missingSheet,

  /// A sheet isn't a whole PNG, is too big, or its cells don't fit in it.
  badSheet,

  /// Bigger than a pet should be.
  tooLarge,

  /// The phone wouldn't let it be written.
  storage,
}

class PetImportException implements Exception {
  const PetImportException(this.problem, [this.detail]);

  final PetImportProblem problem;
  final String? detail;

  @override
  String toString() => 'PetImportException(${problem.name}${detail == null ? '' : ': $detail'})';
}

/// A sheet decodes to at most this many bytes (RGBA). The format suggests
/// 8 MB; Deepy's biggest is 12.9 MB, so a little room past that.
const petSheetDecodedCap = 16 * 1024 * 1024;

/// Neither side of a sheet longer than this (many GPUs' texture limit).
const petSheetSideCap = 4096;

const _packJsonCap = 256 * 1024;
const _sheetFileCap = 8 * 1024 * 1024;
const _sheetsCap = 64;
const _totalCap = 48 * 1024 * 1024;

/// A folder name as kept here: lower-case letters and digits in dash-joined runs.
final _plainId = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

/// A replaced pet's folder while its replacement goes in: `.old-<stamp>-<id>`.
final _backupName = RegExp(r'^\.old-(\d+)-(user-[a-z0-9-]+)$');

/// Where brought pets are kept (tests swap in a temporary folder).
final petLibraryProvider = Provider<PetLibrary>(
  (ref) => PetLibrary(
    () async => Directory('${(await getApplicationSupportDirectory()).path}/pets'),
    // The overlay may have looked while the pet was away and marked it
    // broken (PetOverlay's failedIds): it reads it again.
    onRestored: (id) => unawaited(ref.read(petOverlayChannelProvider).reloadPack(id)),
  ),
);

/// The brought pets on this phone.
class PetLibrary {
  PetLibrary(this._root, {this.onRestored});

  /// `<app support>/pets` (tests: a temporary folder).
  final Future<Directory> Function() _root;

  /// A pet an interrupted replacement had taken away is back from its backup.
  final void Function(String id)? onRestored;

  /// The tail of the queue: installs, removals, listings and reads run one at
  /// a time, so none sees another's folders half swapped.
  Future<void> _queue = Future.value();

  Future<T> _exclusive<T>(Future<T> Function() body) {
    final run = _queue.then((_) => body());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<Directory> folder(String id) async => Directory('${(await _root()).path}/$id');

  /// Every brought pet that still parses, oldest first.
  Future<List<PetPack>> list() => _exclusive(() async {
    final root = await _root();
    await _tidy(root);
    if (!await root.exists()) return const <PetPack>[];
    final found = <(DateTime, PetPack)>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = _nameOf(entity);
      if (!isUserPet(id)) continue;
      try {
        final json = File('${entity.path}/pack.json');
        found.add((await json.lastModified(), await _load(root, id)));
      } on Object {
        // Half there or broken: not offered.
      }
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final (_, pack) in found) pack];
  });

  /// One brought pet, reading its sheets from its folder.
  Future<PetPack> load(String id) => _exclusive(() async {
    final root = await _root();
    await _tidy(root);
    return _load(root, id);
  });

  /// Checks and unpacks [zip]; a pet with the same id is replaced. Returns
  /// its id and whether it replaced one.
  Future<({String id, bool replaced})> install(File zip) => _exclusive(() async {
    final root = await _root();
    await _tidy(root);
    final (:id, :backup) = await compute(_install, (zip.path, root.path, DateTime.now().microsecondsSinceEpoch));
    // The new one is in: the old one's folder goes when it can (else on a
    // later tidy), which is no reason to call the install failed.
    if (backup != null) await _discard(Directory(backup));
    return (id: id, replaced: backup != null);
  });

  /// Removes a brought pet. It leaves in one rename, so a removal that fails
  /// leaves it whole; its files are then deleted when they can be. Backups
  /// of it an earlier replacement couldn't delete are moved to the trash
  /// first: left as `.old-*`, the next tidy would bring the pet back.
  Future<void> remove(String id) async {
    if (!isUserPet(id) || !_plainId.hasMatch(id)) return;
    await _exclusive(() async {
      final root = await _root();
      if (!await root.exists()) return;
      final going = await root
          .list(followLinks: false)
          .where((e) => e is Directory && _backupName.firstMatch(_nameOf(e))?[2] == id)
          .cast<Directory>()
          .toList();
      final dir = Directory('${root.path}/$id');
      if (await dir.exists()) going.add(dir);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final trash = <Directory>[];
      try {
        // The pet itself last: if a backup won't move, the pet is still whole.
        for (final dir in going) {
          trash.add(await dir.rename('${root.path}/.trash-$stamp-${trash.length}-$id'));
        }
      } finally {
        for (final dir in trash) {
          await _discard(dir);
        }
      }
    });
  }

  Future<PetPack> _load(Directory root, String id) async {
    final dir = '${root.path}/$id';
    final json = jsonDecode(await File('$dir/pack.json').readAsString());
    if (json is! Map<String, Object?>) throw const FormatException('pack.json');
    final pack = PetPack.parse(json, dir: dir);
    if (pack.id != id) throw const FormatException('pack.json: id');
    return pack;
  }

  /// Puts right what an interrupted install or removal left (the app killed
  /// between its steps): a pet whose replacement never landed comes back
  /// from its backup; a backup whose pet is there (the replacement landed),
  /// a removed pet's trash and abandoned staging go. Run inside
  /// [_exclusive], so nothing it finds is still in use.
  Future<void> _tidy(Directory root) async {
    if (!await root.exists()) return;
    final backups = <String, List<(int, Directory)>>{};
    final junk = <Directory>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = _nameOf(entity);
      if (_backupName.firstMatch(name) case final m?) {
        (backups[m[2]!] ??= []).add((int.parse(m[1]!), entity));
      } else if (name.startsWith('.staging-') || name.startsWith('.trash-')) {
        junk.add(entity);
      }
    }
    for (final MapEntry(key: id, value: found) in backups.entries) {
      found.sort((a, b) => b.$1.compareTo(a.$1));
      var restored = false;
      if (!await Directory('${root.path}/$id').exists()) {
        try {
          await found.first.$2.rename('${root.path}/$id');
          restored = true;
          onRestored?.call(id);
        } on FileSystemException {
          continue; // Tried again next time; nothing of it is thrown away meanwhile.
        }
      }
      junk.addAll([for (final (_, dir) in found.skip(restored ? 1 : 0)) dir]);
    }
    for (final dir in junk) {
      await _discard(dir);
    }
  }
}

String _nameOf(FileSystemEntity entity) => entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);

/// Deletes [dir] if it can; what stays is deleted on a later tidy.
Future<void> _discard(Directory dir) async {
  try {
    await dir.delete(recursive: true);
  } on FileSystemException {
    // Busy or not allowed right now.
  }
}

/// The id a pack is kept under, after [userPetPrefix]. An id that already is
/// a plain folder name is kept as it is (with the prefix, which a pack
/// exported from here already has), so the same pet brought again replaces
/// itself. Any other is made folder-safe and told apart by a short hash of
/// the whole id: 「小猫」 and 「小狗」, `my cat` and `My Cat` stay two pets.
@visibleForTesting
String userPetIdFor(String packId) {
  final bare = packId.startsWith(userPetPrefix) ? packId.substring(userPetPrefix.length) : packId;
  if (bare.length <= 48 && _plainId.hasMatch(bare)) return '$userPetPrefix$bare';
  var slug = bare.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length > 32) slug = slug.substring(0, 32).replaceAll(RegExp(r'-+$'), '');
  final hash = sha256.convert(utf8.encode(packId)).toString().substring(0, 8);
  return '$userPetPrefix${slug.isEmpty ? 'pet' : slug}-$hash';
}

/// A sheet's own name: a plain PNG file name, nothing that climbs or nests.
bool _safeSheet(String name) =>
    name.isNotEmpty &&
    name.length <= 120 &&
    !name.contains('/') &&
    !name.contains('\\') &&
    !name.contains('\u0000') &&
    !name.startsWith('.') &&
    name.toLowerCase().endsWith('.png');

/// What the overlay's parser (PetPack.kt) turns away although
/// PetPack.parse takes it, as the detail of a [PetImportProblem.badPack];
/// null when both read [json] alike. It reads integers where the app rounds
/// (`scale`, `canvas`, a cell's size, `cols`, each frame's `i` and `ms`), so
/// those must be whole; it drops no malformed frame; and each cell must be
/// exactly its box × scale, in Kotlin's Float arithmetic. A missing `scale`
/// is fine: the install writes the app's reading of it (1) out.
@visibleForTesting
String? overlayPackProblem(Map<String, Object?> json) {
  bool whole(Object? v, {int min = 0, int max = 1 << 30}) =>
      v is num && v.isFinite && v == v.roundToDouble() && v >= min && v <= max;
  if (_depth(json) > 60) return 'pack.json: nested too deep';
  final scale = json['scale'] ?? 1;
  if (!whole(scale, min: 1, max: petSheetSideCap)) return 'pack.json: scale';
  final canvas = json['canvas'];
  if (canvas is! Map || !whole(canvas['w'], min: 1) || !whole(canvas['h'], min: 1)) return 'pack.json: canvas';
  final animations = json['animations'];
  if (animations is! Map) return 'pack.json: animations';
  for (final MapEntry(:key, :value) in animations.entries) {
    if (value is! Map) return 'pack.json: animation $key';
    final fw = value['frameW'];
    final fh = value['frameH'];
    if (!whole(fw, min: 1, max: petSheetSideCap) ||
        !whole(fh, min: 1, max: petSheetSideCap) ||
        !whole(value['cols'], min: 1, max: petSheetSideCap)) {
      return 'pack.json: frames of $key';
    }
    final box = value['box'];
    if (box is! Map || box['w'] is! num || box['h'] is! num) return 'pack.json: animation $key';
    if (_kotlinCell(box['w'] as num, scale as num) != fw || _kotlinCell(box['h'] as num, scale) != fh) {
      return 'pack.json: frameW, frameH of $key ≠ box × scale';
    }
    final frames = value['frames'];
    if (frames is! List) return 'pack.json: frames of $key';
    for (final f in frames) {
      if (f is! Map || !whole(f['i']) || !whole(f['ms'], min: 1)) return 'pack.json: frames of $key';
    }
  }
  return null;
}

/// `(box × scale).toInt()` as PetPack.kt computes it: the box as a Float,
/// times the scale in Float, truncated.
int _kotlinCell(num box, num scale) {
  final f = Float32List(1)..[0] = box.toDouble();
  f[0] = f[0] * scale.toInt();
  return f[0].isFinite ? f[0].truncate() : -1;
}

/// How deep [value] nests (the overlay's JSON reader stops at 64).
int _depth(Object? value) => switch (value) {
  final Map<Object?, Object?> m => 1 + m.values.map(_depth).fold(0, math.max),
  final List<Object?> l => 1 + l.map(_depth).fold(0, math.max),
  _ => 0,
};

/// A PNG's width and height from its header; null when it isn't one.
@visibleForTesting
(int, int)? pngSize(Uint8List bytes) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length < 24) return null;
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != signature[i]) return null;
  }
  // The first chunk is IHDR: length, type, then width and height.
  if (String.fromCharCodes(bytes.sublist(12, 16)) != 'IHDR') return null;
  final data = ByteData.sublistView(bytes);
  return (data.getUint32(16), data.getUint32(20));
}

/// Whether [bytes] is a whole PNG sheet a decoder will draw: every chunk
/// there with a good CRC, a sound IHDR (sides up to [petSheetSideCap]), one
/// run of IDAT that inflates to exactly the rows the header promises, each
/// with a known filter, no critical chunk a decoder may not know, and an
/// IEND. What a real decode adds (unfiltering) can't fail. Never inflates
/// past what the header promises.
@visibleForTesting
bool pngIntact(Uint8List bytes) {
  try {
    return _pngIntact(bytes);
  } on Object {
    // Bad zlib data, or anything else that doesn't read.
    return false;
  }
}

bool _pngIntact(Uint8List bytes) {
  if (pngSize(bytes) == null) return false;
  final data = ByteData.sublistView(bytes);
  var width = 0, height = 0, depth = 0, colour = -1, interlace = 0;
  var palette = false;
  final idat = <Uint8List>[];
  var idatOver = false;
  var at = 8;
  while (true) {
    if (bytes.length - at < 12) return false;
    final length = data.getUint32(at);
    if (length > bytes.length - at - 12) return false;
    final type = String.fromCharCodes(bytes, at + 4, at + 8);
    final body = Uint8List.sublistView(bytes, at + 8, at + 8 + length);
    if (getCrc32(Uint8List.sublistView(bytes, at + 4, at + 8 + length)) != data.getUint32(at + 8 + length)) {
      return false;
    }
    at += 12 + length;
    if (colour < 0 && type != 'IHDR') return false;
    if (type != 'IDAT' && idat.isNotEmpty) idatOver = true;
    switch (type) {
      case 'IHDR':
        if (colour >= 0 || length != 13) return false;
        final header = ByteData.sublistView(body);
        width = header.getUint32(0);
        height = header.getUint32(4);
        depth = body[8];
        colour = body[9];
        interlace = body[12];
        final depths = switch (colour) {
          0 => const [1, 2, 4, 8, 16],
          3 => const [1, 2, 4, 8],
          2 || 4 || 6 => const [8, 16],
          _ => const <int>[],
        };
        if (!depths.contains(depth) || body[10] != 0 || body[11] != 0 || interlace > 1) return false;
        if (width < 1 || height < 1 || width > petSheetSideCap || height > petSheetSideCap) return false;
      case 'PLTE':
        if (idat.isNotEmpty || length == 0 || length % 3 != 0 || length > 768) return false;
        palette = true;
      case 'IDAT':
        if (idatOver) return false;
        idat.add(body);
      case 'IEND':
        if (idat.isEmpty || (colour == 3 && !palette)) return false;
        return _rowsIntact(idat, width, height, depth, colour, interlace);
      default:
        // Names are four ASCII letters; one whose first is upper-case is
        // critical: a decoder that doesn't know it gives up on the image
        // (libpng, so Android's decoder, among them).
        if (!RegExp(r'^[A-Za-z]{4}$').hasMatch(type) || _upper(type.codeUnitAt(0))) return false;
    }
  }
}

bool _upper(int letter) => letter >= 0x41 && letter <= 0x5A;

bool _rowsIntact(List<Uint8List> idat, int width, int height, int depth, int colour, int interlace) {
  final channels = switch (colour) {
    2 => 3,
    4 => 2,
    6 => 4,
    _ => 1,
  };
  int stride(int w) => 1 + ((w * channels * depth + 7) >> 3);
  final strides = <int>[
    if (interlace == 0)
      for (var y = 0; y < height; y++) stride(width)
    else
      // Adam7: seven passes, each its own rows of its own width; an empty pass has no rows.
      for (final (x0, y0, dx, dy) in const [
        (0, 0, 8, 8),
        (4, 0, 8, 8),
        (0, 4, 4, 8),
        (2, 0, 4, 4),
        (0, 2, 2, 4),
        (1, 0, 2, 2),
        (0, 1, 1, 2),
      ])
        if (width > x0 && height > y0)
          for (var y = 0; y < (height - y0 + dy - 1) ~/ dy; y++) stride((width - x0 + dx - 1) ~/ dx),
  ];
  final rows = _PngRows(strides);
  final inflate = ZLibDecoder().startChunkedConversion(rows);
  for (final part in idat) {
    inflate.add(part);
  }
  inflate.close();
  return rows.complete;
}

/// Counts inflated image data against the rows it should make: each row's
/// filter byte is checked as it goes by, and a byte past the last row stops it.
class _PngRows implements Sink<List<int>> {
  _PngRows(this.strides);

  final List<int> strides;
  int _row = 0;

  /// Where the next row starts, in the whole stream.
  int _next = 0;
  int _seen = 0;

  bool get complete => _row == strides.length && _seen == _next;

  @override
  void add(List<int> chunk) {
    final start = _seen;
    _seen += chunk.length;
    while (_row < strides.length && _next < _seen) {
      if (chunk[_next - start] > 4) throw const FormatException('png: filter');
      _next += strides[_row++];
    }
    if (_row == strides.length && _seen > _next) throw const FormatException('png: more data than rows');
  }

  @override
  void close() {}
}

Future<({String id, String? backup})> _install((String, String, int) args) async {
  final (zipPath, rootPath, stamp) = args;
  final staging = Directory('$rootPath/.staging-$stamp');
  final input = InputFileStream(zipPath);
  try {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } on Object {
      throw const PetImportException(PetImportProblem.notAZip);
    }
    // Something that isn't a zip can read as an empty one.
    if (archive.files.isEmpty) throw const PetImportException(PetImportProblem.notAZip);
    final files = {
      for (final f in archive.files)
        if (f.isFile && !f.isSymbolicLink) f.name: f,
    };

    // pack.json at the top, or in the one folder the zip was made from.
    final packs = files.keys.where((n) => n == 'pack.json' || RegExp(r'^[^/]+/pack\.json$').hasMatch(n)).toList()
      ..sort((a, b) => a.length.compareTo(b.length));
    if (packs.isEmpty) throw const PetImportException(PetImportProblem.noPack);
    final packEntry = files[packs.first]!;
    final prefix = packs.first.substring(0, packs.first.length - 'pack.json'.length);
    if (packEntry.size > _packJsonCap) throw const PetImportException(PetImportProblem.tooLarge, 'pack.json');

    final Map<String, Object?> json;
    final PetPack pack;
    try {
      final decoded = jsonDecode(utf8.decode(packEntry.readBytes() ?? Uint8List(0)));
      if (decoded is! Map<String, Object?>) throw const FormatException('pack.json');
      json = decoded;
      pack = PetPack.parse(json);
    } on FormatException catch (error) {
      throw PetImportException(PetImportProblem.badPack, error.message);
    }
    // The overlay reads the same pack.json with its own, stricter parser.
    if (overlayPackProblem(json) case final problem?) throw PetImportException(PetImportProblem.badPack, problem);

    // Every sheet named, there, a whole PNG, and big enough for the cells it is read at.
    final sheets = <String, List<PetAnimation>>{};
    for (final anim in pack.animations.values) {
      if (!_safeSheet(anim.sheet)) throw PetImportException(PetImportProblem.badSheet, anim.sheet);
      (sheets[anim.sheet] ??= []).add(anim);
    }
    if (sheets.length > _sheetsCap) throw const PetImportException(PetImportProblem.tooLarge);
    final bytes = <String, Uint8List>{};
    var total = 0;
    for (final MapEntry(key: sheet, value: anims) in sheets.entries) {
      final entry = files['$prefix$sheet'];
      if (entry == null) throw PetImportException(PetImportProblem.missingSheet, sheet);
      if (entry.size > _sheetFileCap) throw PetImportException(PetImportProblem.tooLarge, sheet);
      final data = entry.readBytes();
      // A header can lie about the size; what came out can't.
      if (data == null || data.length > _sheetFileCap) throw PetImportException(PetImportProblem.tooLarge, sheet);
      total += data.length;
      if (total > _totalCap) throw const PetImportException(PetImportProblem.tooLarge);
      final size = pngSize(data);
      if (size == null) throw PetImportException(PetImportProblem.badSheet, sheet);
      final (w, h) = size;
      if (w <= 0 || h <= 0 || w > petSheetSideCap || h > petSheetSideCap || w * h * 4 > petSheetDecodedCap) {
        throw PetImportException(PetImportProblem.badSheet, sheet);
      }
      for (final anim in anims) {
        final last = anim.frames.map((f) => f.i).reduce(math.max);
        final rows = last ~/ anim.cols + 1;
        if (anim.cols * anim.frameWidth > w || rows * anim.frameHeight > h) {
          throw PetImportException(PetImportProblem.badSheet, '${anim.name} → $sheet');
        }
      }
      // A header can be whole over a cut-off file: read it all before the old pet goes.
      if (!pngIntact(data)) throw PetImportException(PetImportProblem.badSheet, sheet);
      bytes[sheet] = data;
    }

    // Written aside, then swapped in, so a pet is never half there.
    final id = userPetIdFor(pack.id);
    await staging.create(recursive: true);
    for (final MapEntry(key: sheet, value: data) in bytes.entries) {
      await File('${staging.path}/$sheet').writeAsBytes(data, flush: true);
    }
    // What the app read where pack.json left it out, spelled out for the
    // overlay: it requires a scale, and reads a missing pixelArt the other way.
    final kept = {...json, 'id': id, 'scale': pack.scale, 'pixelArt': pack.pixelArt};
    await File('${staging.path}/pack.json').writeAsString(jsonEncode(kept), flush: true);
    final live = Directory('$rootPath/$id');
    final old = Directory('$rootPath/.old-$stamp-$id');
    final replaced = await live.exists();
    if (replaced) await live.rename(old.path);
    try {
      await staging.rename(live.path);
    } on FileSystemException {
      // Killed here, or this fails too: the next tidy brings the old one back.
      if (replaced) await old.rename(live.path);
      rethrow;
    }
    return (id: id, backup: replaced ? old.path : null);
  } on PetImportException {
    rethrow;
  } on FileSystemException catch (error) {
    throw PetImportException(PetImportProblem.storage, error.osError?.message);
  } finally {
    await input.close();
    if (await staging.exists()) await _discard(staging);
  }
}
