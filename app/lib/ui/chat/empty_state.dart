import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../pets/pet_signals.dart' show petTakesWhaleProvider;
import '../common/expand_reveal.dart';
import '../common/fade_in.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'empty_actions.dart';
import 'widgets/whale_tail.dart';

/// 一条建议:一枚线性小图标 + 一行字,点了把 [prompt] 填进输入条。
class ChatSuggestion {
  const ChatSuggestion(this.icon, String label, String prompt) : _label = label, _prompt = prompt, _defaultIndex = null;

  const ChatSuggestion._default(this.icon, this._defaultIndex) : _label = null, _prompt = null;

  final IconData icon;
  final String? _label;
  final String? _prompt;
  final int? _defaultIndex;

  String get label =>
      _label ??
      switch (_defaultIndex) {
        0 => appL10n.viewSuggestWorkspace,
        1 => appL10n.viewSuggestWordCount,
        2 => appL10n.viewSuggestNode,
        _ => appL10n.viewSuggestGit,
      };
  String get prompt =>
      _prompt ??
      switch (_defaultIndex) {
        0 => appL10n.viewSuggestWorkspacePrompt,
        1 => appL10n.viewSuggestWordCountPrompt,
        2 => appL10n.viewSuggestNodePrompt,
        _ => appL10n.viewSuggestGitPrompt,
      };
}

const defaultSuggestions = <ChatSuggestion>[
  ChatSuggestion._default(AppIcons.folderOpen, 0),
  ChatSuggestion._default(AppIcons.code, 1),
  ChatSuggestion._default(AppIcons.terminal, 2),
  ChatSuggestion._default(AppIcons.tip, 3),
];

/// 当前时间的来源(测试里固定它,让问候语可复现)。
@visibleForTesting
DateTime Function() chatClock = DateTime.now;

/// 问候语:按本地时间。
String greetingFor(DateTime now) {
  final h = now.hour;
  if (h >= 5 && h < 11) return appL10n.viewGreetingMorning;
  if (h >= 11 && h < 13) return appL10n.viewGreetingNoon;
  if (h >= 13 && h < 18) return appL10n.viewGreetingAfternoon;
  if (h >= 18 && h < 23) return appL10n.viewGreetingEvening;
  return appL10n.viewGreetingNight;
}

/// 新对话的空状态:居中偏上,一尾很淡的鲸尾 + 按时段的问候 + 一句短副标题,
/// 下面是两档控件(empty_actions.dart):
///
/// - 主操作至多一个,只在这一屏自己有出路时出现(连不上引擎:「重新连接」);
/// - 其余都是同一规格的安静胶囊:工作区胶囊、2×2 的建议。
///
/// 输入条才是这一屏的主角,这里只是安静地递几个起点。
///
/// ```
///                 ⌒)
///               下午好
///           今天想做点什么？
///         ( ▢ 在「dsh-app」中 ⌄ )        ← 断线时这里换成主色「重新连接」
///
///   ( ▢ 看看工作区有什么 ) ( </> 写个词频统计脚本 )
///   ( >_ 新建 Node.js 项目 ) ( ◌ rebase 还是 merge )
/// ```
///
/// 左右与顶栏、输入条一样离屏幕 12,宽屏时与输入条同宽居中;第一次出现时
/// 由上到下依次淡入。连不上引擎时建议收起,只留「重新连接」。
class ChatEmptyState extends StatelessWidget {
  const ChatEmptyState({
    super.key,
    required this.connected,
    required this.onSuggestion,
    this.connecting = false,
    this.starting = false,
    this.tidying = false,
    this.onReconnect,
    this.idle,
    this.now,
    this.suggestions = defaultSuggestions,
    this.workspace,
    this.onWorkspace,
    this.folderPicker,
  });

  final bool connected;
  final bool connecting;

  /// The on-device engine is booting.
  final bool starting;

  /// Booting includes the one-time tidy of plugin files (RuntimeStatus.tidyingFiles).
  final bool tidying;

  /// The engine could not be reached: the one primary pill, 「重新连接」,
  /// where the workspace chip goes; the suggestions fold away.
  final VoidCallback? onReconnect;

  /// 本机 is down and won't come up by itself (not installed, or stopped
  /// with 打开 App 时自动启动 off): the subtitle says so and the one primary
  /// pill fixes it (「安装运行环境」 / 「启动引擎」).
  final ChatIdleAction? idle;
  final ValueChanged<ChatSuggestion> onSuggestion;

