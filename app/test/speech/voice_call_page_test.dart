import 'dart:typed_data';

import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/speech_settings.dart';
import 'package:dsh_app/speech/call/voice_call.dart';
import 'package:dsh_app/speech/voice_cloud.dart';
import 'package:dsh_app/state/voice_state.dart';
import 'package:dsh_app/ui/speech/call/call_backdrop.dart';
import 'package:dsh_app/ui/speech/call/call_parts.dart';
import 'package:dsh_app/ui/speech/call/call_visuals.dart';
import 'package:dsh_app/ui/speech/voice_call_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/composer_fakes.dart';
import '../chat/support/harness.dart';
import 'speech_fakes.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// [still]: the system asks for less motion. [opened] runs on the page's first frame.
  Future<(FakeAudio, FakeConversation)> pumpCall(
    WidgetTester tester, {
    List<Override> extra = const [],
    bool still = false,
    void Function()? opened,
  }) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final audio = FakeAudio();
    final conversation = FakeConversation();
    await tester.pumpWidget(
      testApp(
        Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => MediaQuery(
                        data: MediaQuery.of(context).copyWith(disableAnimations: still),
                        child: VoiceCallPage(title: '周末去哪儿玩', conversation: conversation),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
        overrides: [
          speechAudioProvider.overrideWithValue(audio),
          callRecognizerProvider.overrideWithValue(() async => FakeCloud('这周末北京天气怎么样')),
          voiceBridgeProvider.overrideWithValue(FakeVoiceBridge()),
          deepSeekSpeechProvider.overrideWithValue(() async => FakeDeepSeek()),
          ...extra,
        ],
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    opened?.call();
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      // The saved voice is read with real async work before the call starts listening.
      if (i % 5 == 0) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    return (audio, conversation);
  }

  testWidgets('a turn on the page: heard, sent, the reply arriving; hang up closes it', (tester) async {
    final (audio, conversation) = await pumpCall(tester);
    expect(find.text('周末去哪儿玩'), findsOneWidget);
    expect(audio.calls, contains('callStart:bargeIn=true'));
    expect(find.text('在听'), findsOneWidget);

    audio.emit(const SpeechStart(over: false));
    audio.emit(Utterance(Uint8List(32044), const Duration(seconds: 2)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('这周末北京天气怎么样'), findsOneWidget);
    expect(conversation.sent.single, endsWith('这周末北京天气怎么样'));

    conversation.reply('北京晴，最高二十度。');
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    // The caption follows her voice: nothing before it plays, all of it once played.
    expect(tester.widget<RevealText>(find.byType(RevealText)).text, isEmpty);
    final id = RegExp(r'^open:(\S+):call=true$').firstMatch(audio.calls.lastWhere((c) => c.startsWith('open:')))![1]!;
    audio
      ..emit(PlayEvent(id, PlayPhase.start))
      ..emit(PlayEvent(id, PlayPhase.done));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(tester.widget<RevealText>(find.byType(RevealText)).text, '北京晴，最高二十度。');

    await tester.tap(find.byKey(const ValueKey('call-hang-up')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(audio.calls, contains('callStop'));
    expect(find.byType(VoiceCallPage), findsNothing);
  });

  testWidgets('mute and loudspeaker keys switch and say so', (tester) async {
    final (audio, _) = await pumpCall(tester);
    await tester.tap(find.byKey(const ValueKey('call-mute')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(audio.calls, contains('mute:true'));
    expect(find.text('取消静音'), findsOneWidget);
    expect(find.text('已静音'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('call-speaker')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(audio.calls, contains('speaker:false'));
    expect(find.text('听筒'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('call-hang-up')));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('背景: the water by default; a picture once picked; her only when she lives here', (tester) async {
    final (_, _) = await pumpCall(tester, extra: [callBackdropPickerProvider.overrideWithValue(() async => null)]);
    await tester.tap(find.byKey(const ValueKey('call-backdrop')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('通话背景'), findsOneWidget);
    expect(find.text('深海'), findsOneWidget);
    expect(find.text('选一张图'), findsOneWidget);
    // No companion pack in tests: her card is there but can't be chosen.
    await tester.tap(find.byKey(const ValueKey('backdrop-companion')));
    await tester.pump(const Duration(milliseconds: 300));
    final container = ProviderScope.containerOf(tester.element(find.byType(VoiceCallPage)));
    expect(container.read(callSettingsProvider).backdrop, CallBackdrop.sea);
    await tester.tapAt(const Offset(20, 20));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byKey(const ValueKey('call-hang-up')));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the first call after launch keeps the saved earpiece and no barge-in', (tester) async {
    SharedPreferences.setMockInitialValues({'speech_call_v1': '{"speaker":false,"bargeIn":false}'});
    final (audio, _) = await pumpCall(tester);
    expect(audio.calls, contains('callStart:bargeIn=false'));
    expect(audio.calls, contains('speaker:false'));
    expect(audio.calls, isNot(contains('speaker:true')));
    expect(find.text('听筒'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('call-hang-up')));
    await tester.pump(const Duration(seconds: 1));
  });

  for (final still in [false, true]) {
    testWidgets(still ? 'less motion: the keys are there at once' : 'the keys rise in with the page', (tester) async {
      final hangUp = find.byKey(const ValueKey('call-hang-up'));
      double? first;
      await pumpCall(
        tester,
        still: still,
        opened: () => first = tester
            .widgetList<Opacity>(find.ancestor(of: hangUp, matching: find.byType(Opacity)))
            .fold<double>(1.0, (low, o) => o.opacity < low ? o.opacity : low),
      );
      expect(first, still ? 1.0 : lessThan(0.5));
      await tester.tap(hangUp);
      await tester.pump(const Duration(seconds: 1));
    });
  }

  test('less motion: the colours hold still; only a voice changes the size', () {
    final scene = CallScene();
    addTearDown(scene.dispose);
    for (var t = 0.0; t < 2; t += 0.05) {
      scene.tick(t, phase: CallPhase.listening, mic: 0, voice: 0, isMuted: false, still: true);
    }
    expect(scene.flow, 0);
    expect(scene.scale, 1);
    for (var t = 2.0; t < 3; t += 0.05) {
      scene.tick(t, phase: CallPhase.hearing, mic: 0.8, voice: 0, isMuted: false, still: true);
    }
    expect(scene.flow, 0);
    expect(scene.scale, greaterThan(1.05));

    final moving = CallScene();
    addTearDown(moving.dispose);
    for (var t = 0.0; t < 2; t += 0.05) {
      moving.tick(t, phase: CallPhase.listening, mic: 0, voice: 0, isMuted: false);
    }
    expect(moving.flow, greaterThan(0.4));
  });

  test('a backdrop choice is kept', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(callSettingsProvider);
    await Future<void>.delayed(Duration.zero);
    await container
        .read(callSettingsProvider.notifier)
        .update(const CallSettings(backdrop: CallBackdrop.image, image: '/x/backdrop-1.jpg'));
    final again = ProviderContainer();
    addTearDown(again.dispose);
    again.read(callSettingsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(again.read(callSettingsProvider).backdrop, CallBackdrop.image);
    expect(again.read(callSettingsProvider).image, '/x/backdrop-1.jpg');
  });
}
