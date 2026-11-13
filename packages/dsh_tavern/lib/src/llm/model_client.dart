import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api.dart';

/// The transport contract is OpenAI Chat Completions. DeepSeek's beta endpoint,
/// prefix, reasoning_content and usage fields follow its published API:
/// https://api-docs.deepseek.com/api/create-chat-completion/
/// https://api-docs.deepseek.com/guides/chat_prefix_completion/
/// Checked 2026-11-10. Prompt conversion belongs to the prompt assembler.
sealed class ModelDelta {
  const ModelDelta();
}

class ModelText extends ModelDelta {
  const ModelText(this.text);
  final String text;
}

class ModelReasoning extends ModelDelta {
  const ModelReasoning(this.text);
  final String text;
}

/// An unexecuted tool fragment. An absent/invalid streaming index is never
/// guessed. Protocol diagnostics travel beside the other response channels.
/// The accumulator, rather than the transport, owns call identity and JSON.
class ModelToolFragment extends ModelDelta {
  ModelToolFragment({
    this.index,
    this.id,
    this.type,
    this.name,
    this.arguments,
    List<Map<String, Object?>> issues = const [],
  }) : _issues = jsonEncode(issues);

  final int? index;
  final String? id;
  final String? type;
  final String? name;
  final String? arguments;
  final String _issues;

  /// Every read is detached, including nested diagnostic metadata.
  List<Map<String, Object?>> get issues => [
    for (final issue in jsonDecode(_issues) as List<Object?>) issue as Map<String, Object?>,
  ];
}

class ModelUsage extends ModelDelta {
  const ModelUsage(this.usage);
  final TavernUsage usage;
}

class ModelFinished extends ModelDelta {
  const ModelFinished(this.reason);
  final String? reason;
}

class TavernModelException implements Exception {
  const TavernModelException(this.kind, this.detail);
  final TavernFailure kind;
  final String detail;

  @override
  String toString() => 'TavernModelException(${kind.name}): $detail';
}

/// Only failures before an accepted response are eligible. A successful HTTP
/// response may already be billable even when its first token never arrives.
class _RetryableModelException implements Exception {
  const _RetryableModelException(this.cause);
  final TavernModelException cause;
}

/// One cancellation per generation, including time spent obtaining the key.
class ModelCancellation {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const TavernModelException(TavernFailure.cancelled, 'cancelled');
  }

  Future<T> wait<T>(Future<T> operation) {
    check();
    return Future.any([
      operation,
      whenCancelled.then<T>((_) => throw const TavernModelException(TavernFailure.cancelled, 'cancelled')),
    ]);
  }
}

/// An HTTP client is owned by each call so stopping one chat cannot abort a
/// different chat. Supply [clientFactory] for deterministic transport tests.
class TavernModelClient {
  TavernModelClient({http.Client Function()? clientFactory, this.idleTimeout = const Duration(minutes: 5)})
    : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;
  final Duration idleTimeout;