  /// The workspace the new conversation starts in (null: the default).
  final String? workspace;

  /// Switches [workspace].
  final VoidCallback? onWorkspace;

  /// Optional drawer-folder choice for the new conversation.
  final Widget? folderPicker;

  /// 测试注入;默认取当前时间。
  final DateTime? now;
  final List<ChatSuggestion> suggestions;

  /// Same side margin and width cap as the header pills and the composer.
  static const sideMargin = AppSpace.floatInset;
  static const maxWidth = AppSpace.floatingWidth;

  /// Subtitle → the pill or chip under it.
  static const slotGap = 12.0;

  /// The pill or chip → the suggestions.
  static const suggestionsGap = 32.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final retry = connected ? null : onReconnect;
    final idle = connected || retry != null ? null : this.idle;
    final subtitle = connected
        ? l10n.viewEmptySubtitle
        : retry != null
        ? l10n.commonEngineUnreachable
        : idle != null
        ? idle.message
        : starting
        ? (tidying ? l10n.phoneEngineTidyingFilesEllipsis : l10n.viewEmptyStarting)
        : connecting
        ? l10n.viewEmptyConnecting
        : l10n.viewEmptyDisconnected;

    var order = 0;
    Widget enter(Widget child) => FadeSlideIn(index: order++, child: child);

    // One slot under the subtitle: the primary pill or the workspace chip,
    // the same height, swapped in place.
    final Widget? slot = retry != null
        ? EmptyPrimaryPill(key: const ValueKey('reconnect'), label: l10n.viewEmptyReconnect, onTap: retry)
        : idle != null
        ? EmptyPrimaryPill(key: ValueKey(idle.label), label: idle.label, onTap: idle.onTap)
        : workspace != null && connected
        ? ConstrainedBox(
            key: const ValueKey('workspace'),
            constraints: const BoxConstraints(maxWidth: 280),
            child: QuietChip(
              icon: AppIcons.workspace,
              label: l10n.viewEmptyWorkspace(workspace!),
              trailing: onWorkspace == null ? null : AppIcons.expand,
              onTap: onWorkspace,
              onTapHint: l10n.viewEmptySwitchWorkspace,
            ),
          )
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: sideMargin),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The pet stands on the composer below: one mascot a screen,
              // so the still whale tail fades while the pet is drawn. Its
              // room stays, so nothing moves when the pet comes and goes.
              enter(
                Consumer(
                  builder: (context, ref, child) => AnimatedOpacity(
                    opacity: ref.watch(petTakesWhaleProvider) ? 0 : 1,
                    duration: AppMotion.of(context, AppMotion.standard),
                    curve: AppMotion.std,
                    child: child,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Center(
                      child: WhaleTail(
                        still: true,
                        height: 40,
                        color: whaleColorFor(theme.brightness).withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
              ),
              enter(
                Text(
                  greetingFor(now ?? chatClock()),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.displaySmall?.copyWith(color: theme.colorScheme.onSurface),
                ),
              ),
              const SizedBox(height: 4),
              enter(
                AnimatedSwitcher(
                  duration: AppMotion.of(context, AppMotion.quick),
                  child: Text(
                    subtitle,
                    key: ValueKey(subtitle),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(color: dsh.textTertiary),
                  ),
                ),
              ),
              if (slot != null) ...[
                const SizedBox(height: slotGap),
                enter(
                  Center(
                    child: AnimatedSwitcher(duration: AppMotion.of(context, AppMotion.quick), child: slot),
                  ),
                ),
              ],
              if (connected && folderPicker != null) ...[
                const SizedBox(height: 8),
                enter(Center(child: folderPicker!)),
              ],
              if (suggestions.isNotEmpty)
                ExpandReveal(
                  open: retry == null && idle == null,
                  child: Padding(
                    padding: const EdgeInsets.only(top: suggestionsGap),
                    child: SuggestionChips(
                      suggestions: suggestions,
                      enabled: connected,
                      onSuggestion: onSuggestion,
                      firstIndex: order,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [ChatEmptyState.idle]: what the subtitle says and the pill under it.
class ChatIdleAction {
  const ChatIdleAction({required this.message, required this.label, required this.onTap});

  final String message;
  final String label;
  final VoidCallback onTap;
}
