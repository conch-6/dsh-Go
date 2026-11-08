// Fitting a model to her with the person's own AI (docs/design/companion-adapt.md).
//
// The stage reports what the model is (its probe: parameters with the names
// the editor gave them, expressions, motions, what the rules already linked).
// When something only judgement can settle is left — which parameter turns
// the head, which expression is shy, where the head is — the person's model
// is asked once and answers with an adapter: data only, never code. Every
// part of the answer is checked against the probe before it's written to
// `character/adapter.json`, which the stage wears at once (stage.js
// `adapter`). Nothing of the model itself is sent: names and numbers only.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'companion_light.dart';

/// Her standard parameters (stage.js `STANDARD`) and what each one means,
/// in the words the model reads.
const companionAdaptParams = {
  'ParamAngleX': '头左右转，-30（向她右边）到 30',
  'ParamAngleY': '头上下点，-30（低头）到 30（抬头）',
  'ParamAngleZ': '头左右歪，-30 到 30',
  'ParamBodyAngleX': '身体左右转，-10 到 10',
  'ParamBodyAngleY': '身体前后倾，-10 到 10',
  'ParamBodyAngleZ': '身体左右歪，-10 到 10',
  'ParamBreath': '呼吸，0 到 1',
  'ParamEyeLOpen': '左眼睁开，0（闭）到 1（睁）',
  'ParamEyeROpen': '右眼睁开，0（闭）到 1（睁）',
  'ParamEyeBallX': '眼珠左右，-1 到 1',
  'ParamEyeBallY': '眼珠上下，-1 到 1',
  'ParamEyeSmile': '眼睛笑弯，0 到 1',
  'ParamMouthOpenY': '嘴张开，0（闭）到 1（张大）',
  'ParamMouthForm': '嘴形，-1（嘴角向下）到 1（笑）',
  'ParamBrowLY': '左眉上下，-1 到 1',
  'ParamBrowRY': '右眉上下，-1 到 1',
  'ParamBrowLAngle': '左眉角度，-1 到 1',
  'ParamBrowRAngle': '右眉角度，-1 到 1',
};

/// The range of each standard parameter (stage.js `STANDARD`).
const companionAdaptRanges = {
  'ParamAngleX': (-30.0, 30.0),
  'ParamAngleY': (-30.0, 30.0),
  'ParamAngleZ': (-30.0, 30.0),
  'ParamBodyAngleX': (-10.0, 10.0),
  'ParamBodyAngleY': (-10.0, 10.0),
  'ParamBodyAngleZ': (-10.0, 10.0),
  'ParamBreath': (0.0, 1.0),
  'ParamEyeLOpen': (0.0, 1.0),
  'ParamEyeROpen': (0.0, 1.0),
  'ParamEyeBallX': (-1.0, 1.0),
  'ParamEyeBallY': (-1.0, 1.0),
  'ParamEyeSmile': (0.0, 1.0),
  'ParamMouthOpenY': (0.0, 1.0),
  'ParamMouthForm': (-1.0, 1.0),
  'ParamBrowLY': (-1.0, 1.0),
  'ParamBrowRY': (-1.0, 1.0),
  'ParamBrowLAngle': (-1.0, 1.0),
  'ParamBrowRAngle': (-1.0, 1.0),
};

/// Her feelings (stage.js `DEFAULT_EMOTIONS`, companion_reply.dart).
const companionAdaptEmotions = [
  'calm',
  'happy',
  'shy',
  'sad',
  'angry',
  'surprised',
  'confused',
  'smug',
  'sleepy',
  'worried',
];

/// Her gestures (stage.js `ACTIONS`, plus wave, hop and tail).
const companionAdaptActions = [
  'nod',
  'nodSmall',
  'shake',
  'tilt',
  'tiltLeft',
  'lookUp',
  'recoil',
  'duck',
  'sway',
  'stretch',
  'yawn',
  'wave',
];

