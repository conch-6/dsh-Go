// 语音通话: one page over the conversation, lit like Siri but quieter: a
// sphere of clear glass with soft colour drifting inside, the same colour
// running faintly round the screen's edge, all of it made from the theme's
// colour and following its light or dark (call/call_visuals.dart). Behind it a dark field, the person's own picture,
// or 伙伴小屋's character mouthing the reply (call/call_backdrop.dart). What was
// heard and what she says arrive underneath; mute, hang up and loudspeaker sit
// at the bottom; an approval or question the conversation waits on comes up
// above them and is answered right here.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_voice.dart';
import '../../companion/companion_voice_source.dart';
import '../../l10n/l10n.dart';
import '../../performance/performance_state.dart';
import '../../speech/call/chat_call.dart';
import '../../speech/call/thinking_cue.dart';
import '../../speech/call/voice_call.dart';
import '../../speech/deepseek_speech.dart';
import '../../speech/read_aloud.dart';
import '../../speech/speech_audio.dart';
import '../../speech/speech_out.dart';
import '../../speech/speech_settings.dart';
import '../../speech/voice_cloud.dart';
import '../../state/voice_state.dart';
import '../chat/voice/voice_bridge.dart';
import '../companion/companion_ask.dart';
import '../companion/companion_stage.dart';
import '../fx/voice_ring/voice_ring.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../../state/streaming_asr_model_state.dart';
import '../../state/streaming_asr_state.dart';
import '../../state/streaming_pcm_state.dart';
import '../../voice/live_words.dart';
import '../../voice/streaming_pcm.dart';
import 'call/call_backdrop.dart';
import 'call/call_parts.dart';
import 'call/call_visuals.dart';
import 'speech_ui.dart';

/// Opens a call with the main chat's conversation. [session] gives its id,
/// creating it for a new chat; [title] heads the page.
Future<void> openChatCall(BuildContext context, {required String title, required Future<String?> Function() session}) {
  final container = ProviderScope.containerOf(context, listen: false);
  container.read(readAloudProvider.notifier).stop();
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: true,
      fullscreenDialog: true,
      transitionDuration: AppMotion.of(context, const Duration(milliseconds: 520)),
      reverseTransitionDuration: AppMotion.of(context, AppMotion.collapse),
      pageBuilder: (_, _, _) => VoiceCallPage(title: title, conversation: ChatCallConversation(container, session)),
      transitionsBuilder: (_, animation, _, child) {
        final curve = CurvedAnimation(parent: animation, curve: AppMotion.enter, reverseCurve: AppMotion.exit);
        // Opening: the page rises out of the dark.
        return FadeTransition(
          opacity: curve,
          child: ScaleTransition(scale: Tween(begin: 1.06, end: 1.0).animate(curve), child: child),
        );
      },
    ),
  );
}

class VoiceCallPage extends ConsumerStatefulWidget {
  const VoiceCallPage({super.key, required this.title, required this.conversation});

  final String title;
  final CallConversation conversation;

  @override
  ConsumerState<VoiceCallPage> createState() => _VoiceCallPageState();
}

class _VoiceCallPageState extends ConsumerState<VoiceCallPage> with WidgetsBindingObserver, TickerProviderStateMixin {
  late final VoiceCallController _call;
  final _scene = CallScene();
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  Timer? _leave;
  DateTime? _since;
  CallPhase _shown = CallPhase.starting;

  // Her, when she is the backdrop.
  final _stage = CompanionStageController();
  bool _stageReady = false;
  bool _stageFailed = false;
  double _mouthAt = 0;
  bool _mouthOpen = false;

  /// A finger on the light: it gives a little.
  bool _pressed = false;

