/// A default profile, not a benchmark score. Android owns the classification.
enum DeviceTier { low, medium, high }

enum PerformanceMode { auto, full, light }

class PerformanceSnapshot {
  const PerformanceSnapshot({
    this.sequence = -1,
    this.device = const {},
    this.thermal = const {},
    this.loaded = false,
    this.available = false,
  });

  factory PerformanceSnapshot.fromMap(Map<Object?, Object?> raw) {
    Map<String, Object?> section(Object? value) => value is Map
        ? {
            for (final entry in value.entries)
              if (entry.key is String) entry.key as String: entry.value,
          }
        : const {};
    return PerformanceSnapshot(
      sequence: (raw['sequence'] as num?)?.toInt() ?? 0,
      device: section(raw['device']),
      thermal: section(raw['thermal']),
      loaded: raw['device'] is Map,
      available: true,
    );
  }

  final int sequence;
  final Map<String, Object?> device;
  final Map<String, Object?> thermal;
  final bool loaded;
  final bool available;

  DeviceTier get tier => DeviceTier.values.asNameMap()[device['tier']] ?? DeviceTier.medium;
  bool get thermalLightweight => thermal['lightweight'] == true;

  Map<String, Object?> toMap() => {'available': available, 'loaded': loaded, 'device': device, 'thermal': thermal};
}

/// 屏幕刷新率(设置 → 性能)。有些系统把第三方 App 默认压在 60Hz;App 一旦声明
/// 自己管刷新率,系统就会把开关显示成「应用内设置」——所以这里必须真的给用户一个
/// 选择,包括「跟随系统」把决定权还回去。
enum RefreshRateMode {
  /// 动画、滚动、流式输出时用屏幕最高刷新率;停下来交回系统。
  auto,

  /// 一直用最高刷新率。
  max,

  /// 不声明偏好,完全由系统的刷新率设置决定。
  system,
}

/// Null per-feature values mean "use the current profile". Defaults are never persisted.
class PerformancePrefs {
  const PerformancePrefs({
    this.mode = PerformanceMode.auto,
    this.blur,
    this.animations,
    this.refreshRate = RefreshRateMode.auto,
    this.loaded = false,
  });

  final PerformanceMode mode;
  final bool? blur;
  final bool? animations;
  final RefreshRateMode refreshRate;
  final bool loaded;

  PerformancePrefs copyWith({
    PerformanceMode? mode,
    bool? blur,
    bool? animations,
    RefreshRateMode? refreshRate,
    bool? loaded,
    bool resetEffects = false,
  }) => PerformancePrefs(
    mode: mode ?? this.mode,
    blur: resetEffects ? null : blur ?? this.blur,
    animations: resetEffects ? null : animations ?? this.animations,
    refreshRate: refreshRate ?? this.refreshRate,
    loaded: loaded ?? this.loaded,
  );
}

class PerformanceDefaults {
  const PerformanceDefaults({
    required this.lightweight,
    required this.blur,
    required this.reduceMotion,
    required this.petEnabled,
    required this.autoStartLocal,
    required this.recommendRemote,
  });

  factory PerformanceDefaults.resolve(PerformanceSnapshot snapshot, PerformancePrefs prefs) {
    final light =
        snapshot.thermalLightweight ||
        switch (prefs.mode) {
          PerformanceMode.auto => snapshot.tier == DeviceTier.low,
          PerformanceMode.full => false,
          PerformanceMode.light => true,
        };
    return PerformanceDefaults(
      lightweight: light,
      blur: prefs.blur ?? !light,
      reduceMotion: !(prefs.animations ?? !light),
      petEnabled: !light,
      autoStartLocal: !light,
      recommendRemote: light || snapshot.tier == DeviceTier.low,
    );
  }

  final bool lightweight;
  final bool blur;
  final bool reduceMotion;
  final bool petEnabled;
  final bool autoStartLocal;
  final bool recommendRemote;

  /// Reserved for 7b. No tier opts into extra background residency by default.
  bool get keepEngineInBackground => false;

  Map<String, Object?> toMap() => {
    'lightweight': lightweight,
    'blur': blur,
    'reduceMotion': reduceMotion,
    'petEnabledDefault': petEnabled,
    'autoStartLocalDefault': autoStartLocal,
    'recommendRemote': recommendRemote,
    'keepEngineInBackgroundDefault': keepEngineInBackground,
  };
}
