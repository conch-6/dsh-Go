// 酒馆设置: which DeepSeek model plays the characters and whether it thinks
// first (docs/design/roleplay.md §7). The key is the app's own DeepSeek key
// (settings_state.dart); nothing here stores it.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The models the tavern offers, cheapest first.
const tavernModels = ['deepseek-flash', 'deepseek-v4-pro'];

/// How a chat is laid out (docs/design/roleplay-ui.md §4): bubbles, full
/// width text under the speaker's name, or a stage with one paragraph at a
/// time (视觉小说).
enum TavernLayout { bubble, novel, visualNovel }

/// The story's text size (px), smallest first: a role-play reads more at a
/// time than a chat, so it starts a step below the app's 16.
const tavernTextSizes = [14.0, 15.0, 16.0, 18.0];

/// Its line spacing: 紧凑, 适中 (the app's), 宽松.
const tavernLineHeights = [1.5, 1.65, 1.8];

/// The story's colours (tavern_ink.dart): 素 leaves the text as the app draws
/// it; the others colour what is said and what is done. [st] takes them from
/// an ST theme taken in (tavern_st_theme.dart); with none, 暖's.
enum TavernPalette { plain, ember, ocean, rose, st }

/// How fast 视觉小说 types out a page (docs/design/roleplay-ui.md §4); 立即
/// shows each page whole.
enum TavernTextSpeed {
  slow(16),
  normal(32),
  fast(64),
  instant(null);

  const TavernTextSpeed(this.charactersPerSecond);

  /// Null: no typing out.
  final double? charactersPerSecond;
}

class TavernSettings {
  const TavernSettings({
    this.model = 'deepseek-flash',
    this.thinking = false,
    this.layout = TavernLayout.bubble,
    this.textSize = 15,
    this.lineHeight = 1.5,
    this.palette = TavernPalette.ember,
    this.textSpeed = TavernTextSpeed.normal,
    this.showUsage = true,
    this.cardTheme = true,
    this.novelIndent = true,
    this.islands = true,
    this.islandNoScripts = false,
    this.islandOffline = false,
    this.canvas = false,
    this.loaded = false,
  });

  final String model;
  final bool thinking;
  final TavernLayout layout;

  /// One of [tavernTextSizes] and [tavernLineHeights].
  final double textSize;
  final double lineHeight;
  final TavernPalette palette;
  final TavernTextSpeed textSpeed;

  /// A line of tokens under each reply, as the provider reported them.
  final bool showUsage;

  /// The card's own accent, name colours, layout and background
  /// (tavern_card_theme.dart); off, this page's settings everywhere.
  final bool cardTheme;

  /// 小说: each paragraph opens with two ideographic spaces, as fiction is set.
  final bool novelIndent;

  /// A message carrying HTML (an ```html block, <style>, <div>…) shows that
  /// part in a sandboxed web view of its own, as tall as it is (岛屿).
  final bool islands;

  /// Protections the user may turn on (security-as-options): the card's own
  /// scripts don't run in islands; islands load nothing from the network.
  final bool islandNoScripts;
  final bool islandOffline;

  /// 整页画布 (tavern_canvas.dart, a trial): the story in one web page with
  /// SillyTavern's structure, so a card's CSS reaches across messages. Not
  /// for 视觉小说; card scripts don't run there yet.
  final bool canvas;
  final bool loaded;

  TavernSettings copyWith({
    String? model,
    bool? thinking,
    TavernLayout? layout,
    double? textSize,
    double? lineHeight,
    TavernPalette? palette,
    TavernTextSpeed? textSpeed,
    bool? showUsage,
    bool? cardTheme,
    bool? novelIndent,
    bool? islands,
    bool? islandNoScripts,
    bool? islandOffline,
    bool? canvas,
  }) => TavernSettings(
    model: model ?? this.model,
    thinking: thinking ?? this.thinking,
    layout: layout ?? this.layout,
    textSize: textSize ?? this.textSize,
    lineHeight: lineHeight ?? this.lineHeight,
    palette: palette ?? this.palette,
    textSpeed: textSpeed ?? this.textSpeed,
    showUsage: showUsage ?? this.showUsage,
    cardTheme: cardTheme ?? this.cardTheme,
    novelIndent: novelIndent ?? this.novelIndent,
    islands: islands ?? this.islands,
    islandNoScripts: islandNoScripts ?? this.islandNoScripts,
    islandOffline: islandOffline ?? this.islandOffline,
    canvas: canvas ?? this.canvas,
    loaded: true,
  );
}

class TavernSettingsController extends Notifier<TavernSettings> {
  static const modelKey = 'tavern.model';
  static const thinkingKey = 'tavern.thinking';
  static const layoutKey = 'tavern.layout';
  static const textSizeKey = 'tavern.textSize';
  static const lineHeightKey = 'tavern.lineHeight';
  static const paletteKey = 'tavern.palette';
  static const textSpeedKey = 'tavern.textSpeed';
  static const showUsageKey = 'tavern.showUsage';
  static const cardThemeKey = 'tavern.cardTheme';
  static const novelIndentKey = 'tavern.novelIndent';
  static const islandsKey = 'tavern.islands';
  static const islandNoScriptsKey = 'tavern.islandNoScripts';
  static const islandOfflineKey = 'tavern.islandOffline';
  static const canvasKey = 'tavern.canvas';

  @override
  TavernSettings build() {
    unawaited(_load());
    return const TavernSettings();
  }

