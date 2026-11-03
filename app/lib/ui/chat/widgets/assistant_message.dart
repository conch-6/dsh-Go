// Portions derived from PiPilot (https://github.com/CikeSeven/pi_pilot), MIT, Copyright (c) 2026 CikeSeven. See THIRD_PARTY_NOTICES.md.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../common/expand_reveal.dart';
import '../../common/typing_indicator.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../dsh_ui/dsh_ui.dart';
import '../../plugins/native/message_plugin_menu.dart';
import '../../share/share_entry.dart' show shareReply;
import '../render/markdown_body.dart';
import 'message_actions.dart';
import 'thinking_pill.dart';

/// 助手消息:**无框裸排的全宽正文**(Claude 式),没有头像也没有署名。
///
/// ```
/// (思考过程 ⌄)
/// 正文 Markdown…▍
/// ⚠ 响应已中断
/// ⧉ ⇪ ⑂ ↻ ⋯        ← 一轮的最后一条才有(分叉视 DSH 是否支持;
///                    ↻ 重新回答只给整个对话的最后一条)
/// ```
///
/// ⇪ 和菜单里的「分享」打开同一个分享面板。长按或 ⋯:同一个消息菜单(复制 /
/// 选择文字 / 引用 / 分享 / 重新回答 / 从这里分叉)。正文因此不再直接长按选字,选字走菜单里的
/// "选择文字",选中一段还能「引用」(Claude 式)。
class AssistantMessage extends StatefulWidget {
  const AssistantMessage({
    super.key,
    required this.item,
    this.showActions = false,
    this.onBranch,
    this.branching = false,
    this.onRegenerate,
    this.regenerating = false,
    this.onQuote,
    this.footnote,
  });

  final AssistantChatItem item;

  /// 是否在正文下方显示复制等操作(只给一轮里最后一条助手正文)。
  final bool showActions;

  /// "从这里分叉";null = 这条不是已完成一轮的最后一条回复。
  final VoidCallback? onBranch;

  /// 正在从这里分叉:分叉键转圈,不能再点。
  final bool branching;

  /// 「重新回答」;null = 这条不是对话的最后一条回复,或提问发不了第二次。
  final VoidCallback? onRegenerate;

  /// 正在准备重新回答:重答键转圈,不能再点。
  final bool regenerating;

  /// 「引用」:整条回复,或「选择文字」里选中的一段,放到输入框上方。
  final ValueChanged<String>? onQuote;

  /// 回合脚注(这一轮在这条回复处结束),挂在操作行右端。
  final Widget? footnote;

  @override
  State<AssistantMessage> createState() => _AssistantMessageState();
}

class _AssistantMessageState extends State<AssistantMessage> {
  Widget? _body;
  String? _bodyText;
  bool? _bodyStreaming;

  /// 同一段文字只建一次 Markdown 子树:列表每 32ms 重建一次时,
  /// 没变的消息直接复用同一个 widget 实例,Flutter 不会再往下走。
  Widget _markdown(String text, bool streaming) {
    if (_body == null || _bodyText != text || _bodyStreaming != streaming) {
      // Long-press opens the menu; selecting text is one of its entries.
      // repairBareViews: a model that forgets the ```dsh-ui fence still gets
      // its view drawn instead of a wall of JSON.
      _body = MarkdownBody(text: text, streaming: streaming, selectable: false, repairBareViews: true);
      _bodyText = text;
      _bodyStreaming = streaming;
    }
    return _body!;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final item = widget.item;
    final text = item.text.trimRight();
    final reasoning = item.reasoning.trim();
    final streaming = item.streaming;

    if (text.isEmpty && reasoning.isEmpty) {
      if (streaming) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Semantics(label: l10n.chatReplying, child: const TypingIndicator()),
          ),
        );
      }
      if (!item.interrupted) return const SizedBox.shrink();
    }

    final actions = widget.showActions && !streaming && text.isNotEmpty;
    final reply = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: streaming || text.isEmpty ? null : () => _menu(text),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (reasoning.isNotEmpty) ...[
            ThinkingPill(reasoning: reasoning, active: streaming && text.isEmpty, streaming: streaming),
            if (text.isNotEmpty) const SizedBox(height: 8),
          ],
          if (text.isNotEmpty) _markdown(text, streaming),
          if (item.interrupted) const _InterruptedMark(),
          // 一轮结束时和输入条上的胶囊同一节奏展开:胶囊收回多少,这里长出
          // 多少,回答不会先被顶上去再落回来。打开对话时已结束的轮直接展开。
          ExpandReveal(
            open: actions,
            duration: AppMotion.standard,
            curve: AppMotion.std,
            child: actions
                ? ReplyActionRow(
                    // Copy / share carry a one-line summary of each visual
                    // reply, never its raw JSON.
                    text: dshUiPlainText(text),
                    onBranch: widget.onBranch,
                    branching: widget.branching,
                    onShare: () => shareReply(context, widget.item),
                    onRegenerate: widget.onRegenerate,
                    regenerating: widget.regenerating,
                    onMore: () => _menu(text),
                    trailing: widget.footnote,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
    // 一条回复是读屏里的一个分组,里面的段落、标题照常逐个读。
    return Semantics(container: true, explicitChildNodes: true, child: reply);
  }

  Future<void> _menu(String markdown) async {
    final text = dshUiPlainText(markdown);
    final onBranch = widget.onBranch;
    final onRegenerate = widget.onRegenerate;
    final onQuote = widget.onQuote;
    final action = await showMessageMenu(
      context,
      text: text,
      // Plugins' items for this reply, under each plugin's name.
      extra: nativeMessageMenuGroups(context, widget.item, text: markdown),
      actions: [
        MessageAction.copy,
        MessageAction.selectText,
        if (onQuote != null) MessageAction.quote,
        MessageAction.share,
        if (onRegenerate != null && !widget.regenerating) MessageAction.regenerate,
        if (onBranch != null && !widget.branching) MessageAction.branch,
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case MessageAction.copy:
        await copyMessage(context, text);
      case MessageAction.selectText:
        await showSelectTextSheet(context, text, markdown: true, onQuote: onQuote);
      case MessageAction.quote:
        onQuote?.call(text);
      case MessageAction.share:
        await shareReply(context, widget.item);
      case MessageAction.regenerate:
        onRegenerate?.call();
      case MessageAction.branch:
        onBranch?.call();
      case MessageAction.edit:
        break;
    }
  }
}

/// 被取消 / 中断:正文末尾一行 danger 小字,不改正文颜色。
class _InterruptedMark extends StatelessWidget {
  const _InterruptedMark();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final danger = DshColors.of(context).danger;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.stopped, size: 16, color: danger),
          const SizedBox(width: 4),
          Text(
            l10n.chatInterrupted,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: danger, height: 1.3),
          ),
        ],
      ),
    );
  }
}
