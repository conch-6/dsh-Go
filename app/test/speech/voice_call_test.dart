import 'dart:typed_data';

import 'package:dsh_app/speech/call/voice_call.dart';
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:flutter_test/flutter_test.dart';

import 'speech_fakes.dart';

class _Rig {
  _Rig({
    FakeCloud? cloud,
    bool noRecognizer = false,
    CallStart start = CallStart.ok,
    bool bargeIn = true,
    Duration confirmAfter = const Duration(milliseconds: 60),
    Duration cueAfter = const Duration(milliseconds: 40),
  }) : audio = FakeAudio(start: start),
       cloud = cloud ?? FakeCloud() {
    call = VoiceCallController(
      audio: audio,
      conversation: conversation,
      recognizer: () async => noRecognizer ? null : this.cloud,
      voice: () {
        final out = FakeOut();
        outs.add(out);
        return out;
      },
      choices: () async => (bargeIn: bargeIn, speaker: true, spokenHint: '（语音通话）'),
      cutNote: (heard) => '（被打断在：$heard）',
      thinkingCue: () async => cues++,
      confirmAfter: confirmAfter,
      cueAfter: cueAfter,
    );
  }

  final FakeAudio audio;
  final FakeCloud cloud;
  final conversation = FakeConversation();
  final outs = <FakeOut>[];
  int cues = 0;
  late final VoiceCallController call;

  static final second = Uint8List(44 + 32000);