  /// [body] is the final, inspected request from the assembler. This method
  /// only supplies the configured model and transport stream setting.
  /// `stream: false` presets are also supported: one text/reasoning delta.
  /// Connection errors while sending and HTTP 5xx get at most two retries,
  /// after 250 and 500 ms. Accepted responses and 4xx are not retried; waiting
  /// for headers or an accepted body to time out does not trigger a retry.
  /// A known 5xx stays retryable if reading its error body fails or times out.
  /// A lost response during send can still mean the server received the POST;
  /// bounded retry cannot promise that the first attempt was not charged.
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
  }) async* {
    String? key;
    try {
      cancellation.check();
      key = await cancellation.wait(config.apiKey());
      cancellation.check();
      key = key?.trim();
      if (key == null || key.isEmpty) {
        throw const TavernModelException(TavernFailure.noKey, 'no_api_key');
      }
      final payload = <String, Object?>{...body, 'model': config.model};
      payload.putIfAbsent('stream', () => true);
      if (config.deepseek) {
        payload.putIfAbsent('thinking', () => {'type': config.thinking ? 'enabled' : 'disabled'});
      }
      final encodedBody = jsonEncode(payload);
      final uri = endpoint(config);
      for (var attempt = 0; ; attempt++) {
        try {
          await for (final delta in _generateAttempt(
            config,
            uri,
            key,
            encodedBody,
            payload['stream'] != false,
            cancellation,
          )) {
            yield delta;
          }
          return;
        } on _RetryableModelException catch (error) {
          cancellation.check();
          if (attempt >= 2) throw error.cause;
          await cancellation.wait(Future<void>.delayed(Duration(milliseconds: 250 * (1 << attempt))));
        }
      }
    } on TavernModelException {
      rethrow;
    } on http.RequestAbortedException {
      throw const TavernModelException(TavernFailure.cancelled, 'cancelled');
    } on TimeoutException {
      cancellation.check();
      throw const TavernModelException(TavernFailure.network, 'request_timeout');
    } on http.ClientException {
      cancellation.check();
      throw const TavernModelException(TavernFailure.network, 'http_transport_failed');
    } on FormatException {
      cancellation.check();
      throw const TavernModelException(TavernFailure.server, 'invalid_response_format');
    } catch (_) {
      cancellation.check();
      // Do not expose callback/transport exception text: it may contain a key
      // or the entire request. Known HTTP errors carry a bounded safe detail.
      throw const TavernModelException(TavernFailure.network, 'model_call_failed');
    }
  }

  Stream<ModelDelta> _generateAttempt(
    TavernModelConfig config,
    Uri uri,
    String key,
    String encodedBody,
    bool streaming,
    ModelCancellation cancellation,
  ) async* {
    http.Client? client;
    try {
      cancellation.check();
      final request = http.AbortableRequest('POST', uri, abortTrigger: cancellation.whenCancelled)
        ..headers.addAll({'Content-Type': 'application/json', 'Authorization': 'Bearer $key'})
        ..body = encodedBody;
      client = _clientFactory();
      cancellation.check();
      http.StreamedResponse response;
      try {
        response = await cancellation.wait(client.send(request).timeout(idleTimeout));
      } on http.RequestAbortedException {
        rethrow;
      } on http.ClientException {
        cancellation.check();
        throw const _RetryableModelException(TavernModelException(TavernFailure.network, 'http_transport_failed'));
      }
      cancellation.check();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        String error;
        try {
          error = await cancellation.wait(_errorBody(response.stream.timeout(idleTimeout)));
        } catch (_) {
          cancellation.check();
          // The HTTP status remains authoritative even if its error body was
          // interrupted. Do not substitute raw transport exception messages.
          error = 'error_response_body_unavailable';
        }
        final failure = _apiError(response.statusCode, error, key);
        if (response.statusCode >= 500 && response.statusCode < 600) {
          throw _RetryableModelException(failure);
        }
        throw failure;
      }

      if (!streaming) {
        final text = await cancellation.wait(response.stream.bytesToString().timeout(idleTimeout));
        cancellation.check();
        final result = _object(jsonDecode(text));
        if (result['error'] != null) throw _apiError(200, text, key);
        final choice = _firstChoice(result);
        final message = _object(choice['message']);
        if (message['reasoning_content'] case final String reasoning when reasoning.isNotEmpty) {
          cancellation.check();
          yield ModelReasoning(reasoning);
        }
        if (message['content'] case final String content when content.isNotEmpty) {
          cancellation.check();
          yield ModelText(content);
        }
        for (final fragment in _toolFragments(message['tool_calls'], streaming: false)) {
          cancellation.check();
          yield fragment;
        }
        if (result['usage'] case final Map<String, dynamic> usage) {
          cancellation.check();
          yield ModelUsage(_usage(usage, result['model'] as String? ?? config.model));
        }
        if (choice.isEmpty || message.isEmpty) {
          throw const TavernModelException(TavernFailure.server, 'invalid_completion_response');
        }
        final reason = choice['finish_reason'] as String?;
        _checkFinish(reason);
        cancellation.check();
        yield ModelFinished(reason);
        return;
      }

      String? finishReason;
      var sawFinish = false;
      var sawDone = false;
      await for (final event in decodeServerSentEvents(response.stream.timeout(idleTimeout))) {
        cancellation.check();
        if (event == '[DONE]') {
          sawDone = true;
          break;
        }
        final data = _object(jsonDecode(event));
        if (data['error'] != null) throw _apiError(200, event, key);
        final choice = _firstChoice(data);
        final delta = _object(choice['delta']);
        if (delta['reasoning_content'] case final String reasoning when reasoning.isNotEmpty) {
          cancellation.check();
          yield ModelReasoning(reasoning);
        }
        if (delta['content'] case final String content when content.isNotEmpty) {
          cancellation.check();
          yield ModelText(content);
        }
        for (final fragment in _toolFragments(delta['tool_calls'], streaming: true)) {
          cancellation.check();
          yield fragment;
        }
        if (choice['finish_reason'] case final String reason) {
          finishReason = reason;
          sawFinish = true;
        }
        // Some providers send usage with choices: [], others on the finish
        // chunk. It must be read independently of the first choice.
        if (data['usage'] case final Map<String, dynamic> usage) {
          cancellation.check();
          yield ModelUsage(_usage(usage, data['model'] as String? ?? config.model));
        }
      }
      cancellation.check();
      if (!sawDone && !sawFinish) {
        throw const TavernModelException(TavernFailure.network, 'stream_ended_before_finish');
      }
      _checkFinish(finishReason);
      cancellation.check();
      yield ModelFinished(finishReason);
    } finally {
      client?.close();
    }
  }

  /// Generic services supply their own API prefix (for example /v1). A full
  /// /chat/completions URL is accepted. DeepSeek roots and /v1 become /beta.
  static Uri endpoint(TavernModelConfig config) {
    final uri = Uri.parse(config.baseUrl).removeFragment();
    if (!uri.hasAuthority || (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw const TavernModelException(TavernFailure.network, 'invalid_base_url');
    }
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (path.endsWith('/chat/completions')) {
      if (!config.deepseek) return uri.replace(path: path);
      path = path.substring(0, path.length - '/chat/completions'.length);
    }
    if (config.deepseek && !path.endsWith('/beta')) {
      if (path.endsWith('/v1')) path = path.substring(0, path.length - 3);
      path += '/beta';
    }
    return uri.replace(path: '$path/chat/completions');
  }
}

