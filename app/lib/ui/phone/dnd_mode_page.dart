import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../state/phone_state.dart';
import '../common/brief_notice.dart';
import '../common/list_page_row.dart';
import '../common/segmented_pill.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'phone_widgets.dart';
import 'restricted_settings_guide.dart' show RomFamily;

/// Shizuku's own download page (official site).
const shizukuDownloadUrl = 'https://shizuku.rikka.app/download/';

/// One-line state of 不打扰模式 for the row on the main page.
String dndSummary(PhoneBackgroundStatus bg) {
  if (!bg.androidOk) return appL10n.phoneDndRequiresAndroid;
  return switch (bg.mode) {
    PhoneBackgroundMode.off => appL10n.phoneDndHiddenScreen,
    PhoneBackgroundMode.shizuku =>
      bg.ready ? appL10n.phoneDndShizukuReady : appL10n.phoneDndShizukuStatus(bg.reason ?? appL10n.phoneNotReadyYet),
    PhoneBackgroundMode.adb =>
      bg.ready ? appL10n.phoneDndAdbReady : appL10n.phoneDndAdbStatus(bg.reason ?? appL10n.phoneNotReadyYet),
  };
}

/// Group spacing: 24 between consecutive cards.
const _groupMargin = EdgeInsets.fromLTRB(16, 12, 16, 12);

/// 不打扰模式: Agent works on a virtual display through Shizuku or the app's own
/// wireless-debugging connection. Advanced, off by default; the
/// page says plainly what it costs and what it doesn't do.
class PhoneDndPage extends ConsumerStatefulWidget {
  const PhoneDndPage({super.key});

  @override
  ConsumerState<PhoneDndPage> createState() => _PhoneDndPageState();
}

class _PhoneDndPageState extends ConsumerState<PhoneDndPage> {
  /// Which setup is shown; starts at the mode in use (Shizuku when off).
  PhoneBackgroundMode? _view;
  bool _busy = false;
  String? _error;
  late final AppLifecycleListener _lifecycle;

