// Portions derived from PiPilot (https://github.com/CikeSeven/pi_pilot), MIT, Copyright (c) 2026 CikeSeven. See THIRD_PARTY_NOTICES.md.
// Local changes: chrome-tier glass with a 28 radius; a solid primary send
// key; model picking lives in the header chip; one send action, since DSH
// queues prompts sent mid-turn.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../common/expand_reveal.dart';
import '../pets/pet_perch.dart';
import '../settings/voice_settings_page.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'voice/voice_controller.dart';
import 'voice/voice_widgets.dart';

/// The editor's line height, as a multiple of its font size.
const _lineHeight = 1.45;

/// 输入条:chrome 玻璃 + 28 圆角,1–6 行自动增高,右下角发送 / 停止。
///
/// 两颗 40 圆键是胶囊的"端盖":四周都留 [_keyGap],单行时胶囊高 56、
/// 圆角 28 = 键半径 20 + 8,圆键与胶囊两端同心;文字在 40 高里居中。
/// 多行时键贴底,底边和侧边仍是 8。
///
/// 语音([voice]):草稿为空时发送键是麦克风(和 ＋ 键同样的淡底圆);
/// 听写时 ＋ 换成 ✕(取消)、发送键换成主色的停止键,中间文字处显示
/// 识别结果,停止键左边是音量条。四颗键始终同一位置、同一尺寸。
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.connected,
    required this.running,
    required this.onSend,
    required this.onStop,
    this.focusNode,
    this.busy = false,
    this.stopping = false,
    this.sessionReady = true,
    this.accessory,
    this.leading,
    this.tray,
    this.hasAttachments = false,
    this.onSendOptions,
    this.voice,
    this.onKeyEvent,
    this.placeholder,
    this.waiting = false,
    this.waitHint,
    this.onContentInserted,
    this.maxLines = 6,
    this.hardwareEnterSends = false,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;

  /// 已连上 DSH。没连上时可以先打字,但发不出去。
  final bool connected;

  /// 本轮正在生成:输入为空时发送键变成停止键。
  final bool running;

  /// 正在建会话 / 提交中:挡住连点。
  final bool busy;

  /// Stop was asked for: the stop key turns busy until the turn ends.
  final bool stopping;

  /// Ordinary send/stop controls require an applied session snapshot.
  final bool sessionReady;
  final VoidCallback onSend;
  final VoidCallback onStop;

  /// 发送键左边的小件(上下文环),40dp 高,底对齐。
  final Widget? accessory;

  /// 输入框左边的 40dp 件(＋ 附件)。
  final Widget? leading;

  /// 输入框上方的一条(引文、待发送的附件):出现时展开,拿掉时收起。
  final Widget? tray;

  /// 有附件时,没有文字也能发送。
  final bool hasAttachments;

  /// 长按发送键:生成中可选插话 / 停下先处理 / 排队。
  final VoidCallback? onSendOptions;

  /// 语音输入;null 或不可用时没有麦克风。
  final VoiceInputController? voice;

  /// Hardware keys in the text field first go here (the `@` picker's
  /// arrows / Enter / Esc).
  final FocusOnKeyEventCallback? onKeyEvent;

  /// The idle hint (「给 Chief 发消息…」 in a Bot chat); 「给 DSH 发消息…」
  /// by default.
  final String? placeholder;

  /// An approval or a question is waiting: the stop key steps back (the
  /// card's button is the one primary key) and the hint stops saying the
  /// turn is generating.
  final bool waiting;

  /// What the placeholder says while [waiting] (「等你回答」); null keeps the
  /// plain one.
  final String? waitHint;

  /// Images from the keyboard (screenshots, stickers); null takes none.
  final ValueChanged<KeyboardInsertedContent>? onContentInserted;

  /// Visible editor lines. Multiline text remains scrollable when limited.
  final int maxLines;

  /// Opt-in physical Enter-to-send; never changes the software IME action.
  final bool hardwareEnterSends;

  /// Editor lines for a page whose [pageContext] still carries the keyboard
  /// inset: six, or as many as fit in two fifths of the height above the
  /// keyboard at the current text size, never under two (two keep newlines
  /// and the field's own scrolling). A phone on its side with the keyboard
  /// up, or very large text, would otherwise push the chat to nothing; an
  /// upright phone under a tall keyboard keeps six up to about 1.2× text.
  static int linesFor(BuildContext pageContext) {
    final available = MediaQuery.sizeOf(pageContext).height - MediaQuery.viewInsetsOf(pageContext).bottom;
    final fontSize = Theme.of(pageContext).textTheme.bodyLarge?.fontSize ?? 16;
    final line = MediaQuery.textScalerOf(pageContext).scale(fontSize) * _lineHeight;
    if (line <= 0 || available <= 0) return 2;
    return (available * 0.4 / line).floor().clamp(2, 6);
  }

  @override
  State<Composer> createState() => _ComposerState();
}