/// SSE framing is independent of HTTP chunk boundaries and UTF-8 characters.
/// Malformed UTF-8 is replaced before fields and comments are interpreted.
/// UTF-8 decoding removes at most one leading BOM for the entire stream.
/// Comments/keepalives are ignored; multiple data fields join with a newline.
/// Only a terminating blank line dispatches an event; EOF discards pending data.
Stream<String> decodeServerSentEvents(Stream<List<int>> bytes) async* {
  final data = <String>[];
  await for (final line in bytes.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        yield data.join('\n');
        data.clear();
      }
      continue;
    }
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    if (field != 'data') continue;
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    data.add(value);
  }
}

Map<String, Object?> _object(Object? value) {
  if (value is Map<String, dynamic>) return value;
  return const {};
}

Map<String, Object?> _firstChoice(Map<String, Object?> response) {
  final choices = response['choices'];
  if (choices is! List<Object?> || choices.isEmpty) return const {};
  for (final value in choices) {
    final choice = _object(value);
    if (choice['index'] == null || choice['index'] == 0) return choice;
  }
  return const {};
}

Iterable<ModelToolFragment> _toolFragments(Object? value, {required bool streaming}) sync* {
  if (value == null) {
    return;
  }
  if (value is! List<Object?>) {
    yield ModelToolFragment(
      issues: [
        {'code': 'invalid_tool_calls', 'field': 'tool_calls', 'message': 'Expected an array of tool calls.'},
      ],
    );
    return;
  }
  for (var ordinal = 0; ordinal < value.length; ordinal++) {
    final item = value[ordinal];
    if (item is! Map<String, Object?>) {
      yield ModelToolFragment(
        index: streaming ? null : ordinal,
        issues: [
          {
            'code': 'invalid_tool_call',
            'field': 'tool_calls',
            'ordinal': ordinal,
            if (!streaming) 'index': ordinal,
            'message': 'Expected a tool call object.',
          },
        ],
      );
      continue;
    }
    final issues = <Map<String, Object?>>[];
    int? index;
    if (!streaming) {
      index = ordinal;
    } else if (item['index'] case final int position when position >= 0) {
      index = position;
    } else {
      issues.add({
        'code': 'invalid_index',
        'field': 'index',
        'ordinal': ordinal,
        'message': 'A streaming tool fragment requires a non-negative integer index.',
      });
    }
    String? field(Map<String, Object?> object, String key, String path) {
      if (!object.containsKey(key)) {
        return null;
      }
      final raw = object[key];
      if (raw is String) {
        return raw;
      }
      issues.add({'code': 'invalid_field_type', 'field': path, 'index': ?index, 'message': 'Expected a string.'});
      return null;
    }

    final id = field(item, 'id', 'id');
    final type = field(item, 'type', 'type');
    String? name;
    String? arguments;
    if (item.containsKey('function')) {
      final function = item['function'];
      if (function is Map<String, Object?>) {
        name = field(function, 'name', 'function.name');
        arguments = field(function, 'arguments', 'function.arguments');
      } else {
        issues.add({
          'code': 'invalid_field_type',
          'field': 'function',
          'index': ?index,
          'message': 'Expected a function object.',
        });
      }
    }
    yield ModelToolFragment(index: index, id: id, type: type, name: name, arguments: arguments, issues: issues);
  }
}