  PhoneController get _phone => ref.read(phoneProvider.notifier);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_phone.refreshStatus()));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(Future<PhoneResult> Function() action, {String? done}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await action();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = result.ok ? null : (result.reason ?? context.l10n.phoneActionFailedLater);
    });
    if (result.ok && done != null) showBriefNotice(context, done);
  }

  Future<void> _setMode(PhoneBackgroundMode mode) => _run(
    () => _phone.setBackgroundMode(mode),
    done: mode == PhoneBackgroundMode.off ? context.l10n.phoneDndDisabled : context.l10n.phoneDndEnabled,
  );

  Future<void> _grantShizuku() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await _phone.requestShizukuPermission();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) _toast(context.l10n.phoneDndShizukuPermissionFailed);
  }

  Future<void> _openShizukuSite() async {
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(shizukuDownloadUrl), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok && mounted) {
      _toast(context.l10n.phoneDndBrowserFailed(shizukuDownloadUrl));
    }
  }

  Future<void> _manualPair() async {
    final l10n = context.l10n;
    final entered = await showDialog<(String, int?)>(context: context, builder: (_) => const _PairDialog());
    if (entered == null) return;
    await _run(() => _phone.adbPair(entered.$1, port: entered.$2), done: l10n.phoneDndPairedConnect);
  }

  Future<void> _manualConnect() async {
    final l10n = context.l10n;
    final port = await showDialog<int>(context: context, builder: (_) => const _ConnectDialog());
    if (port == null || !mounted) return;
    await _run(() => _phone.adbConnect(port: port), done: l10n.phoneDndConnected);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final bg = ref.watch(phoneProvider.select((s) => s.status.background));
    final view = _view ?? (bg.mode == PhoneBackgroundMode.off ? PhoneBackgroundMode.shizuku : bg.mode);
    final usable = bg.androidOk;

    return AppPage.list(
      title: l10n.phoneDndTitle,
      subtitle: Text(l10n.phoneDndSubtitle),
      children: [
        if (!usable) PhoneNote(tone: NoteTone.warn, text: l10n.phoneDndUnsupported),
        ListPageCard(
          margin: _groupMargin,
          title: l10n.phoneDndRequirements,
          children: [
            BulletLines([l10n.phoneDndKeepUnlocked, l10n.phoneDndReactivate, l10n.phoneDndKeepDebugging]),
          ],
        ),
        if (bg.mode != PhoneBackgroundMode.off)
          ListPageCard(
            margin: _groupMargin,
            children: [
              ListPageRow(
                icon: AppIcons.dndMode,
                iconColor: Theme.of(context).colorScheme.primary,
                title: bg.mode == PhoneBackgroundMode.shizuku ? l10n.phoneDndUsingShizuku : l10n.phoneDndUsingAdb,
                subtitle: bg.ready ? l10n.phoneReady : (bg.reason ?? l10n.phoneNotReadyYet),
                trailing: TextButton(
                  onPressed: _busy ? null : () => _setMode(PhoneBackgroundMode.off),
                  child: Text(l10n.commonClose),
                ),
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: SegmentedPill<PhoneBackgroundMode>(
            segments: [
              PillSegment(PhoneBackgroundMode.shizuku, l10n.phoneDndUseShizuku),
              PillSegment(PhoneBackgroundMode.adb, l10n.phoneDndDirectAdb),
            ],
            selected: view,
            onChanged: (mode) => setState(() {
              _view = mode;
              _error = null;
            }),
          ),
        ),
        if (_error case final error?) PhoneNote(tone: NoteTone.warn, text: error),
        if (view == PhoneBackgroundMode.shizuku) ..._shizuku(bg, usable) else ..._adb(bg, usable),
      ],
    );
  }

  List<Widget> _shizuku(PhoneBackgroundStatus bg, bool usable) {
    final s = bg.shizuku;
    final sdk = ref.watch(phoneProvider.select((p) => p.status.device.sdkInt));
    final android17 = (sdk ?? 0) >= 37;
    final allSet = s.running && s.granted;
    final inUse = bg.mode == PhoneBackgroundMode.shizuku;
    final Widget next;
    if (!s.running && !s.installed) {
      next = _Next(
        text: context.l10n.phoneDndInstallShizuku,
        button: OutlinedButton.icon(
          onPressed: _openShizukuSite,
          icon: const Icon(AppIcons.openExternal, size: 18),
          label: Text(context.l10n.phoneDndOpenShizukuSite),
        ),
      );
    } else if (!s.running) {
      next = _Next(text: context.l10n.phoneDndStartShizuku);
    } else if (!s.granted) {
      next = _Next(
        text: context.l10n.phoneDndGrantShizukuHint,
        button: FilledButton(onPressed: _busy ? null : _grantShizuku, child: Text(context.l10n.phoneDndGrantShizuku)),
      );
    } else {
      next = _Next(text: context.l10n.phoneDndShizukuAllSet);
    }
    return [
      ListPageCard(
        margin: _groupMargin,
        title: 'Shizuku',
        children: [
          if (s.installed || !s.running) CheckRow(label: context.l10n.phoneDndShizukuInstalled, done: s.installed),
          CheckRow(label: context.l10n.phoneDndShizukuRunning, done: s.running),
          CheckRow(label: context.l10n.phoneDndShizukuGranted, done: s.granted),
          next,
        ],
      ),
      if (!inUse)
        _EnableButton(onPressed: usable && allSet && !_busy ? () => _setMode(PhoneBackgroundMode.shizuku) : null),
      if (android17) PageFootnote(context.l10n.phoneDndShizukuCompatibility),
    ];
  }

  List<Widget> _adb(PhoneBackgroundStatus bg, bool usable) {
    final a = bg.adb;
    final maker = ref.watch(phoneProvider.select((s) => s.status.device.manufacturer));
    final xiaomi = RomFamily.of(maker) == RomFamily.xiaomi;
    final inUse = bg.mode == PhoneBackgroundMode.adb;
    return [
      ListPageCard(
        margin: _groupMargin,
        title: context.l10n.commonStatus,
        children: [
          CheckRow(
            label: context.l10n.phoneDndWirelessDebuggingOn,
            done: a.wirelessDebugging == true,
            unknown: a.wirelessDebugging == null,
          ),
          CheckRow(label: context.l10n.phoneDndPaired, done: a.paired),
          CheckRow(label: context.l10n.phoneDndConnected, done: a.connected),
        ],
      ),
      ListPageCard(
        margin: _groupMargin,
        title: context.l10n.phoneDndPairOnce,
        children: [
          NumberedSteps([
            context.l10n.phoneDndDeveloperOptionsStep,
            context.l10n.phoneDndWirelessDebuggingStep,
            context.l10n.phoneDndStartPairingStep,
            context.l10n.phoneDndGetPairingCodeStep,
            context.l10n.phoneDndEnterPairingCodeStep,
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
            // Three equal steps, equal width; the one filled button on the
            // page stays 「启用不打扰模式」 below.
            child: Row(
              spacing: 8,
              children: [
                for (final (label, onPressed) in [
                  (
                    context.l10n.phoneDndStartPairing,
                    usable && !_busy
                        ? () => _run(_phone.adbStartPairing, done: context.l10n.phoneDndPairingNotificationSent)
                        : null,
                  ),
                  (context.l10n.phoneDndManualEntry, usable && !_busy ? _manualPair : null),
                  (
                    context.l10n.phoneDndConnect,
                    usable && a.paired && !_busy
                        ? () => _run(_phone.adbConnect, done: context.l10n.phoneDndConnected)
                        : null,
                  ),
                ])
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                      onPressed: onPressed,
                      child: FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1)),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextButton(
              onPressed: usable && a.paired && !_busy ? _manualConnect : null,
              child: Text(context.l10n.phoneDndManualConnect),
            ),
          ),
        ],
      ),
      if (!inUse)
        _EnableButton(onPressed: usable && a.connected && !_busy ? () => _setMode(PhoneBackgroundMode.adb) : null),
      PageFootnote([context.l10n.phoneDndManualEntryHint, if (xiaomi) context.l10n.phoneDndXiaomiUsbHint].join('\n')),
    ];
  }
}

class _Next extends StatelessWidget {
  const _Next({required this.text, this.button});

  final String text;
  final Widget? button;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5),
          ),
          if (button case final button?) ...[const SizedBox(height: 10), button],
        ],
      ),
    );
  }
}