/// Where a touch can land (stage.js zones; the page answers each).
const companionAdaptZones = ['head', 'face', 'body', 'tail', 'legs'];

/// The ones without which she barely moves.
const _coreParams = ['ParamAngleX', 'ParamAngleY', 'ParamEyeLOpen', 'ParamMouthOpenY'];

@immutable
class CompanionProbeParam {
  const CompanionProbeParam({
    required this.id,
    required this.min,
    required this.max,
    required this.def,
    this.name,
    this.group,
  });

  final String id;
  final String? name;
  final String? group;
  final double min;
  final double max;
  final double def;
}

/// What the stage found in the model (stage.js `probeReport`).
@immutable
class CompanionProbe {
  const CompanionProbe({
    this.moc = '',
    this.mocVersion = 0,
    this.parameterCount = 0,
    this.params = const [],
    this.parts = const [],
    this.expressions = const [],
    this.motions = const [],
    this.linked = const {},
    this.missing = const [],
    this.zonesFrom = 'default',
    this.emotionsFrom = 'default',
    this.tail = const [],
    this.adapted = false,
    this.name,
  });

  /// The moc3's path under `character/`.
  final String moc;
  final int mocVersion;
  final int parameterCount;
  final List<CompanionProbeParam> params;
  final List<(String, String?)> parts;
  final List<String> expressions;
  final List<String> motions;

  /// Her parameter → the model's, as the rules (or an adapter) linked them.
  final Map<String, List<String>> linked;

  /// Her parameters the model has nothing for.
  final List<String> missing;

  /// Where the touch zones came from: adapter, character, hitAreas or default.
  final String zonesFrom;
  final String emotionsFrom;
  final List<String> tail;
  final bool adapted;
  final String? name;

  static CompanionProbe? fromJson(Object? json) {
    if (json is! Map) return null;
    String? text(Object? v) => v is String && v.isNotEmpty ? v : null;
    double number(Object? v) => v is num ? v.toDouble() : 0;
    List<String> strings(Object? v) => [
      if (v is List)
        for (final s in v)
          if (s is String && s.isNotEmpty) s,
    ];
    final linked = json['linked'];
    return CompanionProbe(
      moc: text(json['moc']) ?? '',
      mocVersion: number(json['mocVersion']).round(),
      parameterCount: number(json['parameterCount']).round(),
      params: [
        if (json['params'] is List)
          for (final p in json['params'] as List)
            if (p is Map && text(p['id']) != null)
              CompanionProbeParam(
                id: p['id'] as String,
                name: text(p['name']),
                group: text(p['group']),
                min: number(p['min']),
                max: number(p['max']),
                def: number(p['def']),
              ),
      ],
      parts: [
        if (json['parts'] is List)
          for (final p in json['parts'] as List)
            if (p is Map && text(p['id']) != null) (p['id'] as String, text(p['name'])),
      ],
      expressions: strings(json['expressions']),
      motions: strings(json['motions']),
      linked: {
        if (linked is Map)
          for (final MapEntry(:key, :value) in linked.entries)
            if (key is String) key: strings(value),
      },
      missing: strings(json['missing']),
      zonesFrom: text(json['zonesFrom']) ?? 'default',
      emotionsFrom: text(json['emotionsFrom']) ?? 'default',
      tail: strings(json['tail']),
      adapted: json['adapter'] == true,
      name: text(json['name']),
    );
  }

