import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/companion/companion_adapt.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A model as the stage reports it: a few parameters named like a real one.
Map<String, Object?> probeJson({
  String zonesFrom = 'default',
  String emotionsFrom = 'default',
  List<String> missing = const ['ParamEyeLOpen', 'ParamEyeROpen'],
  bool adapter = false,
  List<String> tail = const [],
}) => {
  'moc': 'model/m.moc3',
  'mocVersion': 5,
  'parameterCount': 5,
  'params': [
    {'id': 'PARAM_ANGLE_X', 'name': '角度 X', 'group': '脸', 'min': -30, 'max': 30, 'def': 0},
    {'id': 'EyeOpenL', 'name': '左眼 开闭', 'group': '眼睛', 'min': 0, 'max': 1, 'def': 1},
    {'id': 'EyeOpenR', 'name': '右眼 开闭', 'group': '眼睛', 'min': 0, 'max': 1, 'def': 1},
    {'id': 'TailSwing', 'name': '尾巴 摆动', 'group': '尾巴', 'min': -1, 'max': 1, 'def': 0},
    {'id': 'Watermark', 'name': '水印', 'group': '开关', 'min': 0, 'max': 1, 'def': 1},
  ],
  'parts': [
    {'id': 'PartHead', 'name': '头'},
  ],
  'expressions': ['开心', '脸红', '水印消除'],
  'motions': ['挥手', 'Idle'],
  'linked': {
    'ParamAngleX': ['PARAM_ANGLE_X'],
  },
  'missing': missing,
  'zonesFrom': zonesFrom,
  'emotionsFrom': emotionsFrom,
  'tail': tail,
  'adapter': adapter,
  'name': '小鱼',
};

CompanionProbe probe([Map<String, Object?>? json]) => CompanionProbe.fromJson(json ?? probeJson())!;