class _EnableButton extends StatelessWidget {
  const _EnableButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: onPressed,
        child: Text(l10n.phoneDndEnable),
      ),
    );
  }
}

/// The in-app pairing fallback: six-digit code, optional port.
class _PairDialog extends StatefulWidget {
  const _PairDialog();

  @override
  State<_PairDialog> createState() => _PairDialogState();
}

/// ROMs with broken mDNS can connect to the device's current adbd port directly.
class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog();

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  final _port = TextEditingController();

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final port = int.tryParse(_port.text.trim());
    final valid = port != null && port >= 1 && port <= 65535;
    return AlertDialog(
      title: Text(l10n.phoneDndManualConnect),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.phoneDndConnectPortHint),
          TextField(
            key: const ValueKey('adb-connect-port'),
            controller: _port,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 5,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: l10n.phoneDndConnectPortLabel),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
        FilledButton(onPressed: valid ? () => Navigator.pop(context, port) : null, child: Text(l10n.phoneDndConnect)),
      ],
    );
  }
}

class _PairDialogState extends State<_PairDialog> {
  final _code = TextEditingController();
  final _port = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    _port.dispose();
    super.dispose();
  }

  bool get _valid => RegExp(r'^\d{6}$').hasMatch(_code.text.trim());

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.phoneDndEnterCodeTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _code,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: l10n.phoneDndCodeLabel),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            maxLength: 5,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: l10n.phoneDndPortLabel, helperText: l10n.phoneDndPortHint),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: _valid ? () => Navigator.pop(context, (_code.text.trim(), int.tryParse(_port.text.trim()))) : null,
          child: Text(l10n.phoneDndPair),
        ),
      ],
    );
  }
}