  CompanionProbeParam? param(String id) {
    for (final p in params) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// What judgement is still needed for this model; empty when nothing is
/// (an authored character.json, or an adapter already worn).
List<String> companionAdaptWanted(CompanionProbe probe) {
  if (probe.adapted) return const [];
  return [
    if (_coreParams.any(probe.missing.contains)) 'motion',
    if (probe.zonesFrom == 'default') 'zones',
    if (probe.emotionsFrom == 'default' && probe.expressions.length >= 2) 'emotions',
    if (probe.tail.isEmpty && probe.params.any((p) => _tailLike.hasMatch('${p.id} ${p.name ?? ''}'))) 'tail',
  ];
}

const _wantedWords = {'motion': '动作用的参数', 'zones': '触摸区', 'emotions': '情绪对应的表情', 'tail': '尾巴参数'};

final _tailLike = RegExp(r'tail|尾巴|尻尾', caseSensitive: false);

String _num(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

/// The instructions, the same every time (and cacheable).
const companionAdaptSystem = '''
你在帮一个陪伴 App 适配用户导入的 Live2D 模型。App 有一套自己的程序化动作（转头、眨眼、呼吸、口型、情绪、手势、触摸反应），按一组标准参数名驱动。你要看懂这个模型的参数、表情、动作，写一份「适配表」，告诉 App 用模型里的哪个参数代替哪个标准参数、哪个表情对应哪种情绪、触摸区在哪。

只输出一个 JSON 对象，不要解释，不要代码块。所有字段都可以省略；拿不准的就不写，宁缺毋错。字段：

- "params"：{标准参数名: {"id": 模型参数 id 或 id 列表, "scale": 数字, "offset": 数字}}。App 写入的值 v 会换算成 v*scale+offset 再写给模型参数。只给模型里没有同名参数、或者同名参数意思不对的标准参数写；方向反了就用负的 scale；范围不同就用 scale 和 offset 换算。
- "emotions"：{情绪: {"expression": 模型的表情名, "face": {标准参数名或模型参数 id: 数值}}}。face 里的数值是加在当前值上的量（比如 "ParamAngleZ": 10 是头再歪 10）。情绪只能是：calm happy shy sad angry surprised confused smug sleepy worried。表情名必须是下面列出的表情之一。开关类的表情（换装、隐藏部件、水印）不要用作情绪。
- "actions"：{手势名: {"motion": 模型的动作名}}。手势名只能是：nod nodSmall shake tilt tiltLeft lookUp recoil duck sway stretch yawn wave。只在模型有明显对应的动作时写。
- "zones"：触摸区列表，每项 {"id": head|face|body|tail|legs, "from": 0~1, "to": 0~1}，from/to 是从画面顶端往下的比例（0 顶，1 底），可选 "xFrom"/"xTo"（-1 左到 1 右）。按人物从上到下的大致比例估：头发和头顶、脸、身体、腿或尾巴。
- "framing"：{"zoom": 0.3~3, "y": -1~1}，人物在画面里的缩放和上下位置（y 负数往上挪，正数往下挪）。只在默认取景明显不对（人物太大、太小、头被切掉）时写。
- "tail"：尾巴摆动用的模型参数 id 列表（没有尾巴就不写）。
- "pose"：{模型参数 id: 数值}，进来时就固定的值，比如关掉水印、选一套默认衣服。
- "notes"：一句给用户看的话（不超过 60 字），说明做了什么、哪里没法适配。

参数 id 只能用下面「参数」里出现过的，数值要在它的范围内。''';

/// The request for [probe]: its parameters by group, expressions, motions,
/// parts, and what the person said is wrong ([note]) with the current adapter.
String companionAdaptRequest(CompanionProbe probe, {String? note, Map<String, Object?>? current}) {
  final wanted = companionAdaptWanted(probe);
  final b = StringBuffer()
    ..writeln('模型：${probe.name ?? '（未命名）'}，${probe.parameterCount} 个参数，${probe.parts.length} 个部件。')
    ..writeln('App 已经自动对上的标准参数：')
    ..writeln(
      [
        for (final name in companionAdaptParams.keys)
          if (!probe.missing.contains(name)) '$name→${(probe.linked[name] ?? [name]).join('+')}',
      ].join('，'),
    )
    ..writeln('模型里找不到的标准参数：${probe.missing.isEmpty ? '无' : probe.missing.join('，')}')
    ..writeln('最需要你补的：${wanted.isEmpty ? '检查一遍，有更合适的就改' : wanted.map((w) => _wantedWords[w] ?? w).join('、')}')
    ..writeln()
    ..writeln('标准参数的意思：');
  companionAdaptParams.forEach((name, meaning) => b.writeln('- $name：$meaning'));
  b
    ..writeln()
    ..writeln('参数（id 名字 最小..最大 =默认），按组：');
  String? group = '\u0000';
  for (final p in probe.params.take(600)) {
    if (p.group != group) {
      group = p.group;
      b.writeln('[${group ?? '未分组'}]');
    }
    b.writeln('${p.id} ${p.name ?? ''} ${_num(p.min)}..${_num(p.max)} =${_num(p.def)}');
  }
  b
    ..writeln()
    ..writeln('表情：${probe.expressions.isEmpty ? '无' : probe.expressions.join('，')}')
    ..writeln('动作：${probe.motions.isEmpty ? '无' : probe.motions.join('，')}')
    ..writeln('部件（前 150 个）：${probe.parts.take(150).map((p) => p.$2 ?? p.$1).join('，')}');
  if (current != null) {
    b
      ..writeln()
      ..writeln('现在用的适配表：${jsonEncode(current)}');
  }
  if (note != null && note.trim().isNotEmpty) {
    b
      ..writeln()
      ..writeln('用户说哪里不对：${note.trim()}');
  }
  return b.toString();
}

/// The first JSON object in [text] (models wrap answers in prose or fences).
Map<String, Object?>? companionAdaptJson(String text) {
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final decoded = jsonDecode(text.substring(start, end + 1));
    return decoded is Map ? decoded.cast<String, Object?>() : null;
  } on FormatException {
    return null;
  }
}

/// [answer] with everything the probe doesn't back taken out: ids that
/// aren't in the model, names that aren't hers, numbers out of range,
/// fields nobody asked for. Returns the adapter and what was dropped.
({Map<String, Object?> adapter, List<String> dropped}) companionAdapterCheck(
  Map<String, Object?> answer,
  CompanionProbe probe,
) {
  final dropped = <String>[];
  final ids = {for (final p in probe.params) p.id};
  final expressions = probe.expressions.toSet();
  final motions = probe.motions.toSet();
  double? number(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
  double clampTo(String id, double v) {
    final p = probe.param(id);
    if (p == null) return v;
    return v.clamp(math.min(p.min, p.max), math.max(p.min, p.max)).toDouble();
  }

  // A face value is added to where the parameter already is: it can move it
  // at most the parameter's whole width, either way.
  double clampAdd(String id, double v) {
    final (lo, hi) = companionAdaptRanges[id] ?? (probe.param(id)?.min ?? -1.0, probe.param(id)?.max ?? 1.0);
    final width = (hi - lo).abs();
    return v.clamp(-width, width).toDouble();
  }

  Map<String, Object?> map(Object? v) => v is Map ? v.cast<String, Object?>() : const {};

  final params = <String, Object?>{};
  for (final MapEntry(:key, :value) in map(answer['params']).entries) {
    final link = map(value);
    final raw = link['id'];
    final targets = [
      for (final id in raw is List ? raw : [raw])
        if (id is String && ids.contains(id)) id,
    ];
    if (!companionAdaptParams.containsKey(key) || targets.isEmpty) {
      dropped.add('params.$key');
      continue;
    }
    final scale = number(link['scale']);
    final offset = number(link['offset']);
    params[key] = {
      'id': targets.length == 1 ? targets.single : targets,
      if (scale != null && scale != 0 && scale.abs() <= 1000) 'scale': scale,
      if (offset != null && offset.abs() <= 1000) 'offset': offset,
    };
  }

  final emotions = <String, Object?>{};
  for (final MapEntry(:key, :value) in map(answer['emotions']).entries) {
    final def = map(value);
    if (!companionAdaptEmotions.contains(key)) {
      dropped.add('emotions.$key');
      continue;
    }
    final expression = def['expression'];
    final face = <String, Object?>{};
    for (final MapEntry(key: id, :value) in map(def['face']).entries) {
      final v = number(value);
      if (v == null) continue;
      if (companionAdaptParams.containsKey(id) || ids.contains(id)) {
        face[id] = clampAdd(id, v);
      } else {
        dropped.add('emotions.$key.face.$id');
      }
    }
    final known = expression is String && expressions.contains(expression);
    if (expression != null && !known) dropped.add('emotions.$key.expression');
    if (!known && face.isEmpty) continue;
    emotions[key] = {if (known) 'expression': expression, if (face.isNotEmpty) 'face': face};
  }

  final actions = <String, Object?>{};
  for (final MapEntry(:key, :value) in map(answer['actions']).entries) {
    final motion = map(value)['motion'];
    if (companionAdaptActions.contains(key) && motion is String && motions.contains(motion)) {
      actions[key] = {'motion': motion};
    } else {
      dropped.add('actions.$key');
    }
  }

  final zones = <Map<String, Object?>>[];
  final rawZones = answer['zones'];
  for (final zone in rawZones is List ? rawZones : const []) {
    final z = map(zone);
    final from = number(z['from'])?.clamp(0.0, 1.0);
    final to = number(z['to'])?.clamp(0.0, 1.0);
    final xFrom = number(z['xFrom'])?.clamp(-1.5, 1.5);
    final xTo = number(z['xTo'])?.clamp(-1.5, 1.5);
    if (!companionAdaptZones.contains(z['id']) ||
        from == null ||
        to == null ||
        !(to > from) ||
        (xFrom != null && xTo != null && !(xTo > xFrom))) {
      dropped.add('zones');
      continue;
    }
    zones.add({'id': z['id'], 'from': from, 'to': to, 'xFrom': ?xFrom, 'xTo': ?xTo});
  }

  final tail = [
    for (final id in answer['tail'] is List ? answer['tail'] as List : const [])
      if (id is String && ids.contains(id)) id,
  ];
  final pose = <String, Object?>{
    for (final MapEntry(key: id, :value) in map(answer['pose']).entries)
      if (ids.contains(id) && number(value) != null) id: clampTo(id, number(value)!),
  };
  final notes = answer['notes'] is String ? (answer['notes'] as String).trim() : '';
  final rawFraming = map(answer['framing']);
  final zoom = number(rawFraming['zoom']);
  final y = number(rawFraming['y']);
  final framing = <String, Object?>{
    if (zoom != null && zoom > 0) 'zoom': zoom.clamp(0.3, 3.0),
    'y': ?y?.clamp(-1.0, 1.0),
  };
  if (answer.containsKey('framing') && framing.isEmpty) dropped.add('framing');

  for (final key in answer.keys) {
    if (!const {'params', 'emotions', 'actions', 'zones', 'tail', 'pose', 'notes', 'framing'}.contains(key)) {
      dropped.add(key);
    }
  }
  return (
    adapter: {
      'adapter': 1,
      if (params.isNotEmpty) 'params': params,
      if (emotions.isNotEmpty) 'emotions': emotions,
      if (actions.isNotEmpty) 'actions': actions,
      if (zones.isNotEmpty) 'zones': zones,
      if (framing.isNotEmpty) 'framing': framing,
      if (tail.isNotEmpty) 'tail': tail,
      if (pose.isNotEmpty) 'pose': pose,
      if (notes.isNotEmpty) 'notes': notes.length > 120 ? notes.substring(0, 120) : notes,
    },
    dropped: dropped,
  );
}

/// Whether a checked adapter says anything at all.
bool companionAdapterEmpty(Map<String, Object?> adapter) =>
    adapter.keys.every((k) => k == 'adapter' || k == 'notes' || k == 'moc');

class CompanionAdaptError implements Exception {
  const CompanionAdaptError(this.reason);

  /// `unreadable`: the answer had no adapter in it; `empty`: nothing usable.
  final String reason;

  @override
  String toString() => 'CompanionAdaptError($reason)';
}

/// Asks the person's model (the light route) and checks its answer.
/// Throws [CompanionLightError] for the request, [CompanionAdaptError] for
/// an answer that can't be used.
Future<Map<String, Object?>> companionAdaptAsk({
  required http.Client client,
  required String apiKey,
  required CompanionProbe probe,
  String? note,
  Map<String, Object?>? current,
}) async {
  final text = StringBuffer();
  await for (final delta in streamCompanionReply(
    client: client,
    apiKey: apiKey,
    system: companionAdaptSystem,
    lines: [CompanionLine.user(companionAdaptRequest(probe, note: note, current: current))],
    maxTokens: 3000,
  )) {
    text.write(delta);
  }
  final answer = companionAdaptJson(text.toString());
  if (answer == null) throw const CompanionAdaptError('unreadable');
  final (:adapter, dropped: _) = companionAdapterCheck(answer, probe);
  if (companionAdapterEmpty(adapter)) throw const CompanionAdaptError('empty');
  return adapter;
}

/// `character/adapter.json` of the pack at [pack].
File companionAdapterFile(Directory pack) => File('${pack.path}/character/adapter.json');

Future<Map<String, Object?>?> companionAdapterRead(Directory pack) async {
  try {
    final decoded = jsonDecode(await companionAdapterFile(pack).readAsString());
    return decoded is Map ? decoded.cast<String, Object?>() : null;
  } on Object {
    return null;
  }
}

/// Writes [adapter] for the model at [probe] (with its moc3's fingerprint,
/// so it can be matched to the same model later).
Future<void> companionAdapterWrite(Directory pack, CompanionProbe probe, Map<String, Object?> adapter) async {
  final file = companionAdapterFile(pack);
  final fingerprint = await companionMocFingerprint(pack, probe);
  final temp = File('${file.path}.part');
  await temp.writeAsString(jsonEncode({...adapter, 'moc': ?fingerprint}), flush: true);
  await temp.rename(file.path);
}

Future<void> companionAdapterRemove(Directory pack) async {
  final file = companionAdapterFile(pack);
  if (await file.exists()) await file.delete();
}

/// The moc3's sha256, or null when it can't be read.
Future<String?> companionMocFingerprint(Directory pack, CompanionProbe probe) async {
  if (probe.moc.isEmpty || probe.moc.split('/').contains('..')) return null;
  try {
    return (await sha256.bind(File('${pack.path}/character/${probe.moc}').openRead()).first).toString();
  } on Object {
    return null;
  }
}

/// Whether the person has said yes to a fitting once (an offer, or the menu):
/// until then nothing goes out on its own.
const _consentKey = 'companion_adapt_consented';

Future<bool> companionAdaptConsented() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(_consentKey) ?? false;
  } on Object {
    return false;
  }
}

Future<void> companionAdaptSetConsented(bool yes) async =>
    (await SharedPreferences.getInstance()).setBool(_consentKey, yes);

/// Whether models are fitted on their own when they arrive (on unless turned off).
const _autoKey = 'companion_adapt_auto';

Future<bool> companionAdaptAuto() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(_autoKey) ?? true;
  } on Object {
    return true;
  }
}

Future<void> companionAdaptSetAuto(bool on) async => (await SharedPreferences.getInstance()).setBool(_autoKey, on);

/// An automatic try happens once per model, whatever came of it.
String _triedKey(String fingerprint) => 'companion_adapt_tried_$fingerprint';

Future<bool> companionAdaptTried(String fingerprint) async {
  try {
    return (await SharedPreferences.getInstance()).getBool(_triedKey(fingerprint)) ?? false;
  } on Object {
    return false;
  }
}

Future<void> companionAdaptMarkTried(String fingerprint) async {
  try {
    await (await SharedPreferences.getInstance()).setBool(_triedKey(fingerprint), true);
  } on Object {
    // Then it may try again next time.
  }
}
