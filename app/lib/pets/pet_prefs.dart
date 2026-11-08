// 宠物设置 (docs/design/pets.md §2.1, §7), kept in SharedPreferences like the
// other appearance settings: which pet (or none), its size, quiet mode, where
// it stands, and 「藏起来 1 小时」. The overlay keeps its own switches natively.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../performance/performance_state.dart';
import 'pet_library.dart';
import 'pet_state.dart';

/// The pets that ship with the app, in picker order.
const builtInPets = ['deepy-whale', 'whale-girl'];

/// The default pet.
const defaultPetId = 'deepy-whale';

@immutable
class PetPrefs {
  const PetPrefs({
    this.packId = defaultPetId,
    this.packExplicit = true,
    this.size = PetSize.medium,
    this.quiet = false,
    this.position = defaultPosition,
    this.hiddenUntil,
    this.loaded = false,
  });

  /// Where a new pet stands: a quarter along its perch, clear of the
  /// jump-to-bottom key on the right.
  static const defaultPosition = 0.25;

  /// The chosen pet, or [noPetId] (「不显示」).
  final String packId;
  final bool packExplicit;
  final PetSize size;

  /// 「安静模式」: moves only, no bubbles.
  final bool quiet;

  /// Where its foot stands along its perch, as a share of the perch's width.
  final double position;

  /// 「藏起来 1 小时」 until then.
  final DateTime? hiddenUntil;
  final bool loaded;

  bool get enabled => packId != noPetId;

  bool hiddenAt(DateTime now) => hiddenUntil != null && hiddenUntil!.isAfter(now);

  PetPrefs copyWith({
    String? packId,
    bool? packExplicit,
    PetSize? size,
    bool? quiet,
    double? position,
    DateTime? hiddenUntil,
    bool clearHidden = false,
    bool? loaded,
  }) => PetPrefs(
    packId: packId ?? this.packId,
    packExplicit: packExplicit ?? this.packExplicit,
    size: size ?? this.size,
    quiet: quiet ?? this.quiet,
    position: position ?? this.position,
    hiddenUntil: clearHidden ? null : (hiddenUntil ?? this.hiddenUntil),
    loaded: loaded ?? this.loaded,
  );

  @override
  bool operator ==(Object other) =>
      other is PetPrefs &&
      other.packId == packId &&
      other.packExplicit == packExplicit &&
      other.size == size &&
      other.quiet == quiet &&
      other.position == position &&
      other.hiddenUntil == hiddenUntil &&
      other.loaded == loaded;

  @override
  int get hashCode => Object.hash(packId, packExplicit, size, quiet, position, hiddenUntil, loaded);
}

class PetPrefsController extends Notifier<PetPrefs> {
  static const keys = (
    pack: 'pet.pack',
    size: 'pet.size',
    quiet: 'pet.quiet',
    position: 'pet.position',
    hidden: 'pet.hidden_until',
  );

  late Future<void> _loaded;

  @override
  PetPrefs build() {
    ref.listen(performanceDefaultsProvider.select((p) => p.petEnabled), (_, next) {
      if (!state.packExplicit) state = state.copyWith(packId: next ? defaultPetId : noPetId);
    });
    _loaded = _load();
    return const PetPrefs(packExplicit: false);
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      await performanceReady(ref);
      if (!ref.mounted) return;
      final pack = prefs.getString(keys.pack);
      // A brought pet stays chosen; removing it here picks the default
      // (UserPetsController.remove).
      final explicit = pack == noPetId || builtInPets.contains(pack) || (pack != null && isUserPet(pack));
      final hidden = prefs.getInt(keys.hidden);
      state = PetPrefs(
        packId: explicit
            ? pack!
            : ref.read(performanceDefaultsProvider).petEnabled
            ? defaultPetId
            : noPetId,
        packExplicit: explicit,
        size: PetSize.fromName(prefs.getString(keys.size)),
        quiet: prefs.getBool(keys.quiet) ?? false,
        position: (prefs.getDouble(keys.position) ?? PetPrefs.defaultPosition).clamp(0.0, 1.0),
        hiddenUntil: hidden == null ? null : DateTime.fromMillisecondsSinceEpoch(hidden),
        loaded: true,
      );
    } catch (_) {
      // No preferences backend (tests): defaults.
      if (ref.mounted) state = state.copyWith(loaded: true);
    }
  }

  /// Applies once the stored values are in, so a late load can't undo a change.
  Future<void> _save(PetPrefs Function(PetPrefs) apply, Future<void> Function(SharedPreferences) write) async {
    await _loaded;
    if (!ref.mounted) return;
    state = apply(state);
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {
      // Kept for this run only.
    }
  }

  /// A pet, or [noPetId]. Choosing one also brings a hidden pet back.
  Future<void> setPack(String id) =>
      _save((s) => s.copyWith(packId: id, packExplicit: true, clearHidden: true), (p) async {
        await p.setString(keys.pack, id);
        await p.remove(keys.hidden);
      });

  /// The pet changed for the person, not by them (theirs is being removed):
  /// unlike [setPack], 「藏起来 1 小时」 stays as it was.
  Future<void> replacePack(String id) =>
      _save((s) => s.copyWith(packId: id, packExplicit: true), (p) => p.setString(keys.pack, id));

  /// First run's 「桌宠与悬浮窗」 was picked: the default pet, unless a pet
  /// (or 「不显示」) was chosen already. Without it a light phone, whose
  /// default is no pet, would turn on 「App 外显示」 with nothing to show.
  Future<void> adoptDefault() async {
    await _loaded;
    if (!ref.mounted || state.packExplicit) return;
    await setPack(defaultPetId);
  }

  Future<void> setSize(PetSize v) => _save((s) => s.copyWith(size: v), (p) => p.setString(keys.size, v.name));
  Future<void> setQuiet(bool v) => _save((s) => s.copyWith(quiet: v), (p) => p.setBool(keys.quiet, v));
  Future<void> setPosition(double v) {
    final x = v.clamp(0.0, 1.0);
    return _save((s) => s.copyWith(position: x), (p) => p.setDouble(keys.position, x));
  }

  /// 「藏起来 1 小时」.
  Future<void> hideUntil(DateTime until) =>
      _save((s) => s.copyWith(hiddenUntil: until), (p) => p.setInt(keys.hidden, until.millisecondsSinceEpoch));

  Future<void> unhide() => _save((s) => s.copyWith(clearHidden: true), (p) => p.remove(keys.hidden));
}

final petPrefsProvider = NotifierProvider<PetPrefsController, PetPrefs>(PetPrefsController.new);