const double _keySize = 40;
const double _keyGap = 8;

class _ComposerState extends State<Composer> {
  Duration? _lastEscape;

  /// The last tray shown: it stays while the tray folds away.
  late Widget? _tray = widget.tray;

  void _send() {
    if (!widget.connected || !widget.sessionReady || widget.busy) return;
    HapticFeedback.lightImpact();
    widget.onSend();
  }

  void _stop() {
    if (!widget.connected || !widget.sessionReady || widget.busy || widget.stopping) return;
    HapticFeedback.mediumImpact();
    widget.onStop();
  }

  /// Hardware keyboards: Ctrl/⌘+Enter sends; optionally plain Enter does too.
  /// Shift+Enter remains a new line. IME composition never sends.
  /// Two consecutive Esc presses within 500 ms stop the turn. The pair is
  /// local to the focused, eligible editor; a single Esc never leaves it.
  KeyEventResult _hardwareKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final composing = widget.controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      _lastEscape = null;
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.escape) _lastEscape = null;
    final sendEnter =
        keys.isControlPressed ||
        keys.isMetaPressed ||
        (widget.hardwareEnterSends && !keys.isShiftPressed && !keys.isAltPressed);
    if (sendEnter && (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter)) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      final draft = widget.controller.text.trim().isNotEmpty || widget.hasAttachments;
      final dictating = widget.voice?.active ?? false;
      if (draft && widget.connected && !widget.busy && !dictating) _send();
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.ignored;
    if (key != LogicalKeyboardKey.escape || !widget.running) {
      _lastEscape = null;
      return KeyEventResult.ignored;
    }
    if (!widget.sessionReady || !widget.connected || widget.busy || widget.stopping) {
      _lastEscape = null;
      return KeyEventResult.handled;
    }
    final last = _lastEscape;
    _lastEscape = event.timeStamp;
    if (last != null && event.timeStamp - last <= const Duration(milliseconds: 500)) {
      _lastEscape = null;
      _stop();
    }
    return KeyEventResult.handled;
  }

  @override
  void initState() {
    super.initState();
    widget.voice?.onMessage = _voiceMessage;
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionReady != widget.sessionReady ||
        oldWidget.connected != widget.connected ||
        oldWidget.running != widget.running ||
        oldWidget.controller != widget.controller ||
        oldWidget.focusNode != widget.focusNode ||
        oldWidget.busy != widget.busy ||
        oldWidget.stopping != widget.stopping) {
      _lastEscape = null;
    }
    _tray = widget.tray ?? _tray;
    if (oldWidget.voice != widget.voice) {
      if (oldWidget.voice?.onMessage == _voiceMessage) {
        oldWidget.voice?.onMessage = null;
      }
      widget.voice?.onMessage = _voiceMessage;
    }
  }

  @override
  void dispose() {
    if (widget.voice?.onMessage == _voiceMessage) {
      widget.voice?.onMessage = null;
    }
    super.dispose();
  }

  void _voiceMessage(VoiceMessage message) {
    if (!mounted) return;
    final voice = widget.voice;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message.text),
          persist: false,
          action: message.openSettings && voice != null
              ? SnackBarAction(label: appL10n.chatGoToSettings, onPressed: () => voice.bridge.openSettings())
              : message.change
              ? SnackBarAction(
                  label: appL10n.nearbyChange,
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VoiceSettingsPage())),
                )
              : null,
        ),
      );
  }

  void _startVoice() {
    final voice = widget.voice;
    if (voice == null) return;
    // Dictation shows the text in the field; the keyboard only covers it.
    (widget.focusNode ?? FocusManager.instance.primaryFocus)?.unfocus();
    voice.start();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final textStyle = theme.textTheme.bodyLarge?.copyWith(height: _lineHeight);
    // One line centred in the keys' 40: the padding that makes it so, at
    // the current text size (very large text just grows the row).
    final line = MediaQuery.textScalerOf(context).scale(textStyle?.fontSize ?? 16) * _lineHeight;
    final textPad = math.max(4.0, (_keySize - line) / 2);
    final voice = widget.voice;
    voice?.ensureFresh();

    // The chat page's pet stands on the composer's top edge (outside a pet
    // stage this is a plain pass-through).
    return PetPerch(
      kind: PerchKind.composer,
      child: GlassSurface(
        tier: GlassTier.chrome,
        borderRadius: AppShape.radiusXl,
        child: ListenableBuilder(
          listenable: Listenable.merge([widget.controller, ?voice]),
          builder: (context, _) {
            final value = widget.controller.value;
            final phase = voice?.phase ?? VoicePhase.idle;
            final dictating = phase == VoicePhase.listening || phase == VoicePhase.transcribing;
            final empty = value.text.trim().isEmpty && !widget.hasAttachments;
            final showStop = widget.running && empty && !dictating;
            final showMic = !dictating && !showStop && empty && !widget.busy && (voice?.available ?? false);
            final enabled = !widget.busy && widget.connected && widget.sessionReady && (showStop || !empty);
            final waiting = widget.waiting || widget.waitHint != null;
            final hint = switch (phase) {
              VoicePhase.listening => l10n.chatListeningEllipsis,
              VoicePhase.transcribing => l10n.chatTranscribingEllipsis,
              _ =>
                !widget.connected
                    ? l10n.chatConnectToSend
                    : !widget.sessionReady
                    ? l10n.stateChatSynchronizing
                    : widget.waitHint ??
                          (widget.running && !waiting
                              ? l10n.chatGeneratingSteerHint
                              : widget.placeholder ?? l10n.chatComposerHint),
            };
            final leading = dictating
                ? VoiceCancelKey(key: const ValueKey('voice-cancel'), onPressed: voice!.cancel)
                : widget.leading;
            final accessory = dictating
                ? VoiceWaveform(level: voice!.level, active: phase == VoicePhase.listening)
                : widget.accessory;

            final _KeyMode mode;
            if (dictating) {
              mode = _KeyMode.stopVoice;
            } else if (showStop) {
              mode = _KeyMode.stopRun;
            } else if (showMic) {
              mode = _KeyMode.mic;
            } else {
              mode = _KeyMode.send;
            }
            final keyBusy =
                widget.busy ||
                (showStop && widget.stopping) ||
                phase == VoicePhase.transcribing ||
                phase == VoicePhase.starting;

            final row = Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (leading != null) ...[
                  AnimatedSwitcher(
                    duration: AppMotion.of(context, AppMotion.quick),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: ScaleTransition(scale: anim, child: child),
                    ),
                    child: KeyedSubtree(key: ValueKey(dictating), child: leading),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: _hardwareKey,
                    onFocusChange: (hasFocus) {
                      if (!hasFocus) _lastEscape = null;
                    },
                    child: Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      onKeyEvent: widget.onKeyEvent,
                      child: TextField(
                        controller: widget.controller,
                        focusNode: widget.focusNode,
                        contentInsertionConfiguration: switch (widget.onContentInserted) {
                          final onInserted? => ContentInsertionConfiguration(
                            onContentInserted: onInserted,
                            allowedMimeTypes: const ['image/png', 'image/jpeg', 'image/gif', 'image/webp'],
                          ),
                          null => null,
                        },
                        readOnly: dictating || phase == VoicePhase.starting,
                        minLines: 1,
                        maxLines: widget.maxLines,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        textCapitalization: TextCapitalization.sentences,
                        style: textStyle,
                        cursorColor: theme.colorScheme.primary,
                        decoration: InputDecoration(
                          hintText: hint,
                          hintMaxLines: 1,
                          hintStyle: theme.textTheme.bodyLarge?.copyWith(color: dsh.textTertiary, height: 1.45),
                          filled: false,
                          isDense: true,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: textPad),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (accessory != null) ...[accessory, const SizedBox(width: 2)],
                _SendButton(
                  mode: mode,
                  busy: keyBusy,
                  quiet: showStop && waiting && !widget.stopping,
                  enabled: switch (mode) {
                    _KeyMode.mic => true,
                    _KeyMode.stopVoice => phase == VoicePhase.listening,
                    _ => enabled,
                  },
                  onLongPress: mode != _KeyMode.send || !enabled ? null : widget.onSendOptions,
                  onTap: () {
                    switch (mode) {
                      case _KeyMode.stopRun:
                        _stop();
                      case _KeyMode.send:
                        _send();
                      case _KeyMode.mic:
                        _startVoice();
                      case _KeyMode.stopVoice:
                        voice?.stop();
                    }
                  },
                ),
              ],
            );
            // The tray unfolds above the text and folds away again: the
            // glass grows and shrinks, the text row never jumps.
            final content = Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExpandReveal(
                  open: widget.tray != null,
                  child: Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, _keyGap), child: _tray),
                ),
                row,
              ],
            );
            // Dictating: the pet steps away from the voice controls.
            return PetCover(
              active: dictating,
              child: Padding(
                padding: EdgeInsets.fromLTRB(leading == null ? 18 : _keyGap, _keyGap, _keyGap, _keyGap),
                child: content,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// What the right-hand key does.
enum _KeyMode {
  /// ↑ send.
  send,

  /// ■ stop the running turn.
  stopRun,

  /// 🎙 start dictating (draft empty).
  mic,

  /// ■ stop dictating and keep the text.
  stopVoice,
}

/// 40 圆键:↑ 发送 / ■ 停止(实心主色);🎙 麦克风是 ＋ 键那样的淡底圆。
/// 禁用时是 onSurface 12% 的底。
class _SendButton extends StatefulWidget {
  const _SendButton({
    required this.mode,
    required this.busy,
    required this.enabled,
    required this.onTap,
    this.onLongPress,
    this.quiet = false,
  });

  final _KeyMode mode;

  /// Drawn like the mic key (something else on screen is primary).
  final bool quiet;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final enabled = widget.enabled && !widget.busy;
    final mode = widget.mode;
    final mic = mode == _KeyMode.mic || widget.quiet;
    final active = enabled || widget.busy;
    final bg = mic
        ? colors.onSurface.withValues(alpha: 0.06)
        : active
        ? colors.primary
        : colors.onSurface.withValues(alpha: 0.12);
    final fg = mic
        ? colors.onSurface
        : active
        ? colors.onPrimary
        : colors.onSurface.withValues(alpha: 0.38);
    final (icon, size, label) = switch (mode) {
      _KeyMode.send => (AppIcons.send, 22.0, l10n.commonSend),
      _KeyMode.stopRun => (AppIcons.stopGenerating, 20.0, l10n.chatStopGenerating),
      _KeyMode.mic => (AppIcons.voice, 22.0, l10n.chatVoiceInput),
      _KeyMode.stopVoice => (AppIcons.stopGenerating, 20.0, l10n.chatStopVoiceInput),
    };
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.busy && mode == _KeyMode.stopRun ? l10n.commonStopping : label,
      child: GestureDetector(
        onTap: enabled ? widget.onTap : null,
        onLongPress: widget.onLongPress == null
            ? null
            : () {
                setState(() => _pressed = false);
                HapticFeedback.mediumImpact();
                widget.onLongPress!();
              },
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.9 : 1,
          duration: AppMotion.of(context, AppMotion.press),
          curve: AppMotion.std,
          child: AnimatedContainer(
            duration: AppMotion.of(context, AppMotion.quick),
            width: _keySize,
            height: _keySize,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            child: AnimatedSwitcher(
              duration: AppMotion.of(context, AppMotion.quick),
              transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
              child: widget.busy
                  ? Padding(
                      key: const ValueKey('busy'),
                      padding: const EdgeInsets.all(11),
                      child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                    )
                  : Icon(icon, key: ValueKey(mode), size: size, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}
