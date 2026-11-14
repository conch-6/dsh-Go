// SillyTavern public/scripts/world-info.js and utils.js, AGPL-3.0,
// commit 7e8663cd9c184a550b37238218bdd32c6efc68e9. cyrb53 by bryc, public domain/MIT.
part of 'world_info.dart';

/// Per-evaluation state. The caller's metadata and books are never mutated.
class _TimedEffects {
  _TimedEffects(this.input, this.entries)
    : _state = jsonDecode(jsonEncode(input.timedWorldInfo)) as Map<String, Object?>,
      _arrayLengths = {} {
    for (final type in const ['sticky', 'cooldown']) {
      final raw = _state[type];
      if (raw is List<Object?>) _arrayLengths[type] = raw.length;
      final values = _object(_state[type]);
      values.removeWhere((key, value) => value is! Map<String, Object?> && value is! List<Object?>);
      _state[type] = values;
    }
    if (!input.dryRun) {
      _check('sticky');
      _check('cooldown');
    }
    for (final item in entries) {
      final delay = item.entry._fields['delay'];
      if (_truthy(delay) && input.messageCount < _jsNumber(delay)) active['delay']!.add(item.hash);
    }
  }

  final WorldInfoInput input;
  final List<_RuntimeEntry> entries;
  final Map<String, Object?> _state;
  final Map<String, int> _arrayLengths;
  // JS keeps a newly computed NaN/Infinity during this entire evaluation.
  // Project non-finite values to JSON null only at the persistence boundary;
  // an existing null read from JSON still means Number(null) == 0.
  Map<String, Object?> get state {
    // JS arrays accept named timer keys during this evaluation, but JSON.stringify
    // saves only their original indexed slots. Deleted indices become null holes.
    final projected = Map<String, Object?>.of(_state);
    for (final item in _arrayLengths.entries) {
      projected[item.key] = List<Object?>.generate(item.value, (index) => _effects(item.key)['$index']);
    }
    return jsonDecode(_jsJson(projected)) as Map<String, Object?>;
  }

  final active = <String, Set<int>>{'sticky': {}, 'cooldown': {}, 'delay': {}};
  _TimedEffects._fork(this.input, this.entries, this._state, this._arrayLengths);
  _TimedEffects fork() => _TimedEffects._fork(
    input,
    entries,
    _copyTimedValue(_state)! as Map<String, Object?>,
    Map<String, int>.of(_arrayLengths),
  );

  bool isActive(String type, _RuntimeEntry entry) => active[type]!.contains(entry.hash);
  Map<String, Object?> _effects(String type) => _state[type]! as Map<String, Object?>;
  String _key(_RuntimeEntry item) => item.entry.stKey;

  Map<String, Object?> _effect(String type, _RuntimeEntry item, {bool protected = false}) {
    final end = input.messageCount + _jsNumber(item.entry._fields[type]);
    return {'hash': item.hash, 'start': input.messageCount, 'end': end, 'protected': protected};
  }

  void _check(String type) {
    final values = _effects(type);
    for (final key in _objectKeys(values.keys)) {
      final value = _object(values[key]);
      _RuntimeEntry? found;
      for (final item in entries) {
        if (_jsString(value['hash']) == '${item.hash}') {
          found = item;
          break;
        }
      }
      final start = value.containsKey('start') ? _jsNumber(value['start']) : double.nan;
      final end = value.containsKey('end') ? _jsNumber(value['end']) : double.nan;
      if (input.messageCount <= start && !_truthy(value['protected'])) {
        values.remove(key);
        continue;
      }
      if (found == null) {
        if (input.messageCount >= end) values.remove(key);
        continue;
      }
      if (!_truthy(found.entry._fields[type])) {
        values.remove(key);
        continue;
      }
      if (input.messageCount >= end) {
        values.remove(key);
        if (type == 'sticky' && _truthy(found.entry._fields['cooldown'])) {
          _effects('cooldown')[_key(found)] = _effect('cooldown', found, protected: true);
          active['cooldown']!.add(found.hash);
        }
        continue;
      }
      active[type]!.add(found.hash);
    }
  }

  void finish(Iterable<WorldInfoHit> hits) {
    if (input.dryRun) return;
    for (final hit in hits) {
      final item = entries.firstWhere((item) => item.entry.identity == hit.entry.identity);
      for (final type in const ['sticky', 'cooldown']) {
        if (_truthy(item.entry._fields[type]) && !_truthy(_effects(type)[_key(item)])) {
          _effects(type)[_key(item)] = _effect(type, item);
        }
      }
    }
  }
}

Object? _copyTimedValue(Object? value) {
  if (value is Map<String, Object?>) return {for (final item in value.entries) item.key: _copyTimedValue(item.value)};
  if (value is List<Object?>) return value.map(_copyTimedValue).toList();
  return value; // Includes internal non-finite numbers until the final JSON projection.
}

Map<String, Object?> _object(Object? value) {
  if (value is Map<String, Object?>) return Map<String, Object?>.of(value);
  if (value is List<Object?>) return {for (var i = 0; i < value.length; i++) '$i': value[i]};
  return {};
}

bool _truthy(Object? value) =>
    value != null && value != false && value != '' && value != 0 && !(value is double && value.isNaN);

