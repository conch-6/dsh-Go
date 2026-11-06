// The masking every line of a diagnostics bundle goes through before it leaves
// the phone.

import '../ui/chat/secret_mask.dart' show findSecrets;
import '../ui/engine/log_view.dart' show stripAnsi;

/// What a removed value becomes.
const redactionMark = '•••';

/// Longest line kept whole.
const maxLineLength = 2000;

/// The launch-token mask the native side applies to every engine log line
/// (`CrashClassifier.redact`): `token=•••`.
final _launchToken = RegExp(r'token=[A-Za-z0-9._~%-]+');

/// `Authorization: Bearer <credential>` (and `Basic`).
final _bearer = RegExp(r'\b(Bearer|Basic)\s+(?!•)[A-Za-z0-9._~+/=-]+', caseSensitive: false);
final _maskedAuthorization = RegExp(r'^(?:Bearer|Basic)\s+•••$', caseSensitive: false);

/// Assignments whose value is a secret whatever it looks like:
/// `password=…`, `"secret": "…"`, `Cookie: …`, `Authorization: Basic …`.
final _secretAssignment = RegExp(
  r'''\b([A-Za-z0-9_.-]*(?:passw(?:or)?d|passphrase|secret|credential|cookie|authorization)[A-Za-z0-9_.-]*)("?\s*[:=]\s*)(?:(["'])((?:\\.|(?!\3)[^\\\r\n])*)\3|(["']?)(?!•)(?!(?:Bearer|Basic)\b)([^\s"',;&]+))''',
  caseSensitive: false,
);

/// Assignments of key- or token-named values that look like one (8+
/// characters, not a plain number): `DEEPSEEK_API_KEY=…`, `"apiKey": "…"`,
/// `access_token=…`; `tokens: 1234` stays.
final _keyAssignment = RegExp(
  r'''\b([A-Za-z0-9_.-]*(?:api[_-]?key|apikey|access[_-]?key|private[_-]?key|token)[A-Za-z0-9_.-]*)("?\s*[:=]\s*["']?)(?!•)(?![0-9]+(?:[\s"',;&]|$))([^\s"',;&]{8,})''',
  caseSensitive: false,
);

/// Known credential prefixes kept in front of the mark, so a reader still
/// sees which kind of key was there (`sk-•••`).
const _prefixes = [
  'github_pat_',
  'sk_live_',
  'sk_test_',
  'rk_live_',
  'rk_test_',
  'whsec_',
  'glpat-',
  'xoxa-',
  'xoxb-',
  'xoxp-',
  'xoxr-',
  'xoxs-',
  'ghp_',
  'gho_',
  'ghu_',
  'ghs_',
  'ghr_',
  'npm_',
  'hf_',
  'sk-',
  'AIza',
  'AKIA',
  'ASIA',
  'LTAI',
  'AKID',
];

/// [text] with every credential removed:
///
/// - colour escapes stripped;
/// - API-key-shaped strings (the official secret-mask formats: `sk-…`,
///   `AIza…`, `ghp_…`, JWTs, private-key blocks, passwords in URLs) replaced
///   whole, keeping only a known prefix (`sk-•••`) or a key block's
///   BEGIN / END lines;
/// - the launch token, as the engine log already masks it (`token=•••`);
/// - `Bearer …` / `Basic …` credentials and the values of secret-named
///   assignments.
///
/// Unlike the chat's display mask, nothing of a key's own characters stays.
/// Lines longer than [maxLineLength] are cut first (an inlined image in a
/// log line says nothing to a reader, and it keeps the scan short).
String redactDiagnostics(String text) {
  var out = stripAnsi(text);
  if (out.length > maxLineLength) {
    out = out
        .split('\n')
        .map((line) {
          if (line.length <= maxLineLength) return line;
          var end = maxLineLength;
          final before = line.codeUnitAt(end - 1);
          final after = line.codeUnitAt(end);
          // Keep a supplementary character whole at the truncation boundary.
          if (before >= 0xd800 && before <= 0xdbff && after >= 0xdc00 && after <= 0xdfff) {
            end--;
          }
          return '${line.substring(0, end)}…';
        })
        .join('\n');
  }
  final secrets = findSecrets(out);
  if (secrets.isNotEmpty) {
    final buffer = StringBuffer();
    var at = 0;
    for (final secret in secrets) {
      buffer
        ..write(out.substring(at, secret.start))
        ..write(_maskSpan(out.substring(secret.start, secret.end)));
      at = secret.end;
    }
    buffer.write(out.substring(at));
    out = buffer.toString();
  }
  out = out.replaceAll(_launchToken, 'token=$redactionMark');
  out = out.replaceAllMapped(_bearer, (m) => '${m[1]} $redactionMark');
  out = out.replaceAllMapped(_secretAssignment, (m) {
    final quote = m[3];
    if (quote == null) return '${m[1]}${m[2]}${m[5]}$redactionMark';
    final value = m[4]!;
    // A closed quoted value can contain spaces, separators and escaped quotes.
    // Keep an empty value and an already masked auth scheme readable.
    final masked = value.isEmpty || _maskedAuthorization.hasMatch(value) ? value : redactionMark;
    return '${m[1]}${m[2]}$quote$masked$quote';
  });
  out = out.replaceAllMapped(_keyAssignment, (m) => '${m[1]}${m[2]}$redactionMark');
  return out;
}

/// Redacts the log together so private-key blocks retain their line context.
List<String> redactLines(Iterable<String> lines) {
  final source = lines.toList();
  if (source.isEmpty) return source;
  return redactDiagnostics(source.join('\n')).split('\n');
}

/// A JSON-shaped value with every string through [redactDiagnostics]; keys
/// and non-string values unchanged (`"hasApiKey": true` stays readable).
Object? redactJson(Object? value) => switch (value) {
  String() => redactDiagnostics(value),
  Map() => {for (final e in value.entries) '${e.key}': redactJson(e.value)},
  Iterable() => [for (final v in value) redactJson(v)],
  _ => value,
};

String _maskSpan(String secret) {
  if (secret.startsWith('-----BEGIN')) {
    final lines = secret.split('\n');
    if (lines.length < 2) return redactionMark;
    final hasEnd = lines.last.startsWith('-----END ') && lines.last.endsWith('PRIVATE KEY-----');
    return '${lines.first}\n$redactionMark${hasEnd ? '\n${lines.last}' : ''}';
  }
  for (final prefix in _prefixes) {
    if (secret.startsWith(prefix)) return '$prefix$redactionMark';
  }
  return redactionMark;
}
