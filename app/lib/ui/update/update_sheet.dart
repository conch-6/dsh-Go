import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../state/star_prompt.dart' show starPromptGateProvider, starPromptProvider;
import '../../state/update_state.dart';
import '../../update/release.dart' show releaseNotesFor;
import '../../update/update_config.dart';
import '../chat/render/markdown_body.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../settings/settings_widgets.dart' show SettingsSection;
import '../shell/brand_mark.dart';
import '../star/star_prompt_dialog.dart' show openStarProject;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../common/brief_notice.dart';

/// The update offer: version, size, notes, and the download → install flow
/// (progress lives in [appUpdateProvider], so closing the sheet doesn't stop it).
Future<void> showUpdateSheet(BuildContext context) =>
    showAppSheet<void>(context, isScrollControlled: true, builder: (_) => const UpdateSheet());

/// Looks for an update on request (设置 → 关于): opens the sheet when there is
/// one, otherwise says so in a snack bar.
Future<void> checkForUpdates(BuildContext context, WidgetRef ref) async {
  final controller = ref.read(appUpdateProvider.notifier);
  if (ref.read(appUpdateProvider).hasUpdate) return showUpdateSheet(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final phase = await controller.check();
  if (!context.mounted) return;
  switch (phase) {
    case UpdateCheckPhase.available:
      await showUpdateSheet(context);
    case UpdateCheckPhase.upToDate:
      messenger?.showBriefNotice(context.l10n.updateUpToDate);
    case UpdateCheckPhase.unavailable:
      messenger?.showSnackBar(SnackBar(content: Text(context.l10n.updateCheckUnavailable)));
    case UpdateCheckPhase.idle || UpdateCheckPhase.checking:
  }
}

/// "180.1 MB".
String formatUpdateSize(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

/// What went wrong, for the person: (title, explanation).
(String, String) describeUpdateProblem(UpdateProblem problem, {int? size}) => switch (problem) {
  UpdateProblem.network => (appL10n.updateDownloadInterrupted, appL10n.updateDownloadInterruptedMessage),
  UpdateProblem.unavailable => (appL10n.updateDownloadUnavailable, appL10n.updateDownloadUnavailableMessage),
  UpdateProblem.checksum => (appL10n.updateChecksumFailed, appL10n.updateChecksumFailedMessage),
  UpdateProblem.noChecksum => (appL10n.updateChecksumMissing, appL10n.updateChecksumMissingMessage),
  UpdateProblem.storage => (appL10n.updateStorageWriteFailed, appL10n.updateStorageWriteFailedMessage),
  UpdateProblem.noSpace => (
    appL10n.commonStorageFull,
    size == null ? appL10n.updateFreeSpaceRetry : appL10n.updateSpaceRequired(formatUpdateSize(size * 2)),
  ),
  UpdateProblem.permissionUnavailable => (appL10n.updateSettingsOpenFailed, appL10n.updateSettingsOpenFailedMessage),
  UpdateProblem.installCancelled => (appL10n.updateInstallCancelled, appL10n.updateInstallCancelledMessage),
  UpdateProblem.installUnconfirmed => (appL10n.updateInstallUnconfirmed, appL10n.updateInstallUnconfirmedMessage),
  UpdateProblem.signature => (appL10n.updateSignatureMismatch, appL10n.updateSignatureMismatchMessage),
  UpdateProblem.notDsh => (appL10n.updateWrongPackage, appL10n.updateWrongPackageMessage),
  UpdateProblem.downgrade => (appL10n.updateDowngradeBlocked, appL10n.updateDowngradeBlockedMessage),
  UpdateProblem.incompatible => (appL10n.updateIncompatible, appL10n.updateIncompatibleMessage),
  UpdateProblem.invalid => (appL10n.updatePackageCorrupt, appL10n.updatePackageCorruptMessage),
  UpdateProblem.blocked => (appL10n.updateInstallBlocked, appL10n.updateInstallBlockedMessage),
  UpdateProblem.installFailed => (appL10n.updateInstallIncomplete, appL10n.updateInstallIncompleteMessage),
};

/// Problems where retrying in the app can't help: the way out is the browser.
const _browserOnly = {
  UpdateProblem.signature,
  UpdateProblem.noChecksum,
  UpdateProblem.incompatible,
  UpdateProblem.downgrade,
};

/// Install failures the system's own installer may get past (the package is still here).
const _systemInstallerHelps = {UpdateProblem.installFailed, UpdateProblem.blocked};

/// An install that was cancelled, or whose result never came back: the package is ready again.
const _installUnfinished = {UpdateProblem.installCancelled, UpdateProblem.installUnconfirmed};

String _date(DateTime t) {
  final local = t.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
}

class UpdateSheet extends ConsumerWidget {
  const UpdateSheet({super.key});

  static const _buttonSize = Size.fromHeight(48);

  Future<void> _openPage(BuildContext context, Uri? page) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final uri = page ?? githubReleasesPage;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
    if (!ok) messenger?.showSnackBar(SnackBar(content: Text(appL10n.updateBrowserOpenFailed(uri.host, uri.path))));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final update = ref.watch(appUpdateProvider);
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final latest = update.latest;
    if (latest == null) {
      // The offer went away (installed elsewhere, or a check found nothing newer).
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.updateCheck),
            Padding(
              padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 8, SheetTitleBar.inset, 32),
              child: Text(l10n.updateUpToDateVersion(update.current.name), style: theme.textTheme.bodyLarge),
            ),
          ],
        ),
      );
    }
    // The patch's size when one applies: what the download really is.
    final size = update.downloadSize;
    final facts = [
      l10n.updateCurrentVersion(update.current.name),
      ?(size == null ? null : formatUpdateSize(size)),
      ?(latest.publishedAt == null ? null : _date(latest.publishedAt!)),
    ].join(' · ');

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(l10n.updateNewVersionFound),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const BrandMark(size: 52, tile: true),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('DSH ${latest.version.name}', style: theme.textTheme.titleLarge),
                            const SizedBox(height: 2),
                            Text(facts, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_status(context, update) case final status?) ...[status, const SizedBox(height: 16)],
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                    child: Text(l10n.updateReleaseNotes, style: SettingsSection.titleStyle(context)),
                  ),
                  SheetGroup(
                    margin: EdgeInsets.zero,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                        // Full width, so the notes start at 16 however short they are.
                        child: SizedBox(
                          width: double.infinity,
                          // In the app's language only (Chinese when the
                          // release has none in it).
                          child: switch (releaseNotesFor(latest, Localizations.localeOf(context).languageCode)) {
                            '' => Text(l10n.updateNoReleaseNotes, style: theme.textTheme.bodyMedium),
                            final notes => MarkdownBody(text: notes, selectable: false),
                          },
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                    child: Text(
                      l10n.updateInstallKeepsData,
                      style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 16, SheetTitleBar.inset, 8),
            child: _actions(context, ref, update),
          ),
        ],
      ),
    );
  }

  Widget? _status(BuildContext context, AppUpdateState update) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final scheme = theme.colorScheme;
    if (update.asset == null) {
      final abi = update.flavor?.name;
      return _Notice(
        icon: AppIcons.info,
        background: colors.infoContainer,
        foreground: colors.onInfoContainer,
        title: l10n.updateNoCompatiblePackage,
        text: abi == null ? l10n.updateNoPackage : l10n.updateNoAbiPackage(abi),
      );
    }
    switch (update.task) {
      case UpdateTaskPhase.downloading:
        final progress = update.progress;
        final amount = update.total == null
            ? formatUpdateSize(update.received)
            : '${formatUpdateSize(update.received)} / ${formatUpdateSize(update.total!)}';
        return _Progress(
          title: progress == null ? l10n.updateDownloading : l10n.updateDownloadingPercent((progress * 100).floor()),
          trailing: amount,
          value: progress,
          note: [
            if (update.source case final source?) l10n.updateDownloadSource(source),
            l10n.updateDownloadInBackgroundNote,
          ].join(' · '),
        );
      case UpdateTaskPhase.verifying:
        return _Progress(title: l10n.updateVerifyingPackage, note: l10n.updateVerifyingPackageNote);
      case UpdateTaskPhase.installing:
        return _Progress(title: l10n.updateInstalling, note: l10n.updateConfirmInstallNote);
      case UpdateTaskPhase.ready:
        final unfinished = _installUnfinished.contains(update.problem);
        final (title, text) = unfinished
            ? describeUpdateProblem(update.problem!)
            : (l10n.updatePackageDownloaded, l10n.updateReadyToInstall);
        return _Notice(
          icon: unfinished ? AppIcons.info : AppIcons.completed,
          background: unfinished ? scheme.surfaceContainerHighest : colors.successContainer,
          foreground: unfinished ? scheme.onSurfaceVariant : colors.onSuccessContainer,
          title: title,
          text: text,
        );
      case UpdateTaskPhase.needsPermission:
        final unavailable = update.problem == UpdateProblem.permissionUnavailable;
        final (title, text) = unavailable
            ? describeUpdateProblem(UpdateProblem.permissionUnavailable)
            : (l10n.updateAllowInstall, l10n.updateAllowInstallMessage);
        return _Notice(
          icon: AppIcons.permissions,
          background: colors.warningContainer,
          foreground: colors.onWarningContainer,
          title: title,
          text: text,
        );
      case UpdateTaskPhase.failed:
        final (title, text) = describeUpdateProblem(
          update.problem ?? UpdateProblem.installFailed,
          size: update.asset?.size,
        );
        return _Notice(
          icon: AppIcons.error,
          background: colors.dangerContainer,
          foreground: colors.onDangerContainer,
          title: title,
          text: text,
        );
      case UpdateTaskPhase.idle:
        return null;
    }
  }

  Widget _actions(BuildContext context, WidgetRef ref, AppUpdateState update) {
    final l10n = context.l10n;
    final controller = ref.read(appUpdateProvider.notifier);
    void close() => Navigator.of(context).pop();
    final page = update.latest?.pageUrl;

    Widget pair(String secondary, VoidCallback? onSecondary, String primary, VoidCallback? onPrimary) => Row(
      children: [
        Expanded(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: _buttonSize),
            onPressed: onSecondary,
            child: Text(secondary),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: _buttonSize),
            onPressed: onPrimary,
            child: Text(primary),
          ),
        ),
      ],
    );

    // The in-app install was stopped or failed with the package still here.
    Widget withSystemInstaller(Widget buttons) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        buttons,
        TextButton(
          key: const ValueKey('update-system-installer'),
          onPressed: () async {
            final messenger = ScaffoldMessenger.maybeOf(context);
            if (!await controller.installWithSystem()) {
              messenger?.showSnackBar(SnackBar(content: Text(appL10n.updateSystemInstallerFailed)));
            }
          },
          child: Text(l10n.updateInstallWithSystem),
        ),
      ],
    );

    Widget busy(String label) => FilledButton(
      style: FilledButton.styleFrom(minimumSize: _buttonSize),
      onPressed: null,
      child: Text(label),
    );

    if (update.asset == null) {
      return pair(l10n.commonLater, close, l10n.updateOpenReleasePage, () => unawaited(_openPage(context, page)));
    }
    switch (update.task) {
      case UpdateTaskPhase.idle:
        // Public builds also ask for a star here, until the star prompt is answered.
        final askStar = ref.watch(starPromptGateProvider) && !ref.watch(starPromptProvider).finished;
        void star() => unawaited(
          openStarProject(ProviderScope.containerOf(context, listen: false), ScaffoldMessenger.maybeOf(context)),
        );
        const tight = EdgeInsets.symmetric(horizontal: 8);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (askStar)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(minimumSize: _buttonSize, padding: tight),
                      onPressed: close,
                      child: Text(l10n.commonLater),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('update-star'),
                      style: FilledButton.styleFrom(minimumSize: _buttonSize, padding: tight),
                      onPressed: star,
                      icon: const Icon(AppIcons.starProject, size: 18),
                      label: Text(l10n.updateStarProject),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(minimumSize: _buttonSize, padding: tight),
                      onPressed: () => unawaited(controller.startDownload()),
                      child: Text(l10n.updateUpdateNow),
                    ),
                  ),
                ],
              )
            else
              pair(l10n.commonLater, close, l10n.updateUpdateNow, () => unawaited(controller.startDownload())),
            if (!update.isSkipped)
              TextButton(
                onPressed: () {
                  unawaited(controller.skipLatest());
                  close();
                },
                child: Text(l10n.updateSkipVersion),
              ),
          ],
        );
      case UpdateTaskPhase.downloading:
        return pair(l10n.updateCancelDownload, controller.cancelDownload, l10n.updateDownloadInBackground, close);
      case UpdateTaskPhase.verifying:
        return busy(l10n.updateVerifying);
      case UpdateTaskPhase.installing:
        return busy(l10n.updateInstallingBusy);
      case UpdateTaskPhase.ready:
        final install = pair(l10n.commonLater, close, l10n.commonInstall, () => unawaited(controller.install()));
        return _installUnfinished.contains(update.problem) ? withSystemInstaller(install) : install;
      case UpdateTaskPhase.needsPermission:
        return pair(
          l10n.commonLater,
          close,
          l10n.updateOpenPermissionSettings,
          () => unawaited(controller.requestInstallPermission()),
        );
      case UpdateTaskPhase.failed:
        if (_browserOnly.contains(update.problem)) {
          return pair(l10n.commonClose, close, l10n.updateOpenReleasePage, () => unawaited(_openPage(context, page)));
        }
        final retry = pair(l10n.commonLater, close, l10n.commonRetry, () => unawaited(controller.retry()));
        return _systemInstallerHelps.contains(update.problem) ? withSystemInstaller(retry) : retry;
    }
  }
}

/// Tinted box: icon, title, explanation.
class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.background,
    required this.foreground,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final Color background;
  final Color foreground;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(color: background, shape: Squircle.border(AppShape.md)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 20, color: foreground),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall?.copyWith(color: foreground)),
                  const SizedBox(height: 2),
                  Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: foreground, height: 1.5)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Title, optional amount, a thin bar (indeterminate when [value] is null), note.
class _Progress extends StatelessWidget {
  const _Progress({required this.title, required this.note, this.trailing, this.value});

  final String title;
  final String? trailing;
  final double? value;
  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
            if (trailing case final trailing?)
              Text(trailing, style: AppType.monoLabel(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: AppShape.radiusXs,
          child: LinearProgressIndicator(value: value, minHeight: 4),
        ),
        const SizedBox(height: 8),
        Text(note, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
      ],
    );
  }
}
