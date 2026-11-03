// The diagnostics snapshot as one compact Markdown file. The app writes it
// inside the engine's rootfs (`$DSH_HOME/dsh-app/diagnostics.md`) so the
// agent there can read it by itself when the person reports a problem.

import '../state/app_info.dart';
import 'diagnostics_bundle.dart';
import 'redact.dart';

/// Most lines kept from each log tail (the model reads this file, not a zip).
const diagnosticsEngineLines = 80;
const diagnosticsFailureLines = 60;
const diagnosticsErrorLines = 10;

/// Hard cap: a diagnostics file that costs more context than this is no
/// longer worth reading. The zip export stays available for everything else.
const diagnosticsMarkdownBytes = 16 * 1024;

/// Renders [s]. Pure: tests build a snapshot and compare, secrets go through
/// [redactDiagnostics] on the way out.
String diagnosticsMarkdown(DiagnosticsSnapshot s, {int maxBytes = diagnosticsMarkdownBytes}) {
  final b = StringBuffer()
    ..writeln('# DSH Go 本机诊断')
    ..writeln()
    ..writeln('> App 写在引擎里的环境快照，给排查问题用；已脱敏。生成时间：${_time(s.at)}。')
    ..writeln();
  _environment(b, s);
  _connection(b, s);
  _performance(b, s);
  _errors(b, s);
  _log(b, '引擎日志（尾部）', s.engineLog, diagnosticsEngineLines);
  _log(b, '失败前后的日志（尾部）', s.failureLog, diagnosticsFailureLines);
  final text = redactDiagnostics(b.toString());
  if (text.length <= maxBytes) return text;
  return '${text.substring(0, maxBytes)}\n…（诊断文件过长，已截断；完整内容用 设置 → 诊断 的导出包）\n';
}

void _environment(StringBuffer b, DiagnosticsSnapshot s) {
  final st = s.status;
  final app = s.native.app;
  final device = s.native.device;
  final manifest = s.native.manifest;
  b
    ..writeln('## 环境')
    ..writeln('- App：${_join([AppInfo.version, app['versionName'], app['versionCode']?.toString()])}')
    ..writeln('- 设备：${_join([device['manufacturer'], device['brand'], device['model'], _android(device)], mono: true)}')
    ..writeln('- 设备资源：${_join([_mb(device['memoryMb'], '内存'), _mb(device['freeStorageMb'], '剩余存储')])}')
    ..writeln('- ABI：${st.abi ?? '—'}');
  final display = device['display'];
  if (display is Map) {
    final d = {for (final e in display.entries) '${e.key}': e.value};
    b.writeln(
      '- 显示：${_join([if (d['widthPx'] != null && d['heightPx'] != null) '${d['widthPx']}×${d['heightPx']}', if (d['densityDpi'] != null) '${d['densityDpi']}dpi', if (d['density'] != null) '${d['density']}×', if (d['fontScale'] != null) '字号 ${d['fontScale']}'])}',
    );
  }
  if (manifest.isNotEmpty) {
    b.writeln(
      '- 内置运行时：${_join([manifest['runtimeVersion'], manifest['dshVersion'], manifest['nodeVersion']], mono: true)}',
    );
  }
  b
    ..writeln(
      '- 运行时状态：${st.phase.name} · 模式 ${st.mode.name}'
      '${st.safeState.name != 'off' ? ' · 安全模式 ${st.safeState.name}${st.safeReason == null ? '' : '（${st.safeReason}）'}' : ''}'
      '${st.strikes > 0 ? ' · 连续失败 ${st.strikes}' : ''}',
    )
    ..writeln(
      '- 版本：内置 ${_short(st.bundledVersion)} · 已装 ${_short(st.installedVersion)} · DSH ${st.dshVersion ?? '—'} · Node ${st.nodeVersion ?? '—'}',
    )
    ..writeln(
      '- 启动方式：${st.currentExecutionMode ?? st.launchSelectedMode ?? (st.directEngineEnabled ? 'direct（未观测）' : 'proot')}'
      '${st.launchFailureReason == null ? '' : ' · 最近失败 ${st.launchFailureReason}'}'
      '${st.directEngineFallbackReason == null ? '' : ' · 回退 ${st.directEngineFallbackReason}'}',
    )
    ..writeln('- 引擎地址：${st.baseUrl ?? '—'}（token 不回传）');
  if (st.error case final error? when error.isNotEmpty) b.writeln('- 最近错误：$error');
  if (st.networkBlocked) b.writeln('- 系统限制联网：${_time(st.networkBlockedAt ?? s.at)} 起');
  b
    ..writeln()
    ..writeln('## 设置')
    ..writeln(
      '- API Key：${s.settings.hasApiKey ? '已设置' : '未设置'} · 自定义服务商 ${s.settings.customProviderIds.length}'
      ' · 主题 ${s.settings.themeMode.name} · 对话字号 ${s.settings.chatTextScale}',
    )
    ..writeln(
      '- 自动起本机引擎 ${s.settings.autoStartLocal} · 自动批准命令 ${s.settings.autoApproveCommands}'
      ' · 手机存储 ${s.settings.phoneStorage} · 完成后收起过程 ${s.settings.foldCompletedTurns}'
      ' · 可视化回复 ${s.settings.visualReplies}',
    )
    ..writeln();
}

