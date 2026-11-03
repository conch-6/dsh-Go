// Idea after PiPilot (https://github.com/CikeSeven/pi_pilot), MIT, Copyright (c) 2026 CikeSeven. See THIRD_PARTY_NOTICES.md.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../diagnostics/diagnostics_publish.dart';
import '../../diagnostics/redact.dart';
import '../../runtime/runtime_state.dart';
import '../../runtime/runtime_bridge.dart';
import '../../state/app_info.dart';
import '../../state/connection_state.dart';
import '../../state/settings_state.dart';
import '../common/list_page_row.dart';
import '../engine/diagnostics_export_card.dart';
import '../engine/engine_screen.dart' show shortRuntimeVersion;
import '../engine/engine_status.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'settings_widgets.dart';
import 'direct_engine_settings.dart';
import '../common/brief_notice.dart';

/// Self-service diagnostics: what the app knows about the runtime and the
/// connection, plus a copyable report with every secret redacted.
class DiagnosticsPage extends ConsumerWidget {
  const DiagnosticsPage({super.key});

  static Map<String, Object?> report({
    required LocalRuntimeState runtime,
    required AppSettings settings,
    required String connection,
    required int logLines,
  }) {
    final s = runtime.status;
    return {
      'app': AppInfo.version,
      'runtime': {
        'phase': s.phase.name,
        'abi': s.abi,
        'bundledVersion': s.bundledVersion,
        'installedVersion': s.installedVersion,
        'dshVersion': s.dshVersion,
        'nodeVersion': s.nodeVersion,
        'baseUrl': s.baseUrl,
        'token': s.token == null ? null : '<redacted>',
        'error': s.error,
        'logLines': logLines,
        ...s.launchDiagnostics,
      },
      'connection': connection,
      'settings': {
        'hasApiKey': settings.hasApiKey,
        'themeMode': settings.themeMode.name,
        'autoStartLocal': settings.autoStartLocal,
        'autoApproveCommands': settings.autoApproveCommands,
      },
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final runtime = ref.watch(localRuntimeProvider);
    final settings = ref.watch(settingsProvider);
    final conn = ref.watch(localConnectionProvider);
    final status = runtime.status;
    final connection = switch (conn) {
      AsyncData(:final value) => value == null ? l10n.commonNotConnected : l10n.pluginsConnectedHost(value.label),
      AsyncError(:final error) => l10n.pluginsConnectionError('$error'),
      _ => l10n.pluginsConnecting,
    };
    Future<void> copyReport() async {
      final json = const JsonEncoder.withIndent('  ').convert(
        redactJson(
          report(
            runtime: runtime,
            settings: settings,
            connection: connection,
            logLines: ref.read(localRuntimeLogsProvider).length,
          ),
        ),
      );
      await Clipboard.setData(ClipboardData(text: json));
      if (context.mounted) {
        showBriefNotice(context, l10n.pluginsDiagnosticsCopied);
      }
    }

    Future<void> publishForAi() async {
      final published = await ref.read(diagnosticsPublisherProvider).publish();
      if (!context.mounted) return;
      showBriefNotice(
        context,
        published == null ? l10n.diagnosticsForAiFailed : l10n.diagnosticsForAiDone,
      );
    }

    return AppPage.list(
      title: l10n.pluginsDiagnostics,
      subtitle: Text(l10n.pluginsDiagnosticsDescription),
      children: [
        SettingsSection(
          title: l10n.pluginsRuntime,
          children: [
            InfoRow(label: l10n.commonStatus, value: EngineStatusView.of(runtime).label),
            InfoRow(label: l10n.pluginsArchitecture, value: status.abi ?? '—', mono: true),
            InfoRow(label: l10n.pluginsBundledVersion, value: shortRuntimeVersion(status.bundledVersion), mono: true),
            InfoRow(
              label: l10n.pluginsInstalledVersion,
              value: shortRuntimeVersion(status.installedVersion),
              mono: true,
            ),
            RuntimeLaunchFacts(status: status),
            InfoRow(label: 'DSH', value: status.dshVersion ?? '—', mono: true),
            InfoRow(label: 'Node.js', value: status.nodeVersion ?? '—', mono: true),
            if (status.error case final error?) InfoRow(label: l10n.pluginsErrorLabel, value: error, mono: true),
          ],
        ),
        SettingsSection(
          title: l10n.pluginsConnection,
          children: [
            InfoRow(label: l10n.pluginsAddress, value: status.baseUrl ?? '—', mono: true),
            InfoRow(label: l10n.pluginsClient, value: connection),
            InfoRow(label: 'API Key', value: settings.hasApiKey ? l10n.pluginsConfigured : l10n.commonNotSet),
          ],
        ),
        DiagnosticsExportCard(
          title: l10n.pluginsExport,
          extra: [
            ListPageRow(
              icon: AppIcons.copy,
              title: l10n.pluginsCopyDiagnostics,
              subtitle: l10n.pluginsDiagnosticsContents,
              onTap: copyReport,
            ),
            ListPageRow(
              icon: AppIcons.bot,
              title: l10n.diagnosticsForAi,
              subtitle: l10n.diagnosticsForAiHint,
              onTap: publishForAi,
            ),
          ],
        ),
        // The note belongs to the export card; the next group starts 24 below
        // it, as groups do.
        const DiagnosticsBundleNote(),
        const SizedBox(height: 24),
        const DirectEngineSettings(),
      ],
    );
  }
}

/// The engine process as the native side observes it (never the saved
/// preference), then the latest launch attempt, kept after it exits.
class RuntimeLaunchFacts extends StatelessWidget {
  const RuntimeLaunchFacts({super.key, required this.status});
  final RuntimeStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    String method(String mode) => switch (mode) {
      'direct' => l10n.phoneLaunchDirect,
      'proot' => l10n.phoneLaunchCompatible,
      _ => mode,
    };
    // One child of the card: keep SheetGroup's 2dp between its rows.
    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        InfoRow(
          label: l10n.phoneActualLaunchMode,
          value: switch (status.currentExecutionMode) {
            final String mode => method(mode),
            null => l10n.phoneLaunchNotObserved,
          },
        ),
        // A live process is that launch: the attempt only adds news once it ended.
        if (status.launchSelectedMode case final selected? when status.currentExecutionMode == null)
          InfoRow(label: l10n.phoneLastLaunchSelection, value: method(selected)),
        if (status.directEngineFallbackReason case final reason?)
          InfoRow(
            label: l10n.phoneDirectRejectedReason,
            value: switch (reason) {
              'incompatibleFiles' => l10n.phoneDirectIncompatibleFiles,
              'notEnoughSpace' => l10n.phoneDirectNotEnoughSpace,
              'migrationFailed' => l10n.phoneDirectMigrationFailed,
              'directFailed' => l10n.phoneDirectLaunchFailed,
              'safeRecovery' => l10n.phoneSafeMode,
              _ => reason,
            },
          ),
        if (status.launchFailureReason case final reason?)
          InfoRow(
            label: l10n.phoneLaunchFailureReason,
            value: reason == 'startFailed'
                ? l10n.phoneLaunchStartFailed
                : reason.startsWith('exit:') && int.tryParse(reason.substring(5)) != null
                ? l10n.phoneLaunchExited(reason.substring(5))
                : reason,
          ),
      ],
    );
  }
}
