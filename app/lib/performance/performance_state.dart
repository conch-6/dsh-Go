import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'performance_policy.dart';

export 'performance_policy.dart';

class PerformanceChannel {
  PerformanceChannel();

  /// What [performanceChannelProvider] builds. The test config swaps in a
  /// channel that answers at once, since tests have no platform side.
  @visibleForTesting
  static PerformanceChannel Function() create = PerformanceChannel.new;

  static const _methods = MethodChannel('dsh/performance');
  static const _events = EventChannel('dsh/performance/events');
  Future<PerformanceSnapshot>? _initial;

  Future<PerformanceSnapshot> snapshot() => _initial ??= _read();

  Future<PerformanceSnapshot> _read() async {
    try {
      final map = await _methods.invokeMapMethod<Object?, Object?>('snapshot');
      return map == null ? const PerformanceSnapshot(loaded: true) : PerformanceSnapshot.fromMap(map);
    } on MissingPluginException {
      return const PerformanceSnapshot(loaded: true);
    }
  }

  Stream<PerformanceSnapshot> get changes async* {
    // EventChannel reports missing registration through FlutterError, not the stream.
    // The native listener sends its current sequence on listen, closing this handoff race.
    if (!(await snapshot()).available) return;
    yield* _events
        .receiveBroadcastStream()
        .where((value) => value is Map)
        .map((value) => PerformanceSnapshot.fromMap(Map<Object?, Object?>.from(value as Map)));
  }
}

final performanceChannelProvider = Provider<PerformanceChannel>((ref) => PerformanceChannel.create());

class PerformanceController extends Notifier<PerformanceSnapshot> {
  late Future<void> ready;

  @override
  PerformanceSnapshot build() {
    final channel = ref.watch(performanceChannelProvider);
    final subscription = channel.changes.listen(_accept, onError: (Object _) {});
    ref.onDispose(() => unawaited(subscription.cancel()));
    ready = _load(channel);
    return const PerformanceSnapshot();
  }

  Future<void> _load(PerformanceChannel channel) async {
    final reply = Completer<PerformanceSnapshot>();
    // A broken native endpoint must not hold the first-run gate forever.
    final deadline = Timer(const Duration(seconds: 5), () {
      if (!reply.isCompleted) reply.complete(const PerformanceSnapshot(loaded: true));
    });
    ref.onDispose(() {
      deadline.cancel();
      if (!reply.isCompleted) reply.complete(const PerformanceSnapshot(loaded: true));
    });
    try {
      channel.snapshot().then(
        (value) {
          if (!reply.isCompleted) reply.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          if (!reply.isCompleted) reply.completeError(error, stack);
        },
      );
      _accept(await reply.future);
    } catch (_) {
      // Keep a newer thermal event even if its device facts have not arrived.
    } finally {
      deadline.cancel();
      if (ref.mounted && !state.loaded) {
        state = PerformanceSnapshot(
          sequence: state.sequence,
          device: state.device,
          thermal: state.thermal,
          loaded: true,
          available: state.available,
        );
      }
    }
  }

  void _accept(PerformanceSnapshot next) {
    if (!ref.mounted || next.sequence < state.sequence) return;
    state = next;
  }
}

final performanceProvider = NotifierProvider<PerformanceController, PerformanceSnapshot>(PerformanceController.new);

class PerformancePrefsController extends Notifier<PerformancePrefs> {
  static const modeKey = 'performance.mode';
  static const blurKey = 'performance.blur';
  static const animationsKey = 'performance.animations';
  static const refreshRateKey = 'performance.refresh_rate';
  late Future<void> ready;

  @override
  PerformancePrefs build() {
    ready = _load();
    return const PerformancePrefs();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      state = PerformancePrefs(
        mode: PerformanceMode.values.asNameMap()[prefs.getString(modeKey)] ?? PerformanceMode.auto,
        blur: prefs.getBool(blurKey),
        animations: prefs.getBool(animationsKey),
        refreshRate: RefreshRateMode.values.asNameMap()[prefs.getString(refreshRateKey)] ?? RefreshRateMode.auto,
        loaded: true,
      );
    } catch (_) {
      if (ref.mounted) state = state.copyWith(loaded: true);
    }
  }

  Future<void> _save(
    PerformancePrefs Function(PerformancePrefs) change,
    Future<void> Function(SharedPreferences) write,
  ) async {
    await ready;
    if (!ref.mounted) return;
    state = change(state);
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {
      // Preserve the choice for this run if the preferences backend is unavailable.
    }
  }

  Future<void> setMode(PerformanceMode mode) =>
      _save((s) => s.copyWith(mode: mode), (p) => p.setString(modeKey, mode.name));
  Future<void> setBlur(bool value) => _save((s) => s.copyWith(blur: value), (p) => p.setBool(blurKey, value));
  Future<void> setAnimations(bool value) =>
      _save((s) => s.copyWith(animations: value), (p) => p.setBool(animationsKey, value));
  Future<void> setRefreshRate(RefreshRateMode mode) =>
      _save((s) => s.copyWith(refreshRate: mode), (p) => p.setString(refreshRateKey, mode.name));
  Future<void> resetEffects() => _save((s) => s.copyWith(resetEffects: true), (p) async {
    await p.remove(blurKey);
    await p.remove(animationsKey);
  });
}

final performancePrefsProvider = NotifierProvider<PerformancePrefsController, PerformancePrefs>(
  PerformancePrefsController.new,
);

final performanceDefaultsProvider = Provider<PerformanceDefaults>(
  (ref) => PerformanceDefaults.resolve(ref.watch(performanceProvider), ref.watch(performancePrefsProvider)),
);

/// Both facts and stored overrides must be available before deriving a startup default.
Future<void> performanceReady(Ref ref) async {
  ref.read(performanceProvider);
  ref.read(performancePrefsProvider);
  await Future.wait([ref.read(performanceProvider.notifier).ready, ref.read(performancePrefsProvider.notifier).ready]);
}

Map<String, Object?> performanceDiagnostics(Ref ref) {
  final prefs = ref.read(performancePrefsProvider);
  return {
    ...ref.read(performanceProvider).toMap(),
    'preferences': {'mode': prefs.mode.name, 'blurOverride': prefs.blur, 'animationsOverride': prefs.animations, 'refreshRate': prefs.refreshRate.name},
    'defaults': ref.read(performanceDefaultsProvider).toMap(),
  };
}
