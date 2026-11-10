import 'dart:convert';

import 'package:dsh_app/diagnostics/app_error_log.dart';
import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/diagnostics/diagnostics_markdown.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';

void main() {
  DiagnosticsSnapshot snapshot({
    List<String> engineLog = const [],
    List<String> failureLog = const [],
    List<AppErrorRecord> errors = const [],
    Map<String, Object?> connection = const {},
    Map<String, Object?> performance = const {},
    Map<String, Object?>? device,
  }) => DiagnosticsSnapshot(
    at: DateTime(2026, 10, 31, 18, 2, 3),
    status: RuntimeStatus(
      phase: RuntimePhase.running,
      abi: 'arm64-v8a',
      bundledVersion: 'r11-dsh0.2.1-rc.4-node24.22.1-ubuntu24.04.5',
      installedVersion: 'r11-dsh0.2.1-rc.4-node24.22.1-ubuntu24.04.5',
      dshVersion: '0.2.1-rc.4',
      nodeVersion: '24.22.1',
      baseUrl: 'http://127.0.0.1:4512',
      token: 'launch-token-secret-value',
      currentExecutionMode: 'proot',
      launchSelectedMode: 'proot',
    ),
    settings: const AppSettings(apiKey: 'sk-verysecretvalue123', themeMode: ThemeMode.dark, phoneStorage: true),
    native: NativeDiagnostics(
      app: {'versionName': '1.0.6', 'versionCode': 10311700, 'abi': 'arm64-v8a'},
      device:
          device ??
          {
            'manufacturer': 'vivo',
            'brand': 'vivo',
            'model': 'V2405A',
            'android': '16',
            'sdkInt': 36,
            'memoryMb': 12288,
            'freeStorageMb': 4096,
          },
      manifest: {'runtimeVersion': 'r11', 'dshVersion': '0.2.1-rc.4', 'nodeVersion': '24.22.1'},
    ),
    connection: connection,
    performance: performance,
    engineLog: engineLog,
    failureLog: failureLog,
    appErrors: errors,
  );

  test('the report has the sections a support skill needs', () {
    final text = diagnosticsMarkdown(snapshot());
    expect(text, contains('# DSH Go 本机诊断'));
    expect(text, contains('## 环境'));
    expect(text, contains('vivo'));
    expect(text, contains('V2405A'));
    expect(text, contains('Android 16 (SDK 36)'));
    expect(text, contains('设备资源：内存 12288 MB · 剩余存储 4096 MB'));
    expect(text, contains('0.2.1-rc.4'));
    expect(text, contains('## 设置'));
    expect(text, contains('API Key：已设置'));
    expect(text, contains('## 连接'));
    expect(text, contains('## 性能'));
  });

  test('resource sizes preserve native MB, including small and missing values', () {
    final cases = <(Map<String, Object?>, String)>[
      ({'memoryMb': 11323, 'freeStorageMb': 64512}, '- 设备资源：内存 11323 MB · 剩余存储 64512 MB'),
      ({'memoryMb': 0, 'freeStorageMb': 1}, '- 设备资源：内存 0 MB · 剩余存储 1 MB'),
      ({'memoryMb': 2048}, '- 设备资源：内存 2048 MB'),
      ({}, '- 设备资源：'),
    ];
    for (final (device, expected) in cases) {
      final report = diagnosticsMarkdown(snapshot(device: device));
      expect(report.split('\n').singleWhere((line) => line.startsWith('- 设备资源：')), expected);
    }
  });

  test('secrets never survive, even inside log lines and errors', () {
    final text = diagnosticsMarkdown(
      snapshot(
        engineLog: ['start token=launch-token-secret-value', 'Authorization: Bearer abcdef0123456789'],
        errors: [
          AppErrorRecord(
            at: DateTime(2026, 10, 31, 17, 0),
            source: AppErrorSource.flutter,
            message: 'request failed with apiKey=sk-verysecretvalue123',
            stack: '',
          ),
        ],
      ),
    );
    expect(text, isNot(contains('launch-token-secret-value')));
    expect(text, isNot(contains('abcdef0123456789')));
    expect(text, isNot(contains('sk-verysecretvalue123')));
    expect(text, contains('•••'));
  });

  test('log tails are capped and the whole file is bounded', () {
    final many = [for (var i = 0; i < 3000; i++) 'line $i: ${'x' * 40}'];
    final text = diagnosticsMarkdown(snapshot(engineLog: many), maxBytes: 4096);
    expect(text.length, lessThanOrEqualTo(4096 + 80));
    expect(text, contains('已截断'));
    final capped = diagnosticsMarkdown(snapshot(engineLog: many));
    expect(capped, contains('取最后 80 行'));
    expect(capped, isNot(contains('line 0:')));
    expect(capped, contains('line 2999:'));
  });

  test('display facts are printed, for "the pet looks the wrong size" reports', () {
    final text = diagnosticsMarkdown(
      snapshot(
        device: {
          'model': 'M154FF',
          'display': {'widthPx': 1208, 'heightPx': 2624, 'density': 2.625, 'densityDpi': 420, 'fontScale': 1.0},
        },
      ),
    );
    expect(text, contains('显示：1208×2624 · 420dpi · 2.625× · 字号 1.0'));
  });

  test('connection and performance maps are printed as facts', () {
    final text = diagnosticsMarkdown(
      snapshot(
        connection: {'state': 'connected', 'route': 'relay'},
        performance: {
          'device': {'tier': 'high'},
          'thermal': {'lightweight': false},
        },
      ),
    );
    expect(text, contains('state：connected'));
    expect(text, contains('route：relay'));
    expect(text, contains('tier=high'));
  });

  String probeReport(Object? probe, {List<String> engineLog = const []}) => diagnosticsMarkdown(
    snapshot(device: NativeDiagnostics.fromMap({'device': {'backgroundInputProbe': probe}}).device, engineLog: engineLog),
  );

  test('background probe absence and unknown schema are not pass or fail', () {
    for (final raw in [null, 'PRIVATE_RAW', {}, {'v': 2, 'observed': true, 'result': 'success'},
      {'v': 1.0, 'observed': true}, {'v': 1, 'observed': 'true'}]) {
      final text = probeReport(raw);
      expect(text, contains('后台输入探针事实（不是实时自检）：不可用或版本未知'));
      expect(text, isNot(contains('PRIVATE_')));
      expect(text, isNot(contains('自检）：通过')));
      expect(text, isNot(contains('自检）：失败')));
    }
  });

  test('an unobserved probe cannot be promoted by stale result or detail fields', () {
    final text = probeReport({
      'v': 1, 'observed': false, 'result': 'success', 'connectionFailure': false,
      'stage': 'input_send', 'exceptionType': 'SecurityException', 'elapsedMs': 100,
    });
    expect(text, contains('未运行或无保留观察'));
    expect(text, contains('保留连接失败事实：false（不表示当前连接状态）'));
    expect(text, isNot(contains('自检）：通过')));
    expect(text, isNot(contains('失败细节')));
  });

  test('last accepted success and a later connection failure remain separate facts', () {
    final text = probeReport({
      'v': 1, 'observed': true, 'result': 'success', 'connectionFailure': true,
      'stage': 'input_send', 'exceptionType': 'SecurityException', 'elapsedMs': 100,
    });
    expect(text, contains('最近接受的后台输入探针事实（不是实时自检）：通过'));
    expect(text, contains('保留连接失败事实：true（不表示当前连接状态）'));
    expect(text, isNot(contains('失败细节')));
  });

  test('known native failure categories survive the actual Markdown entry', () {
    const stages = ['precondition', 'ui_dispatch', 'presentation_create', 'presentation_configure',
      'presentation_show', 'activity_start', 'activity_ready_wait',
      'view_layout_wait', 'frame_commit_wait', 'target_validate', 'input_send', 'receipt_wait', 'cleanup'];
    const types = ['none', 'SecurityException', 'IllegalStateException', 'IllegalArgumentException',
      'InvalidDisplayException', 'BadTokenException', 'TimeoutException', 'InterruptedException', 'OtherException'];
    for (final stage in stages) {
      for (final type in types) {
        final text = probeReport({
          'v': 1, 'observed': true, 'result': 'failure', 'stage': stage, 'exceptionType': type, 'elapsedMs': 60000,
        });
        expect(text, contains('自检）：失败'));
        expect(text, contains('stage=$stage · type=$type · elapsedMs=60000'));
      }
    }
    expect(probeReport({'v': 1, 'observed': true, 'result': 'failure', 'elapsedMs': 0}), contains('elapsedMs=0'));
  });

  test('untrusted details and unknown fields never get stringified into the report', () {
    for (final elapsed in [-1, 60001, 7.0, double.nan, double.infinity, 'PRIVATE_TIME', {'PRIVATE_TIME': 7}]) {
      final text = probeReport({
        'v': 1, 'observed': true, 'result': 'failure', 'connectionFailure': 'PRIVATE_CONNECTION',
        'stage': 'PRIVATE_PAGE', 'exceptionType': 'PRIVATE_ERROR', 'elapsedMs': elapsed,
        'packageName': 'PRIVATE_PACKAGE', 'message': 'PRIVATE_MESSAGE', 'imageBytes': [80, 81],
      });
      expect(text, contains('自检）：失败'));
      expect(text, isNot(contains('PRIVATE_')));
      expect(text, isNot(contains('失败细节')));
      expect(text, isNot(contains('保留连接失败事实')));
    }
    final unknown = probeReport({'v': 1, 'observed': true, 'result': 'PRIVATE_RESULT', 'stage': 'input_send'});
    expect(unknown, contains('自检）：结果未知'));
    expect(unknown, isNot(contains('PRIVATE_')));
    expect(unknown, isNot(contains('stage=')));
  });

  test('the probe addition still obeys the whole report UTF-8 byte budget', () {
    final text = probeReport({
      'v': 1, 'observed': true, 'result': 'failure', 'stage': 'presentation_show',
      'exceptionType': 'IllegalStateException', 'elapsedMs': 17,
    }, engineLog: List.generate(8, (_) => '汉' * 1000));
    expect(text, contains('stage=presentation_show'));
    expect(text, contains('已截断'));
    expect(utf8.encode(text).length, lessThanOrEqualTo(diagnosticsMarkdownBytes));
    expect(utf8.decode(utf8.encode(text)), text);
  });
}