  /// The system asks for less motion (read each build): the light holds still
  /// and the page comes in without its staggered rise.
  bool _still = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final callSettings = ref.read(callSettingsProvider.notifier);
    final voices = ref.read(speechVoiceSettingsProvider.notifier);
    // The chosen voice, as soon as the settings have been read (the first reply comes later).
    var voice = ref.read(speechVoiceSettingsProvider) ?? voices.defaults;
    final speaker = ref.read(speechSpeakerProvider);
    final audio = ref.read(speechAudioProvider);
    final deepseek = ref.read(deepSeekSpeechProvider);
    final recognize = ref.read(callRecognizerProvider);
    final bridge = ref.read(voiceBridgeProvider);
    _call = VoiceCallController(
      audio: audio,
      conversation: widget.conversation,
      recognizer: () async {
        voice = await voices.ready();
        // The phone's own voice warms up while the recognizer is found.
        if (voice.source != CompanionVoiceSource.deepseek) unawaited(speaker.ready(voice));
        return recognize();
      },
      voice: () => speechOutFor(voice, deepseek: deepseek, audio: audio, speaker: speaker, call: true, levels: true),
      // The saved ones, not the defaults shown while they load (a first call after launch).
      choices: () async {
        final saved = await callSettings.ready();
        return (
          bargeIn: saved.bargeIn,
          speaker: saved.speaker,
          spokenHint: saved.spoken ? appL10n.speechCallHint : null,
        );
      },
      permission: () async => await bridge.requestPermission() == VoicePermission.granted,
      cutNote: (heard) => heard.isEmpty ? appL10n.speechCallCutEarly : appL10n.speechCallCutNote(heard),
      thinkingCue: () async {
        // Asked again after the settings: her voice may have begun meanwhile.
        if ((await callSettings.ready()).cue && _call.cueStill) await playThinkingCue(audio);
      },
    )..addListener(_changed);
    HapticFeedback.mediumImpact();
    _enter.forward();
    unawaited(_start());
  }

  /// Live captions, once the call listens, when the streaming model is on the phone.
  LiveWords? _live;

  Future<void> _start() async {
    final pcm = ref.read(streamingPcmCaptureProvider);
    final asr = ref.read(streamingAsrProvider);
    final store = ref.read(streamingAsrModelStoreProvider.future);
    await _call.start();
    try {
      final model = await (await store).installed();
      if (model == null || !mounted || _call.phase == CallPhase.ended) return;
      final live = _live = LiveWords(pcm, asr, model, StreamingPcmSource.call, _call.live);
      await live.start();
    } on Object {
      // Without live captions the call goes on as before.
      _live = null;
    }
  }

  void _changed() {
    if (!mounted) return;
    final phase = _call.phase;
    if (phase != _shown) {
      _arrived(phase);
      _shown = phase;
    }
    if (phase == CallPhase.ended && _leave == null) {
      // Hung up: the light sinks away first. Ended for a reason: the reason stays a moment.
      _leave = Timer(
        _call.ended == CallEnd.hungUp ? const Duration(milliseconds: 380) : const Duration(milliseconds: 2600),
        () {
          if (mounted) Navigator.of(context).maybePop();
        },
      );
    }
    setState(() {});
  }

  /// A new phase: a touch under the finger, and her mood when she is there.
  void _arrived(CallPhase phase) {
    switch (phase) {
      case CallPhase.listening when _since == null:
        _since = DateTime.now();
        HapticFeedback.lightImpact();
      case CallPhase.hearing:
        HapticFeedback.selectionClick();
      case CallPhase.speaking:
        HapticFeedback.lightImpact();
      case CallPhase.ended:
        HapticFeedback.mediumImpact();
      default:
        break;
    }
    if (_stageReady) {
      _stage.command('mood', {
        'mood': switch (phase) {
          CallPhase.thinking || CallPhase.starting => 'thinking',
          CallPhase.speaking => 'speaking',
          CallPhase.ended => 'idle',
          _ => 'listening',
        },
      });
      if (phase != CallPhase.speaking) _stage.command('quiet');
    }
  }

  void _tick(double seconds) {
    _scene.tick(
      seconds,
      phase: _call.phase,
      mic: _call.micLevel,
      voice: _call.voiceLevel,
      isMuted: _call.muted,
      still: _still,
    );
    // Her mouth follows the voice, twenty times a second at most.
    if (_stageReady && seconds - _mouthAt > 0.05) {
      final speaking = _call.phase == CallPhase.speaking;
      final open = speaking ? (_scene.level * 1.3).clamp(0.0, 1.0) : 0.0;
      if (speaking || _mouthOpen) {
        _stage.command('mouth', {'value': open});
        _mouthOpen = open > 0;
        _mouthAt = seconds;
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) _call.backgrounded();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_live?.stop());
    _leave?.cancel();
    _enter.dispose();
    _call
      ..removeListener(_changed)
      ..dispose();
    _scene.dispose();
    super.dispose();
  }

  void _hangUp() {
    HapticFeedback.heavyImpact();
    _call.hangUp();
  }

  (String, bool) _status(L10n l10n) {
    if (_call.phase == CallPhase.ended) {
      return (
        switch (_call.ended) {
          CallEnd.permission => l10n.speechCallEndPermission,
          CallEnd.microphone => l10n.speechCallEndMicrophone,
          CallEnd.noRecognizer => l10n.speechCallEndNoRecognizer,
          CallEnd.background => l10n.speechCallEndBackground,
          CallEnd.failed => l10n.speechCallEndFailed,
          CallEnd.hungUp || null => l10n.speechCallEnded,
        },
        false,
      );
    }
    if (_call.muted && _call.phase != CallPhase.speaking && _call.phase != CallPhase.thinking) {
      return (l10n.speechCallMuted, false);
    }
    return switch (_call.phase) {
      CallPhase.starting => (l10n.speechCallStarting, true),
      CallPhase.listening => (l10n.speechCallListening, true),
      CallPhase.hearing => (l10n.speechCallHearing, false),
      CallPhase.thinking => (l10n.speechCallThinking, true),
      CallPhase.speaking => (l10n.speechCallSpeaking, false),
      CallPhase.ended => (l10n.speechCallEnded, false),
    };
  }

  /// The light in the middle: Libraries.dev's voice ring (its ribbon or its single line),
  /// listening to the person, speaking with her voice, turning while it thinks; or the glass orb.
  Widget _light(CallVisual visual, CallPalette palette, bool dark, double size) {
    if (visual == CallVisual.glass) {
      return CallLight(key: const ValueKey('glass'), scene: _scene, palette: palette, size: size);
    }
    final phase = _call.phase;
    return VoiceRing(
      key: ValueKey(visual),
      type: visual == CallVisual.mono ? VoiceRingType.mono : VoiceRingType.ring,
      state: switch (phase) {
        CallPhase.starting || CallPhase.thinking => VoiceRingState.processing,
        CallPhase.listening || CallPhase.hearing => VoiceRingState.listening,
        CallPhase.speaking => VoiceRingState.speaking,
        CallPhase.ended => VoiceRingState.idle,
      },
      size: size * 0.82,
      theme: dark ? VoiceRingTheme.dark : VoiceRingTheme.light,
      paused: phase == CallPhase.ended,
      level: () => switch (_call.phase) {
        CallPhase.hearing when !_call.muted => VoiceRingLevel.mic(_call.micLevel),
        CallPhase.speaking => VoiceRingLevel.playback(_call.voiceLevel),
        _ => 0,
      },
    );
  }

  /// [child] coming in with the page: a fade and a short rise, starting at [from] (0–1).
  Widget _rise(double from, Widget child, {double distance = 18}) {
    if (_still) return child;
    final curve = CurvedAnimation(
      parent: _enter,
      curve: Interval(from, math.min(1, from + 0.5), curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: curve,
      builder: (context, child) => Opacity(
        opacity: curve.value,
        child: Transform.translate(offset: Offset(0, (1 - curve.value) * distance), child: child),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    _still = AppMotion.reduced(context);
    final settings = ref.watch(callSettingsProvider);
    final blur = ref.watch(performanceDefaultsProvider).blur;
    final ended = _call.phase == CallPhase.ended;
    final image =
        settings.backdrop == CallBackdrop.image && settings.image.isNotEmpty && File(settings.image).existsSync()
        ? settings.image
        : null;
    final her = settings.backdrop == CallBackdrop.companion && !_stageFailed;
    final (status, dots) = _status(l10n);
    final error = _call.error;
    final sessionId = switch (widget.conversation) {
      final ChatCallConversation chat => chat.sessionId,
      _ => null,
    };
    final width = MediaQuery.sizeOf(context).width;
    // Light or dark as the theme is; a picture or her behind always reads as dark.
    final dark = theme.brightness == Brightness.dark || image != null || her;
    final palette = CallPalette.of(theme.colorScheme, light: !dark);
    final ink = CallInk(dark: dark, child: const SizedBox());

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: CallInk(
        dark: dark,
        child: Scaffold(
          backgroundColor: palette.field,
          body: CallClock(
            onTick: _tick,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CallField(scene: _scene, palette: palette, center: her ? 0.66 : 0.4),
                // A new backdrop fades in over the old one.
                AnimatedSwitcher(
                  duration: AppMotion.of(context, AppMotion.slow),
                  switchInCurve: AppMotion.enter,
                  switchOutCurve: AppMotion.exit,
                  child: switch ((image, her)) {
                    (final path?, _) => ImageBackdrop(key: ValueKey(path), path: path, blur: blur),
                    (_, true) => CompanionBackdrop(
                      key: const ValueKey('her'),
                      controller: _stage,
                      onReady: () {
                        if (!mounted) return;
                        setState(() => _stageReady = true);
                        _arrived(_call.phase);
                      },
                      onFailed: () {
                        if (mounted) {
                          setState(() {
                            _stageFailed = true;
                            _stageReady = false;
                          });
                        }
                      },
                    ),
                    _ => const SizedBox.expand(key: ValueKey('sea')),
                  },
                ),
                // The screen's edge glows only with the glass orb; the ring is light enough on its own.
                if (settings.visual == CallVisual.glass) CallEdgeGlow(scene: _scene, palette: palette),
                if (her)
                  // Her feet fade into the water so the words below stay readable.
                  const IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00030712), Color(0x00030712), Color(0xD9030712), Color(0xF2030712)],
                          stops: [0, 0.46, 0.7, 1],
                        ),
                      ),
                    ),
                  ),
                SafeArea(
                  child: Column(
                    children: [
                      _rise(
                        0.05,
                        _TopBar(
                          title: widget.title,
                          since: _since,
                          live: !ended && _since != null,
                          onBackdrop: ended ? null : () => unawaited(showCallBackdropSheet(context)),
                        ),
                        distance: -14,
                      ),
                      Expanded(
                        child: her
                            ? const SizedBox.expand()
                            : Center(
                                child: Semantics(
                                  button: _call.phase == CallPhase.speaking,
                                  label: status,
                                  hint: _call.phase == CallPhase.speaking ? l10n.speechCallSkipHint : null,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTapDown: (_) => setState(() => _pressed = true),
                                    onTapUp: (_) => setState(() => _pressed = false),
                                    onTapCancel: () => setState(() => _pressed = false),
                                    onTap: _call.phase == CallPhase.speaking
                                        ? () {
                                            HapticFeedback.lightImpact();
                                            _call.skip();
                                          }
                                        : null,
                                    child: AnimatedScale(
                                      scale: _pressed ? 0.93 : 1,
                                      duration: AppMotion.of(
                                        context,
                                        _pressed ? AppMotion.press : const Duration(milliseconds: 420),
                                      ),
                                      curve: _pressed ? Curves.easeOut : Curves.elasticOut,
                                      child: AnimatedSwitcher(
                                        duration: AppMotion.of(context, AppMotion.slow),
                                        child: _light(settings.visual, palette, dark, math.min(340, width * 0.86)),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                      _rise(
                        0.3,
                        CallStatus(
                          text: status,
                          dots: dots,
                          color: ended && _call.ended != CallEnd.hungUp ? ink.warn : null,
                        ),
                      ),
                      const SizedBox(height: 14),
                      HeardLine(text: ended ? '' : _call.heard),
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: error != null && !ended
                            ? SizedBox(
                                height: 80,
                                child: Center(
                                  child: Text(
                                    speechErrorText(l10n, error, listening: true),
                                    key: const ValueKey('call-error'),
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodyMedium?.copyWith(color: ink.warn),
                                  ),
                                ),
                              )
                            : RevealText(
                                key: const ValueKey('call-reply'),
                                text: speakable(_call.caption).replaceAll('\n', ' '),
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: ink.fg.withValues(alpha: 0.92),
                                  height: 1.55,
                                  fontSize: 17,
                                ),
                              ),
                      ),
                      if (sessionId != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: CompanionAsk(sessionId: sessionId),
                        ),
                      const SizedBox(height: 22),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _rise(
                            0.4,
                            CallKey(
                              key: const ValueKey('call-mute'),
                              icon: _call.muted ? AppIcons.micMuted : AppIcons.voice,
                              label: _call.muted ? l10n.speechCallUnmute : l10n.speechCallMute,
                              on: _call.muted,
                              blur: blur,
                              onTap: ended ? null : () => _call.setMuted(!_call.muted),
                            ),
                            distance: 28,
                          ),
                          _rise(
                            0.48,
                            HangUpKey(
                              key: const ValueKey('call-hang-up'),
                              icon: AppIcons.hangUp,
                              label: l10n.speechCallHangUp,
                              onTap: ended ? null : _hangUp,
                            ),
                            distance: 34,
                          ),
                          _rise(
                            0.56,
                            CallKey(
                              key: const ValueKey('call-speaker'),
                              icon: _call.speaker ? AppIcons.readAloud : AppIcons.earpiece,
                              label: _call.speaker ? l10n.speechCallSpeakerOn : l10n.speechCallEarpiece,
                              on: _call.speaker,
                              blur: blur,
                              onTap: ended ? null : () => unawaited(_call.setSpeaker(!_call.speaker)),
                            ),
                            distance: 28,
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The conversation's name, the clock, and the 背景 key.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.title, required this.since, required this.live, required this.onBackdrop});

  final String title;
  final DateTime? since;
  final bool live;
  final VoidCallback? onBackdrop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 14, 0),
      child: Row(
        children: [
          const SizedBox(width: 40),
          Expanded(
            child: Column(
              children: [
                Text(
                  title,
                  key: const ValueKey('call-title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: CallInk.of(context).fg,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 6),
                CallTimer(since: since, live: live),
              ],
            ),
          ),
          Semantics(
            button: true,
            label: context.l10n.speechBackdropTitle,
            child: GestureDetector(
              key: const ValueKey('call-backdrop'),
              onTap: onBackdrop == null
                  ? null
                  : () {
                      HapticFeedback.selectionClick();
                      onBackdrop!();
                    },
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: CallInk.of(context).glass,
                  border: Border.all(color: CallInk.of(context).glassBorder),
                ),
                child: Icon(
                  AppIcons.theme,
                  size: 18,
                  color: CallInk.of(context).fg.withValues(alpha: onBackdrop == null ? 0.35 : 0.8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