  Future<void> _load() async {
    var loaded = const TavernSettings(loaded: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final model = prefs.getString(modelKey);
      loaded = TavernSettings(
        model: tavernModels.contains(model) ? model! : tavernModels.first,
        thinking: prefs.getBool(thinkingKey) ?? false,
        layout: TavernLayout.values.asNameMap()[prefs.getString(layoutKey)] ?? TavernLayout.bubble,
        textSize: _oneOf(prefs.getDouble(textSizeKey), tavernTextSizes, 15),
        lineHeight: _oneOf(prefs.getDouble(lineHeightKey), tavernLineHeights, 1.5),
        palette: TavernPalette.values.asNameMap()[prefs.getString(paletteKey)] ?? TavernPalette.ember,
        textSpeed: TavernTextSpeed.values.asNameMap()[prefs.getString(textSpeedKey)] ?? TavernTextSpeed.normal,
        showUsage: prefs.getBool(showUsageKey) ?? true,
        cardTheme: prefs.getBool(cardThemeKey) ?? true,
        novelIndent: prefs.getBool(novelIndentKey) ?? true,
        islands: prefs.getBool(islandsKey) ?? true,
        islandNoScripts: prefs.getBool(islandNoScriptsKey) ?? false,
        islandOffline: prefs.getBool(islandOfflineKey) ?? false,
        canvas: prefs.getBool(canvasKey) ?? false,
        loaded: true,
      );
    } catch (_) {
      // No preferences backend (tests): the defaults.
    }
    if (!state.loaded) state = loaded;
  }

  Future<void> setModel(String model) async {
    state = state.copyWith(model: model);
    await _save((prefs) => prefs.setString(modelKey, model));
  }

  Future<void> setThinking(bool thinking) async {
    state = state.copyWith(thinking: thinking);
    await _save((prefs) => prefs.setBool(thinkingKey, thinking));
  }

  Future<void> setLayout(TavernLayout layout) async {
    state = state.copyWith(layout: layout);
    await _save((prefs) => prefs.setString(layoutKey, layout.name));
  }

  Future<void> setTextSize(double size) async {
    state = state.copyWith(textSize: size);
    await _save((prefs) => prefs.setDouble(textSizeKey, size));
  }

  Future<void> setLineHeight(double height) async {
    state = state.copyWith(lineHeight: height);
    await _save((prefs) => prefs.setDouble(lineHeightKey, height));
  }

  Future<void> setPalette(TavernPalette palette) async {
    state = state.copyWith(palette: palette);
    await _save((prefs) => prefs.setString(paletteKey, palette.name));
  }

  Future<void> setTextSpeed(TavernTextSpeed speed) async {
    state = state.copyWith(textSpeed: speed);
    await _save((prefs) => prefs.setString(textSpeedKey, speed.name));
  }

  Future<void> setShowUsage(bool show) async {
    state = state.copyWith(showUsage: show);
    await _save((prefs) => prefs.setBool(showUsageKey, show));
  }

  Future<void> setCardTheme(bool use) async {
    state = state.copyWith(cardTheme: use);
    await _save((prefs) => prefs.setBool(cardThemeKey, use));
  }

  Future<void> setNovelIndent(bool indent) async {
    state = state.copyWith(novelIndent: indent);
    await _save((prefs) => prefs.setBool(novelIndentKey, indent));
  }

  Future<void> setIslands(bool on) async {
    state = state.copyWith(islands: on);
    await _save((prefs) => prefs.setBool(islandsKey, on));
  }

  Future<void> setIslandNoScripts(bool on) async {
    state = state.copyWith(islandNoScripts: on);
    await _save((prefs) => prefs.setBool(islandNoScriptsKey, on));
  }

  Future<void> setIslandOffline(bool on) async {
    state = state.copyWith(islandOffline: on);
    await _save((prefs) => prefs.setBool(islandOfflineKey, on));
  }

  Future<void> setCanvas(bool on) async {
    state = state.copyWith(canvas: on);
    await _save((prefs) => prefs.setBool(canvasKey, on));
  }

  /// [stored] when it is one of [choices]; else [fallback].
  static double _oneOf(double? stored, List<double> choices, double fallback) =>
      stored != null && choices.contains(stored) ? stored : fallback;

  Future<void> _save(Future<bool> Function(SharedPreferences prefs) write) async {
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {}
  }
}

final tavernSettingsProvider = NotifierProvider<TavernSettingsController, TavernSettings>(TavernSettingsController.new);

/// One chat's own layout, over 酒馆设置's; null follows the setting.
class TavernChatLayoutController extends Notifier<TavernLayout?> {
  TavernChatLayoutController(this.chatId);

  final String chatId;
  var _chosen = false;

  String get _key => 'tavern.layout.$chatId';

  @override
  TavernLayout? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getString(_key);
      if (!_chosen && ref.mounted) state = TavernLayout.values.asNameMap()[stored];
    } catch (_) {}
  }

  Future<void> set(TavernLayout? layout) async {
    _chosen = true;
    state = layout;
    try {
      final prefs = await SharedPreferences.getInstance();
      layout == null ? await prefs.remove(_key) : await prefs.setString(_key, layout.name);
    } catch (_) {}
  }
}

final tavernChatLayoutProvider = NotifierProvider.autoDispose.family<TavernChatLayoutController, TavernLayout?, String>(
  TavernChatLayoutController.new,
);