String sse(String text) =>
    'event: content_block_delta\ndata: ${jsonEncode({
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'text_delta', 'text': text},
    })}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the stage report, read', () {
    final p = probe();
    expect(p.moc, 'model/m.moc3');
    expect(p.params.map((x) => x.id), contains('EyeOpenL'));
    expect(p.param('EyeOpenL')!.name, '左眼 开闭');
    expect(p.parts.single, ('PartHead', '头'));
    expect(p.linked['ParamAngleX'], ['PARAM_ANGLE_X']);
    expect(CompanionProbe.fromJson('nope'), isNull);
  });

  test('what judgement is still needed', () {
    expect(companionAdaptWanted(probe()), ['motion', 'zones', 'emotions', 'tail']);
    // An authored character.json with everything: nothing to ask.
    expect(
      companionAdaptWanted(
        probe(
          probeJson(zonesFrom: 'character', emotionsFrom: 'character', missing: const [], tail: const ['TailSwing']),
        ),
      ),
      isEmpty,
    );
    // Only a smile missing doesn't make her stiff.
    expect(
      companionAdaptWanted(
        probe(probeJson(zonesFrom: 'hitAreas', emotionsFrom: 'character', missing: const ['ParamEyeSmile'])),
      ),
      ['tail'],
    );
    expect(companionAdaptWanted(probe(probeJson(adapter: true))), isEmpty);
  });

  test('the request: what was linked, what is missing, every parameter by group, the note', () {
    final text = companionAdaptRequest(probe(), note: '摸头没反应', current: {'zones': []});
    expect(text, contains('ParamAngleX→PARAM_ANGLE_X'));
    expect(text, contains('模型里找不到的标准参数：ParamEyeLOpen，ParamEyeROpen'));
    expect(text, contains('[眼睛]\nEyeOpenL 左眼 开闭 0..1 =1\nEyeOpenR 右眼 开闭 0..1 =1'));
    expect(text, contains('表情：开心，脸红，水印消除'));
    expect(text, contains('用户说哪里不对：摸头没反应'));
    expect(text, contains('现在用的适配表：{"zones":[]}'));
    expect(companionAdaptSystem, contains('只输出一个 JSON 对象'));
  });

  test('the JSON out of whatever the model wrapped it in', () {
    expect(companionAdaptJson('好的：\n```json\n{"notes":"x"}\n```'), {'notes': 'x'});
    expect(companionAdaptJson('没有'), isNull);
    expect(companionAdaptJson('{broken'), isNull);
  });

  test('only what the model backs is kept', () {
    final (:adapter, :dropped) = companionAdapterCheck({
      'params': {
        'ParamEyeLOpen': {'id': 'EyeOpenL'},
        'ParamEyeROpen': {'id': 'EyeOpenR', 'scale': -1, 'offset': 1},
        'ParamMouthOpenY': {'id': 'NoSuchParam'},
        'NotHers': {'id': 'EyeOpenL'},
      },
      'emotions': {
        'happy': {
          'expression': '开心',
          'face': {'ParamMouthForm': 3, 'EyeOpenL': 5, 'ParamAngleZ': 15, 'Nope': 1},
        },
        'shy': {'expression': '不存在'},
        'ecstatic': {'expression': '开心'},
      },
      'actions': {
        'wave': {'motion': '挥手'},
        'nod': {'motion': '没有这个'},
        'dance': {'motion': '挥手'},
      },
      'zones': [
        {'id': 'head', 'from': 0, 'to': 0.2},
        {'id': 'face', 'from': 0.3, 'to': 0.2},
        {'id': 'wings', 'from': 0, 'to': 1},
        // Nothing left once clamped, or left of itself: never touchable.
        {'id': 'legs', 'from': 1.2, 'to': 1.6},
        {'id': 'body', 'from': 0.3, 'to': 0.6, 'xFrom': 0.5, 'xTo': -0.5},
      ],
      'framing': {'zoom': 9, 'y': 0.1},
      'tail': ['TailSwing', 'Nope'],
      'pose': {'Watermark': 7, 'Nope': 1},
      'notes': '  尾巴用摆动参数代替了  ',
      'script': 'alert(1)',
    }, probe());
    expect(adapter['params'], {
      'ParamEyeLOpen': {'id': 'EyeOpenL'},
      'ParamEyeROpen': {'id': 'EyeOpenR', 'scale': -1.0, 'offset': 1.0},
    });
    expect(adapter['emotions'], {
      'happy': {
        'expression': '开心',
        // Added to where she already is: as far as the parameter can move.
        'face': {'ParamMouthForm': 2.0, 'EyeOpenL': 1.0, 'ParamAngleZ': 15.0},
      },
    });
    expect(adapter['actions'], {
      'wave': {'motion': '挥手'},
    });
    expect(adapter['zones'], [
      {'id': 'head', 'from': 0.0, 'to': 0.2},
    ]);
    expect(adapter['framing'], {'zoom': 3.0, 'y': 0.1});
    expect(adapter['tail'], ['TailSwing']);
    expect(adapter['pose'], {'Watermark': 1.0});
    expect(adapter['notes'], '尾巴用摆动参数代替了');
    expect(adapter.containsKey('script'), isFalse);
    expect(
      dropped,
      containsAll([
        'params.ParamMouthOpenY',
        'params.NotHers',
        'emotions.happy.face.Nope',
        'emotions.shy.expression',
        'emotions.ecstatic',
        'actions.nod',
        'actions.dance',
        'zones',
        'script',
      ]),
    );
    expect(companionAdapterEmpty(adapter), isFalse);
    expect(companionAdapterEmpty(companionAdapterCheck({'notes': 'x'}, probe()).adapter), isTrue);
    // Only the framing was off: that is still a fix.
    expect(
      companionAdapterEmpty(
        companionAdapterCheck({
          'framing': {'zoom': 0.7},
        }, probe()).adapter,
      ),
      isFalse,
    );
  });

  group('asking her AI', () {
    test('one request, the answer checked', () async {
      final asked = <Map<String, Object?>>[];
      final client = MockClient.streaming((request, body) async {
        asked.add(jsonDecode(await body.bytesToString()) as Map<String, Object?>);
        final answer = jsonEncode({
          'params': {
            'ParamEyeLOpen': {'id': 'EyeOpenL'},
          },
          'zones': [
            {'id': 'head', 'from': 0, 'to': 0.2},
          ],
          'notes': '对上了眼睛',
        });
        return http.StreamedResponse(Stream.value(utf8.encode(sse('好的。$answer'))), 200);
      });
      final adapter = await companionAdaptAsk(client: client, apiKey: 'sk-test', probe: probe(), note: '眼睛不眨');
      expect(asked.single['system'], companionAdaptSystem);
      expect((asked.single['messages']! as List).single.toString(), contains('眼睛不眨'));
      expect(adapter['params'], {
        'ParamEyeLOpen': {'id': 'EyeOpenL'},
      });
      expect(adapter['notes'], '对上了眼睛');
    });

    test('an answer with nothing usable in it', () async {
      final prose = MockClient.streaming(
        (_, _) async => http.StreamedResponse(Stream.value(utf8.encode(sse('我不确定'))), 200),
      );
      await expectLater(
        companionAdaptAsk(client: prose, apiKey: 'k', probe: probe()),
        throwsA(isA<CompanionAdaptError>().having((e) => e.reason, 'reason', 'unreadable')),
      );
      final made = MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.value(
            utf8.encode(
              sse(
                jsonEncode({
                  'params': {
                    'ParamAngleX': {'id': 'Made'},
                  },
                }),
              ),
            ),
          ),
          200,
        ),
      );
      await expectLater(
        companionAdaptAsk(client: made, apiKey: 'k', probe: probe()),
        throwsA(isA<CompanionAdaptError>().having((e) => e.reason, 'reason', 'empty')),
      );
    });

    test('a refused key is the light route\'s error', () async {
      final refused = MockClient((_) async => http.Response('{"error":"bad key"}', 401));
      await expectLater(
        companionAdaptAsk(client: refused, apiKey: 'k', probe: probe()),
        throwsA(isA<CompanionLightError>().having((e) => e.failure, 'failure', CompanionLightFailure.badKey)),
      );
    });
  });

  group('kept beside the character', () {
    late Directory pack;

    setUp(() {
      pack = Directory.systemTemp.createTempSync('companion-adapt');
      File('${pack.path}/character/model/m.moc3')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
    });
    tearDown(() => pack.deleteSync(recursive: true));

    test('written with the moc3 fingerprint, read back, removed', () async {
      await companionAdapterWrite(pack, probe(), {
        'adapter': 1,
        'tail': ['TailSwing'],
      });
      final back = await companionAdapterRead(pack);
      expect(back!['tail'], ['TailSwing']);
      expect(back['moc'], sha256.convert([1, 2, 3]).toString());
      expect(File('${pack.path}/character/adapter.json.part').existsSync(), isFalse);
      await companionAdapterRemove(pack);
      expect(await companionAdapterRead(pack), isNull);
    });

    test('no fingerprint for a path that climbs out', () async {
      expect(await companionMocFingerprint(pack, probe({...probeJson(), 'moc': '../x.moc3'})), isNull);
    });
  });

  test('fitting on its own: on unless turned off, once per model', () async {
    expect(await companionAdaptAuto(), isTrue);
    await companionAdaptSetAuto(false);
    expect(await companionAdaptAuto(), isFalse);
    expect(await companionAdaptTried('abc'), isFalse);
    await companionAdaptMarkTried('abc');
    expect(await companionAdaptTried('abc'), isTrue);
  });
}
