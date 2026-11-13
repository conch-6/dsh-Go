// 掷骰 (docs/design/roleplay-ui.md §6, §11): pick the dice, roll, and put
// what came up into the composer. The number tumbles a moment before it
// settles (not with reduced motion), with a light tap when it does.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_dice.dart';
import '../common/app_sheet.dart';
import '../common/capsule_chip.dart';
import '../common/fluid_bits.dart';
import '../common/sheet_title_bar.dart';
import '../engine_settings/field_sheets.dart' show SheetCard, StepKey;
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// The line to put in the composer, or null when closed without one.
Future<String?> showTavernDice(BuildContext context) =>
    showAppSheet<String>(context, isScrollControlled: true, builder: (_) => const TavernDiceSheet());

/// The line a roll goes into the chat as: 🎲 2d6+1 掷出 9（3 + 5 + 1）.
String tavernRollLine(L10n l10n, TavernRoll roll) =>
    l10n.tavernDiceLine(roll.dice.notation, roll.total, switch (roll.working) {
      final working? => l10n.tavernDiceWorking(working),
      null => '',
    });

class TavernDiceSheet extends ConsumerStatefulWidget {
  const TavernDiceSheet({super.key});

  /// How long the number tumbles before it settles.
  static const tumble = Duration(milliseconds: 560);
  static const _tick = Duration(milliseconds: 70);

  @override
  ConsumerState<TavernDiceSheet> createState() => _TavernDiceSheetState();
}

class _TavernDiceSheetState extends ConsumerState<TavernDiceSheet> {
  TavernRoll? _roll;

  /// What the big number says: a passing face while tumbling, else the total.
  String? _shown;
  Timer? _tumble;

  @override
  void dispose() {
    _tumble?.cancel();
    super.dispose();
  }

  bool get _rolling => _tumble != null;

  void _choose(TavernDice dice) {
    ref.read(tavernDiceProvider.notifier).set(dice);
    // A new choice: what was rolled before no longer goes with it.
    _tumble?.cancel();
    setState(() {
      _tumble = null;
      _roll = null;
      _shown = null;
    });
  }

  void _throw() {
    final dice = ref.read(tavernDiceProvider);
    final random = ref.read(tavernDiceRandomProvider);
    final roll = dice.roll(random);
    _tumble?.cancel();
    void land() {
      _tumble?.cancel();
      setState(() {
        _tumble = null;
        _roll = roll;
        _shown = '${roll.total}';
      });
      unawaited(HapticFeedback.lightImpact());
    }

    if (AppMotion.reduced(context)) {
      land();
      return;
    }
    var left = TavernDiceSheet.tumble.inMilliseconds ~/ TavernDiceSheet._tick.inMilliseconds;
    setState(() {
      _tumble = Timer.periodic(TavernDiceSheet._tick, (_) {
        if (!mounted) return;
        if (--left <= 0) {
          land();
        } else {
          setState(() => _shown = '${dice.lowest + random.nextInt(dice.highest - dice.lowest + 1)}');
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final dice = ref.watch(tavernDiceProvider);
    final roll = _roll;
    // While it tumbles, nothing is settled yet.
    final settled = _rolling ? null : roll;
    final working = settled?.working;
    final big = AppType.tabular(theme.textTheme.displaySmall!.copyWith(fontWeight: FontWeight.w600));
    final label = theme.textTheme.bodyLarge;
    final value = AppType.tabular(theme.textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w600));

    Widget stepper({
      required String title,
      required String shown,
      required String fewer,
      required String more,
      required VoidCallback? onFewer,
      required VoidCallback? onMore,
      required String name,
    }) => Row(
      children: [
        Expanded(child: Text(title, style: label)),
        StepKey(key: ValueKey('tavern-dice-$name-down'), icon: AppIcons.decrement, tooltip: fewer, onPressed: onFewer),
        SizedBox(
          width: 56,
          child: Text(shown, key: ValueKey('tavern-dice-$name'), textAlign: TextAlign.center, style: value),
        ),
        StepKey(key: ValueKey('tavern-dice-$name-up'), icon: AppIcons.increment, tooltip: more, onPressed: onMore),
      ],
    );

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.tavernDice),
            Padding(
              padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // What came up.
                  SheetCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                    child: Semantics(
                      liveRegion: true,
                      label: settled == null ? dice.notation : tavernRollLine(l10n, settled),
                      excludeSemantics: true,
                      child: Column(
                        children: [
                          SizedBox(
                            height: 56,
                            child: Center(
                              child: _shown == null
                                  ? Text(dice.notation, style: big.copyWith(color: dsh.textTertiary))
                                  : RollingCount(_shown!, key: const ValueKey('tavern-dice-total'), style: big),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            settled == null ? ' ' : (working == null ? dice.notation : '${dice.notation} · $working'),
                            key: const ValueKey('tavern-dice-working'),
                            textAlign: TextAlign.center,
                            style: AppType.tabular(
                              theme.textTheme.bodyMedium!.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final sides in tavernDiceSides)
                        CapsuleChoiceChip(
                          key: ValueKey('tavern-dice-d$sides'),
                          label: 'd$sides',
                          selected: dice.sides == sides,
                          onSelected: () => _choose(dice.copyWith(sides: sides)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  stepper(
                    name: 'count',
                    title: l10n.tavernDiceCount,
                    shown: '${dice.count}',
                    fewer: l10n.tavernDiceFewer,
                    more: l10n.tavernDiceMore,
                    onFewer: dice.count > 1 ? () => _choose(dice.copyWith(count: dice.count - 1)) : null,
                    onMore: dice.count < tavernDiceMaxCount
                        ? () => _choose(dice.copyWith(count: dice.count + 1))
                        : null,
                  ),
                  const SizedBox(height: 12),
                  stepper(
                    name: 'modifier',
                    title: l10n.tavernDiceModifier,
                    shown: dice.modifier > 0 ? '+${dice.modifier}' : '${dice.modifier}',
                    fewer: l10n.tavernDiceModifierDown,
                    more: l10n.tavernDiceModifierUp,
                    onFewer: dice.modifier > -tavernDiceMaxModifier
                        ? () => _choose(dice.copyWith(modifier: dice.modifier - 1))
                        : null,
                    onMore: dice.modifier < tavernDiceMaxModifier
                        ? () => _choose(dice.copyWith(modifier: dice.modifier + 1))
                        : null,
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: roll == null
                            ? FilledButton(
                                key: const ValueKey('tavern-dice-roll'),
                                onPressed: _rolling ? null : _throw,
                                child: Text(l10n.tavernDiceRoll),
                              )
                            : OutlinedButton(
                                key: const ValueKey('tavern-dice-roll'),
                                onPressed: _rolling ? null : _throw,
                                child: Text(l10n.tavernDiceAgain),
                              ),
                      ),
                      if (roll != null) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            key: const ValueKey('tavern-dice-use'),
                            onPressed: _rolling ? null : () => Navigator.of(context).pop(tavernRollLine(l10n, roll)),
                            child: Text(l10n.tavernDiceUse),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
