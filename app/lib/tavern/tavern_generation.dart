// 酒馆设置 › 生成: how much of the story goes to the model, how long a reply
// may be, and how freely it writes. They live in the engine's default preset
// (readSettings / setSettings), until the preset library (T20) gives each chat
// its own.

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tavern_provider.dart';

/// The context the model sees (tokens): ST's default 4K, then what DeepSeek's
/// window allows. More context remembers more, and costs more each turn.
const tavernContextSizes = [4095, 16384, 32768, 65536, 131072];

/// The longest reply (tokens).
const tavernReplySizes = [300, 1000, 2000, 4000];

/// How freely it writes: DeepSeek suggests 1.3 for conversation, 1.5 for
/// creative writing.
const tavernTemperatures = [0.7, 1.0, 1.3, 1.5];

class TavernGeneration {
  const TavernGeneration({required this.maxContext, required this.maxReply, required this.temperature});

  /// The default preset's values when nothing is set: ST's own.
  static const standard = TavernGeneration(maxContext: 4095, maxReply: 300, temperature: 1);

  final int maxContext;
  final int maxReply;
  final double temperature;

  static TavernGeneration of(Map<String, Object?> preset) => TavernGeneration(
    maxContext: (preset['openai_max_context'] as num?)?.toInt() ?? standard.maxContext,
    maxReply: (preset['openai_max_tokens'] as num?)?.toInt() ?? standard.maxReply,
    temperature: (preset['temperature'] as num?)?.toDouble() ?? standard.temperature,
  );
}

class TavernGenerationController extends AsyncNotifier<TavernGeneration> {
  static const contextKey = 'openai_max_context';
  static const replyKey = 'openai_max_tokens';
  static const temperatureKey = 'temperature';

  @override
  Future<TavernGeneration> build() async => TavernGeneration.of(await _preset());

  /// The default preset as the engine has it: ST's own when none is set.
  Future<Map<String, Object?>> _preset() async {
    final settings = await ref.read(tavernProvider).readSettings();
    return switch (settings['preset']) {
      final Map<String, Object?> preset when preset.isNotEmpty => preset,
      _ => ChatPreset.stDefault().raw,
    };
  }

  Future<void> setMaxContext(int tokens) => _set(contextKey, tokens);
  Future<void> setMaxReply(int tokens) => _set(replyKey, tokens);
  Future<void> setTemperature(double value) => _set(temperatureKey, value);

  /// Writes the whole preset back with [key] changed: a preset the engine is
  /// given is all of it, so one field alone would lose the prompts.
  Future<void> _set(String key, Object value) async {
    final preset = {...await _preset(), key: value};
    state = AsyncData(TavernGeneration.of(preset));
    await ref.read(tavernProvider).setSettings({'preset': preset});
  }
}

final tavernGenerationProvider = AsyncNotifierProvider<TavernGenerationController, TavernGeneration>(
  TavernGenerationController.new,
);