TavernUsage _usage(Map<String, Object?> data, String model) {
  int number(Object? value) => value is num ? value.toInt() : 0;
  return TavernUsage(
    promptTokens: number(data['prompt_tokens']),
    cacheHitTokens: number(data['prompt_cache_hit_tokens'] ?? _object(data['prompt_tokens_details'])['cached_tokens']),
    completionTokens: number(data['completion_tokens']),
    model: model,
  );
}

void _checkFinish(String? reason) {
  if (reason == 'insufficient_system_resource' || reason == 'aborted') {
    throw TavernModelException(TavernFailure.server, 'finish_reason:$reason');
  }
}

Future<String> _errorBody(Stream<List<int>> bytes) async {
  final buffer = StringBuffer();
  await for (final chunk in bytes.transform(const Utf8Decoder(allowMalformed: true))) {
    buffer.write(chunk);
    if (buffer.length >= 4096) break;
  }
  final text = buffer.toString();
  return text.length > 4096 ? text.substring(0, 4096) : text;
}

bool _isContextLengthError(String body) {
  bool matches(String value) {
    final lowered = value.toLowerCase();
    return lowered.contains('context_length_exceeded') ||
        lowered.contains('maximum context length') ||
        lowered.contains('context window') ||
        lowered.contains('context too long');
  }

  // Keep existing raw/plain-text matches and also recognize JSON escapes in
  // the two established error strings. Unrelated values are never re-encoded.
  if (matches(body)) return true;
  try {
    final error = _object(_object(jsonDecode(body))['error']);
    final code = error['code'];
    final message = error['message'];
    return (code is String && matches(code)) || (message is String && matches(message));
  } on FormatException {
    return false;
  }
}

TavernModelException _apiError(int status, String body, String key) {
  final kind = switch (status) {
    401 || 403 => TavernFailure.badKey,
    402 => TavernFailure.insufficientBalance,
    429 => TavernFailure.busy,
    >= 500 && < 600 => TavernFailure.server,
    _ when _isContextLengthError(body) => TavernFailure.contextTooLong,
    400 || 422 => TavernFailure.invalidParameters,
    _ => TavernFailure.server,
  };
  var detail = body.replaceAll(key, '[redacted]');
  detail = detail.replaceAll(RegExp(r'Bearer\s+[^\s"<>]+', caseSensitive: false), 'Bearer [redacted]');
  if (detail.length > 512) detail = detail.substring(0, 512);
  return TavernModelException(kind, 'HTTP $status: $detail');
}