  Future<void> say() async {
    audio.emit(const SpeechStart(over: false));
    audio.emit(Utterance(second, const Duration(seconds: 1)));
    await pumpEventQueue();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a turn: heard, sent with the hint once, the reply read as it grows', () async {
    final rig = _Rig();
    await rig.call.start();
    expect(rig.call.phase, CallPhase.listening);
    expect(rig.audio.calls, contains('callStart:bargeIn=true'));

    rig.audio.emit(const SpeechStart(over: false));
    expect(rig.call.phase, CallPhase.hearing);
    rig.audio.emit(Utterance(_Rig.second, const Duration(seconds: 1)));
    await pumpEventQueue();
    expect(rig.call.phase, CallPhase.thinking);
    expect(rig.call.heard, '今天天气怎么样');
    expect(rig.conversation.sent, ['（语音通话）\n今天天气怎么样']);

    rig.conversation.reply('北京晴，');
    expect(rig.outs, hasLength(1));
    rig.outs.single.emit(const SpeechOutStarted());
    expect(rig.call.phase, CallPhase.speaking);
    rig.conversation.reply('北京晴，最高二十度。');
    rig.conversation.reply('北京晴，最高二十度。', done: true);
    expect(rig.outs.single.added, ['北京晴，', '最高二十度。']);
    expect(rig.outs.single.finished, isTrue);
    rig.outs.single.emit(const SpeechOutDone());
    expect(rig.call.phase, CallPhase.listening);

    // The next message goes without the hint.
    rig.cloud.text = '那上海呢';
    await rig.say();
    expect(rig.conversation.sent.last, '那上海呢');
  });

  Future<_Rig> speaking({Duration confirmAfter = const Duration(milliseconds: 60)}) async {
    final rig = _Rig(confirmAfter: confirmAfter);
    await rig.call.start();
    await rig.say();
    rig.conversation.reply('好的，我来详细说一说。');
    rig.outs.single.emit(const SpeechOutStarted());
    rig.outs.single.heard = '好的，';
    return rig;
  }

  Future<void> over(_Rig rig, String said) async {
    rig.cloud.text = said;
    rig.audio.emit(const SpeechStart(over: true));
    rig.audio.emit(Utterance(_Rig.second, const Duration(milliseconds: 600)));
    await pumpEventQueue();
  }

  test('agreement over her: she steps back, then carries on; nothing is sent', () async {
    final rig = await speaking();
    rig.audio.emit(const SpeechStart(over: true));
    expect(rig.outs.single.ducks, [true]);
    expect(rig.call.phase, CallPhase.speaking);
    rig.cloud.text = '嗯嗯，对';
    rig.audio.emit(Utterance(_Rig.second, const Duration(milliseconds: 600)));
    await pumpEventQueue();
    expect(rig.outs.single.ducks, [true, false]);
    expect(rig.outs.single.stopped, isFalse);
    expect(rig.conversation.interrupts, 0);
    expect(rig.conversation.sent, hasLength(1));
    expect(rig.call.phase, CallPhase.speaking);
  });

  test('words over her: she stops, the turn too, and the next message says where she was cut off', () async {
    final rig = await speaking();
    await over(rig, '换个话题吧');
    expect(rig.outs.single.stopped, isTrue);
    expect(rig.conversation.interrupts, 1);
    expect(rig.conversation.sent.last, '（被打断在：好的，）\n换个话题吧');
  });

  test('停 over her: she stops and nothing is sent; the next message still says where', () async {
    final rig = await speaking();
    await over(rig, '等一下！');
    expect(rig.outs.single.stopped, isTrue);
    expect(rig.conversation.interrupts, 1);
    expect(rig.conversation.sent, hasLength(1));
    expect(rig.call.phase, CallPhase.listening);
    // What she was still writing is no longer read.
    rig.conversation.reply('好的，我来详细说一说。第一点', done: true);
    expect(rig.outs, hasLength(1));

    rig.cloud.text = '我想问别的';
    await rig.say();
    expect(rig.conversation.sent.last, '（被打断在：好的，）\n我想问别的');
  });

  test('talking on over her takes the turn before the words are known', () async {
    // Long enough that a busy machine cannot reach it before the first check.
    final rig = await speaking(confirmAfter: const Duration(milliseconds: 500));
    rig.audio.emit(const SpeechStart(over: true));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(rig.outs.single.stopped, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(rig.outs.single.stopped, isTrue);
    expect(rig.conversation.interrupts, 1);
    expect(rig.call.phase, CallPhase.hearing);
    rig.call.hangUp();
  });

  test('a slow answer gets the thinking cue once; a quick one none', () async {
    final rig = _Rig(cueAfter: const Duration(milliseconds: 400));
    await rig.call.start();
    await rig.say();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(rig.cues, 1);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(rig.cues, 1);

    rig.conversation.reply('好。', done: true);
    rig.outs.single
      ..emit(const SpeechOutStarted())
      ..emit(const SpeechOutDone());
    rig.cloud.text = '再说一个';
    await rig.say();
    rig.conversation.reply('行，');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(rig.cues, 1);
    rig.call.hangUp();
  });

  test('live words show while the person speaks, and stand in until the recognizer answers', () async {
    final rig = _Rig();
    await rig.call.start();
    rig.audio.emit(const SpeechStart(over: false));
    rig.call.live('今天天气');
    expect(rig.call.heard, '今天天气');
    rig.call.live('今天天气怎么样');
    rig.audio.emit(Utterance(_Rig.second, const Duration(seconds: 1)));
    expect(rig.call.heard, '今天天气怎么样');
    await pumpEventQueue();
    expect(rig.conversation.sent.single, endsWith('今天天气怎么样'));
  });

  test('over her, a few live words take the turn at once; agreement does not', () async {
    final rig = await speaking();
    rig.audio.emit(const SpeechStart(over: true));
    rig.call.live('嗯嗯');
    expect(rig.outs.single.stopped, isFalse);
    rig.call.live('换个话题');
    expect(rig.outs.single.stopped, isTrue);
    expect(rig.conversation.interrupts, 1);
    expect(rig.call.phase, CallPhase.hearing);
  });

  test('the caption follows her voice; all of it once she is skipped', () async {
    final rig = await speaking();
    expect(rig.call.caption, '');
    rig.outs.single.emit(const SpeechOutLevel(0.4));
    expect(rig.call.caption, '好的，');
    rig.call.skip();
    expect(rig.call.caption, '好的，我来详细说一说。');
  });

  test('a knock is not a sentence', () async {
    final rig = _Rig();
    await rig.call.start();
    rig.audio.emit(const SpeechStart(over: false));
    rig.audio.emit(Utterance(_Rig.second, const Duration(milliseconds: 200)));
    await pumpEventQueue();
    expect(rig.cloud.heard, isEmpty);
    expect(rig.call.phase, CallPhase.listening);
  });

  test('nothing recognized: back to listening, nothing sent', () async {
    final rig = _Rig(cloud: FakeCloud(''));
    await rig.call.start();
    await rig.say();
    expect(rig.conversation.sent, isEmpty);
    expect(rig.call.phase, CallPhase.listening);
  });

  test('recognition fails: the call goes on and says why', () async {
    final cloud = FakeCloud()..fail = const DeepSeekSpeechError(DeepSeekSpeechFailure.insufficientBalance);
    final rig = _Rig(cloud: cloud);
    await rig.call.start();
    await rig.say();
    expect(rig.call.phase, CallPhase.listening);
    expect(rig.call.error, isA<DeepSeekSpeechError>());
  });

  test('a reply with nothing to say (tools only) returns to listening', () async {
    final rig = _Rig();
    await rig.call.start();
    await rig.say();
    rig.conversation.reply('', done: true);
    expect(rig.outs, isEmpty);
    expect(rig.call.phase, CallPhase.listening);
  });

  test('no recognizer, no permission: it ends and says so', () async {
    final none = _Rig(noRecognizer: true);
    await none.call.start();
    expect(none.call.phase, CallPhase.ended);
    expect(none.call.ended, CallEnd.noRecognizer);
    expect(none.audio.calls, isNot(contains('callStart:bargeIn=true')));

    final denied = _Rig(start: CallStart.permission);
    await denied.call.start();
    expect(denied.call.ended, CallEnd.permission);
  });

  test('mute, loudspeaker and hang up reach the native side', () async {
    final rig = _Rig(bargeIn: false);
    await rig.call.start();
    expect(rig.audio.calls, contains('callStart:bargeIn=false'));
    rig.call.setMuted(true);
    expect(rig.call.muted, isTrue);
    await rig.call.setSpeaker(false);
    expect(rig.call.speaker, isFalse);
    rig.call.hangUp();
    expect(rig.call.phase, CallPhase.ended);
    expect(rig.audio.calls, containsAllInOrder(['mute:true', 'speaker:false', 'callStop']));
  });

  test('skip: she stops, the call listens again', () async {
    final rig = _Rig();
    await rig.call.start();
    await rig.say();
    rig.conversation.reply('一段很长的回答。');
    rig.outs.single.emit(const SpeechOutStarted());
    rig.call.skip();
    expect(rig.outs.single.stopped, isTrue);
    expect(rig.call.phase, CallPhase.listening);
    expect(rig.conversation.interrupts, 0);
  });
}