num _jsNumber(Object? value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  if (value is bool) return value ? 1 : 0;
  if (value is Map<String, Object?>) return double.nan;
  // Dart VM trim also removes NEL (U+0085); ECMAScript Number does not.
  final text = _jsString(value).replaceAll(
    RegExp(
      r'^[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+'
      r'|[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$',
    ),
    '',
  );
  if (text.isEmpty) return 0;
  final radix = RegExp(r'^0([xXbBoO])([0-9a-fA-F]+)$').firstMatch(text);
  if (radix != null) {
    final base = switch (radix[1]!.toLowerCase()) {
      'x' => 16,
      'b' => 2,
      _ => 8,
    };
    return BigInt.tryParse(radix[2]!, radix: base)?.toDouble() ?? double.nan;
  }
  if (text == 'Infinity' || text == '+Infinity') return double.infinity;
  if (text == '-Infinity') return double.negativeInfinity;
  if (!RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$').hasMatch(text)) return double.nan;
  return double.tryParse(text) ?? double.nan;
}

String _jsString(Object? value) {
  if (value == null) return 'null';
  if (value is num) return _jsNumberString(value);
  if (value is Map<String, Object?>) return '[object Object]';
  if (value is List<Object?>) return value.map((item) => item == null ? '' : _jsString(item)).join(',');
  return '$value';
}

/// ST hashes the original loader object after its two-decorator parser. Full V3
/// interpretation below must not silently change the identity of imported ST timers.
int _entryHash(WorldInfoEntry entry) {
  final fields = entry._fields;
  final mapped = <String, Object?>{
    if (fields.containsKey('uid')) 'uid': fields['uid'],
    'world': entry.book.stWorldName,
    for (final key in _objectKeys(fields.keys))
      if (key != 'uid') key: fields[key],
  };
  final parsed = _stDecorators(_string(fields['content']));
  mapped['decorators'] = parsed.$1;
  mapped['content'] = parsed.$2;
  return _cyrb53(_jsJson(mapped));
}

(List<String>, String) _stDecorators(String content) {
  if (!content.startsWith('@@')) return ([], content);
  final lines = content.split('\n');
  final values = <String>[];
  var fallback = false;
  var rest = content;
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (!line.startsWith('@@')) {
      rest = lines.skip(i).join('\n');
      break;
    }
    if (line.startsWith('@@@')) {
      if (!fallback) continue;
      line = line.substring(1);
    }
    if (line.startsWith('@@activate') || line.startsWith('@@dont_activate')) {
      values.add(line);
      fallback = false;
    } else {
      fallback = true;
    }
  }
  return (values, rest);
}

int _cyrb53(String text) {
  var h1 = 0xdeadbeef;
  var h2 = 0x41c6ce57;
  for (final unit in text.codeUnits) {
    h1 = ((h1 ^ unit) * 2654435761) & 0xffffffff;
    h2 = ((h2 ^ unit) * 1597334677) & 0xffffffff;
  }
  h1 = (((h1 ^ (h1 >>> 16)) * 2246822507) ^ ((h2 ^ (h2 >>> 13)) * 3266489909)) & 0xffffffff;
  h2 = (((h2 ^ (h2 >>> 16)) * 2246822507) ^ ((h1 ^ (h1 >>> 13)) * 3266489909)) & 0xffffffff;
  return 4294967296 * (2097151 & h2) + h1;
}

String _jsJson(Object? value) {
  if (value == null) return 'null';
  if (value is bool) return '$value';
  if (value is num) return value.isFinite ? _jsNumberString(value) : 'null';
  if (value is String) return _jsQuote(value);
  if (value is List<Object?>) return '[${value.map(_jsJson).join(',')}]';
  if (value is Map<String, Object?>) {
    return '{${_objectKeys(value.keys).map((key) => '${_jsQuote(key)}:${_jsJson(value[key])}').join(',')}}';
  }
  throw const FormatException('World info state must contain only JSON values.');
}

String _jsQuote(String value) {
  final result = StringBuffer('"');
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    switch (unit) {
      case 0x22:
        result.write(r'\"');
      case 0x5c:
        result.write(r'\\');
      case 8:
        result.write(r'\b');
      case 9:
        result.write(r'\t');
      case 10:
        result.write(r'\n');
      case 12:
        result.write(r'\f');
      case 13:
        result.write(r'\r');
      default:
        if (unit < 32 ||
            (unit >= 0xd800 &&
                unit <= 0xdfff &&
                !(unit <= 0xdbff &&
                    i + 1 < value.length &&
                    value.codeUnitAt(i + 1) >= 0xdc00 &&
                    value.codeUnitAt(i + 1) <= 0xdfff))) {
          result.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
        } else {
          result.writeCharCode(unit);
          if (unit >= 0xd800 && unit <= 0xdbff) result.writeCharCode(value.codeUnitAt(++i));
        }
    }
  }
  result.write('"');
  return '$result';
}

String _jsNumberString(num value) {
  final number = value.toDouble();
  if (number == 0) return '0';
  if (!number.isFinite) return '$number';
  final negative = number < 0;
  final text = number.abs().toString().toLowerCase();
  final parts = text.split('e');
  final coefficient = parts.first;
  final point = coefficient.indexOf('.');
  var digits = coefficient.replaceAll('.', '').replaceFirst(RegExp(r'0+$'), '');
  var decimal = (point < 0 ? coefficient.length : point) + (parts.length == 2 ? int.parse(parts[1]) : 0);
  while (digits.startsWith('0')) {
    digits = digits.substring(1);
    decimal--;
  }
  String result;
  if (decimal > 0 && decimal <= 21) {
    result = decimal >= digits.length
        ? digits.padRight(decimal, '0')
        : '${digits.substring(0, decimal)}.${digits.substring(decimal)}';
  } else if (decimal <= 0 && decimal > -6) {
    result = '0.${''.padRight(-decimal, '0')}$digits';
  } else {
    final exponent = decimal - 1;
    result = '${digits[0]}${digits.length > 1 ? '.${digits.substring(1)}' : ''}e${exponent >= 0 ? '+' : ''}$exponent';
  }
  return negative ? '-$result' : result;
}