void _connection(StringBuffer b, DiagnosticsSnapshot s) {
  b.writeln('## 连接');
  final entries = s.connection.entries.where((e) => e.value != null && '${e.value}'.isNotEmpty).toList();
  if (entries.isEmpty) {
    b.writeln('- 没有正在观察的连接');
  } else {
    for (final e in entries) {
      b.writeln('- ${e.key}：${e.value}');
    }
  }
  b.writeln();
}

void _performance(StringBuffer b, DiagnosticsSnapshot s) {
  b.writeln('## 性能');
  final p = s.performance;
  if (p.isEmpty) {
    b.writeln('- 没有采样');
  } else {
    for (final e in p.entries) {
      final value = e.value;
      if (value is Map) {
        b.writeln('- ${e.key}：${value.entries.map((x) => '${x.key}=${x.value}').join(' ')}');
      } else {
        b.writeln('- ${e.key}：$value');
      }
    }
  }
  b.writeln();
}

void _errors(StringBuffer b, DiagnosticsSnapshot s) {
  if (s.appErrors.isEmpty) return;
  b.writeln('## 最近错误（App 内捕获）');
  for (final e in s.appErrors.reversed.take(diagnosticsErrorLines).toList().reversed) {
    b.writeln('- ${_time(e.at)} · ${e.source.name}：${_firstLine(e.message)}');
  }
  b.writeln();
}

void _log(StringBuffer b, String title, List<String> lines, int maxLines) {
  if (lines.isEmpty) return;
  final tail = lines.length <= maxLines ? lines : lines.sublist(lines.length - maxLines);
  b
    ..writeln('## $title（${lines.length} 行，取最后 ${tail.length} 行）')
    ..writeln('```log')
    ..writeln(tail.join('\n'))
    ..writeln('```')
    ..writeln();
}

String _join(List<Object?> parts, {bool mono = false}) {
  final text = parts.where((p) => p != null && '$p'.trim().isNotEmpty).map((p) => '$p'.trim()).join(' · ');
  return mono && text.isNotEmpty ? '`$text`' : text;
}

String _android(Map<String, Object?> device) {
  final version = device['android'];
  final sdk = device['sdkInt'];
  if (version == null && sdk == null) return '';
  return version == null ? 'SDK $sdk' : 'Android $version${sdk == null ? '' : ' (SDK $sdk)'}';
}

String _mb(Object? value, String label) {
  if (value is! num) return '';
  return '$label ${value.round()} MB';
}

String _short(String? version) => version == null ? '—' : (version.length > 22 ? version.substring(0, 22) : version);

String _time(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
}

String _firstLine(String text) {
  final line = text.split('\n').first.trim();
  return line.length <= 240 ? line : '${line.substring(0, 240)}…';
}
