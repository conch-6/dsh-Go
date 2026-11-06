import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/background_net.dart';
import '../../runtime/runtime_state.dart';
import '../../state/app_info.dart';
import '../shell/page_frame.dart';
import '../theme/theme.dart';
import 'settings_widgets.dart';
import '../common/row_marks.dart';
import '../common/smooth_size.dart';

/// Keeping conversations running in the background: this phone maker's own
/// switch first (one tap opens it where the ROM allows, else the app's system
/// page), the system battery exemption, then where the other makers keep theirs.
///
/// The vendor pages are reverse-engineered and move between ROM versions:
/// the native side tries them only when they
/// resolve and falls back to the app's details page, and every row also says
/// where the switch lives.
class BackgroundGuidePage extends ConsumerStatefulWidget {
  const BackgroundGuidePage({super.key});

  @override
  ConsumerState<BackgroundGuidePage> createState() => _BackgroundGuidePageState();
}

/// One maker's switch: the name it has in their settings, and the way there.
typedef _VendorSwitch = ({String name, String key, String path});

class _BackgroundGuidePageState extends ConsumerState<BackgroundGuidePage> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Back from the system dialog or settings page: read the exemption again.
    _lifecycle = AppLifecycleListener(onResume: () => ref.invalidate(batteryExemptProvider));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// This phone's row, by the native vendor key; `{app}` is the app's name in system settings.
  static Map<String, _VendorSwitch> get _switches => <String, _VendorSwitch>{
    'vivo': (name: 'vivo / iQOO', key: appL10n.pluginsAllowHighPower, path: appL10n.pluginsVivoBatteryPath('{app}')),
    'xiaomi': (
      name: appL10n.brandXiaomi,
      key: appL10n.pluginsXiaomiBatterySetting,
      path: appL10n.pluginsXiaomiBatteryPath('{app}'),
    ),
    'huawei': (
      name: appL10n.brandHuawei,
      key: appL10n.pluginsHuaweiBatterySetting,
      path: appL10n.pluginsHuaweiBatteryPath('{app}'),
    ),
    'honor': (
      name: appL10n.brandHonor,
      key: appL10n.pluginsHuaweiBatterySetting,
      path: appL10n.pluginsHuaweiBatteryPath('{app}'),
    ),
    'oppo': (
      name: appL10n.brandOppo,
      key: appL10n.pluginsOppoBatterySetting,
      path: appL10n.pluginsOppoBatteryPath('{app}'),
    ),
    'samsung': (
      name: appL10n.brandSamsung,
      key: appL10n.pluginsSamsungBatterySetting,
      path: appL10n.pluginsSamsungBatteryPath('{app}'),
    ),
  };

  /// Every maker, for phones of the others: (vendor keys, label, where).
  static List<(Set<String>, String, List<String>)> get _vendors => [
    ({'vivo'}, appL10n.brandVivoOs, [appL10n.pluginsVivoBatteryPath('{app}'), appL10n.pluginsVivoBatteryStep]),
    (
      {'xiaomi'},
      appL10n.brandXiaomiOs,
      [appL10n.pluginsXiaomiBatteryFullPath('{app}'), appL10n.pluginsXiaomiAutostart],
    ),
    (
      {'huawei', 'honor'},
      appL10n.brandHuaweiOs,
      [appL10n.pluginsHuaweiBatteryPath('{app}'), appL10n.pluginsHuaweiBatteryStep],
    ),
    ({'oppo'}, appL10n.brandOppoOs, [appL10n.pluginsOppoBatteryPath('{app}'), appL10n.pluginsOppoBatteryStep]),
    (
      {'samsung'},
      appL10n.brandSamsungOs,
      [appL10n.pluginsSamsungBatteryPath('{app}'), appL10n.pluginsSamsungBatteryStep],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Null without the native side (or on error): no row.
    final exempt = ref.watch(batteryExemptProvider).value;
    final settings = ref.watch(backgroundSettingsProvider).value;
    final app = settings?.label ?? AppInfo.name;
    final vendor = settings?.vendor;
    final mine = _switches[vendor];
    String named(String text) => text.replaceAll('{app}', app);
    return AppPage.list(
      title: l10n.pluginsBackgroundTitle,
      subtitle: Text(l10n.pluginsBackgroundDescription),
      children: [
        if (mine != null)
          SettingsSection(
            title: mine.name,
            children: [
              SettingsTile(
                title: mine.key,
                subtitle: named(mine.path),
                chevron: true,
                onTap: () => unawaited(ref.read(runtimeBridgeProvider).openBackgroundSettings()),
              ),
            ],
          ),
        if (exempt != null)
          SettingsSection(
            title: l10n.pluginsSystem,
            children: [
              SettingsTile(
                title: l10n.pluginsSystemBatteryOptimization,
                value: Text(
                  exempt ? l10n.pluginsTurnedOff : l10n.pluginsNotTurnedOff,
                  style: TextStyle(color: exempt ? null : DshColors.of(context).warning),
                ),
                onTap: exempt
                    ? null
                    : () async {
                        await ref.read(runtimeBridgeProvider).requestBatteryExempt();
                        if (mounted) ref.invalidate(batteryExemptProvider);
                      },
              ),
            ],
          ),
        SettingsSection(
          title: l10n.pluginsStayOnline,
          children: [
            _Step(index: 1, text: l10n.pluginsKeepEngineNotification),
            _Step(index: 2, text: l10n.pluginsLockInRecents(app)),
          ],
        ),
        SettingsSection(
          title: mine == null ? l10n.pluginsPhoneBrands : l10n.pluginsOtherBrands,
          children: [
            for (final (keys, label, steps) in _vendors)
              if (!keys.contains(vendor)) _VendorRow(vendor: label, steps: [for (final s in steps) named(s)]),
          ],
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: SettingsMetrics.rowHeight),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 8, SettingsMetrics.inset, 8),
        child: Row(
          children: [
            SizedBox.square(
              dimension: SettingsMetrics.icon,
              child: Center(
                child: DecoratedBox(
                  decoration: ShapeDecoration(color: scheme.primaryContainer, shape: const CircleBorder()),
                  child: SizedBox.square(
                    dimension: 24,
                    child: Center(
                      child: Text(
                        '$index',
                        style: AppType.tabular(theme.textTheme.labelMedium!.copyWith(color: scheme.onPrimaryContainer)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: SettingsMetrics.iconGap),
            Expanded(child: Text(text, style: settingsTitleStyle(context))),
          ],
        ),
      ),
    );
  }
}

/// One phone brand: tap to unfold where its switch lives (size + fade).
class _VendorRow extends StatefulWidget {
  const _VendorRow({required this.vendor, required this.steps});

  final String vendor;
  final List<String> steps;

  @override
  State<_VendorRow> createState() => _VendorRowState();
}

class _VendorRowState extends State<_VendorRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final duration = AppMotion.of(context, AppMotion.standard);
    final steps = Padding(
      padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 0, SettingsMetrics.inset, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final step in widget.steps)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(step, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          expanded: _open,
          child: InkWell(
            onTap: () => setState(() => _open = !_open),
            splashFactory: rowSplash(context),
            highlightColor: scheme.onSurface.withValues(alpha: 0.05),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: SettingsMetrics.rowHeight),
              child: Padding(
                // The ⌄'s ink ends 16 in, on the edge the › above ends on.
                padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 6, SettingsMetrics.inset, 6),
                child: Row(
                  children: [
                    Expanded(child: Text(widget.vendor, style: settingsTitleStyle(context))),
                    const SizedBox(width: 12),
                    RowExpandArrow(open: _open),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (duration == Duration.zero)
          _open ? steps : const SizedBox.shrink()
        else
          SmoothSize(
            duration: duration,
            curve: AppMotion.collapseCurve,
            alignment: Alignment.topCenter,
            child: AnimatedOpacity(
              opacity: _open ? 1 : 0,
              duration: duration,
              child: _open ? steps : const SizedBox(width: double.infinity),
            ),
          ),
      ],
    );
  }
}
