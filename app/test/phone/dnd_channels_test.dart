// 不打扰模式's channel picker against the versioned status block: what each
// channel says about itself, that only an explicit tap picks one (root only
// after its notice), that a failure shows its own reason, that 保持 is the
// in-use channel's own switch, and that an old native module keeps the
// three-way page.

import 'package:dsh_app/state/phone_state.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/common/risk_notice.dart';
import 'package:dsh_app/ui/engine_settings/field_row.dart' show FieldBadge;
import 'package:dsh_app/ui/phone/dnd_mode_page.dart';
import 'package:dsh_app/ui/phone/phone_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness.dart';
import 'support.dart';

/// The row of channel [title].
Finder channel(String title) => find.ancestor(of: find.text(title), matching: find.byType(ListPageRow)).first;

/// [text] inside the row of channel [title].
Finder inRow(String title, String text) => find.descendant(of: channel(title), matching: find.text(text));

ButtonStyleButton button(WidgetTester tester, String label) => tester.widget<ButtonStyleButton>(
  find.ancestor(of: find.text(label), matching: find.bySubtype<ButtonStyleButton>()).first,
);

/// Calls that would pick a channel, ask for a permission or start su.
const _acting = {'setBackgroundMode', 'prepareRoot', 'requestShizukuPermission', 'grantSecureSettings'};

Iterable<String> acting(FakePhoneNative native) => native.methods.where(_acting.contains);

Future<void> open(WidgetTester tester, String title) async {
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the five-way block lists four channels, each with who it is for and where it stands', (tester) async {
    final h = await pumpPhone(
      tester,
      const PhoneDndPage(),
      native: FakePhoneNative(
        status: privilegedStatus(
          recommended: 'shizuku',
          shizukuApp: true,
          provider: 'shizuku',
          running: true,
          granted: true,
          wirelessDebugging: true,
          paired: true,
        ),
      ),
    );
    expect(inRow('Shizuku', '可以用'), findsOneWidget);
    expect(inRow('Shizuku', '装了 Shizuku App 的手机'), findsOneWidget);
    expect(inRow('Sui', '未检测到'), findsOneWidget);
    expect(inRow('Root', '尚未检查'), findsOneWidget);
    expect(inRow('自连 ADB', '已配对'), findsOneWidget);
    // Off is the 关闭 of the card above, not a channel; nothing is in use yet.
    expect(find.textContaining('正在使用'), findsNothing);

    // The suggestion is a quiet tag on its row, and picks nothing.
    expect(find.descendant(of: channel('Shizuku'), matching: find.byType(FieldBadge)), findsOneWidget);
    expect(find.byType(FieldBadge), findsOneWidget);
    expect(acting(h.native!), isEmpty);

    // Unfolding is not choosing either: only the button inside is.
    await open(tester, 'Shizuku');
    expect(find.text('Shizuku 这边准备好了。'), findsOneWidget);
    expect(acting(h.native!), isEmpty);
    await tester.tap(find.text('用 Shizuku 开启'));
    await tester.pumpAndSettle();
    expect(h.native!.callsOf('setBackgroundMode').single.arguments, {'mode': 'shizuku'});
    expect(find.text('正在使用：Shizuku'), findsOneWidget);
    expect(inRow('Shizuku', '使用中'), findsOneWidget);
    // Working, so folded: the common case is one glance.
    expect(find.text('Shizuku 这边准备好了。'), findsNothing);
  });

  testWidgets('root not tried yet is 尚未检查, and opening or refreshing never runs su', (tester) async {
    final h = await pumpPhone(tester, const PhoneDndPage(), native: FakePhoneNative(status: privilegedStatus()));
    expect(PhoneStatus.fromMap(h.native!.status).background.root.available, isNull);
    expect(inRow('Root', '尚未检查'), findsOneWidget);
    expect(inRow('Root', '未连接'), findsNothing);
    expect(find.byType(PhoneNote), findsNothing);

    h.native!.push(privilegedStatus(recommended: 'adb', paired: true));
    await settlePhone(tester);
    await leaveAndResume(tester);
    await open(tester, 'Root');
    expect(find.textContaining('只有主动选择后才首次执行 root 命令'), findsOneWidget);
    expect(acting(h.native!), isEmpty);
  });

  testWidgets('root is picked only after its notice, then the root manager asks', (tester) async {
    final h = await pumpPhone(tester, const PhoneDndPage(), native: FakePhoneNative(status: privilegedStatus()));
    await open(tester, 'Root');

    // Closing the notice picks nothing.
    await tester.tap(find.text('用 Root 开启'));
    await tester.pumpAndSettle();
    expect(find.byType(RiskNoticeSheet), findsOneWidget);
    expect(find.textContaining('root 管理器（Magisk、KernelSU 或 APatch）会弹窗问你'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(SheetHeader), matching: find.byType(SheetIconButton)));
    await tester.pumpAndSettle();
    expect(acting(h.native!), isEmpty);

    await tester.tap(find.text('用 Root 开启'));
    await tester.pumpAndSettle();
    expect(acting(h.native!), isEmpty);
    await tester.tap(find.byKey(const ValueKey('risk-confirm')));
    await tester.pumpAndSettle();
    expect(h.native!.callsOf('setBackgroundMode').single.arguments, {'mode': 'root'});
    expect(h.native!.callsOf('prepareRoot'), isEmpty);
  });

  testWidgets('waiting for the root manager is not a failure, and 关闭 still cancels it', (tester) async {
    final h = await pumpPhone(
      tester,
      const PhoneDndPage(),
      native: FakePhoneNative(
        status: privilegedStatus(mode: 'root', reason: '正在等待 root 授权', root: {'checked': true, 'starting': true}),
      ),
    );
    expect(find.text('正在等待 root 授权'), findsOneWidget);
    expect(inRow('Root', '等待授权'), findsOneWidget);
    expect(find.byType(PhoneNote), findsNothing);
    expect(find.text('重新申请 root 授权'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, '关闭'));
    await tester.pumpAndSettle();
    expect(h.native!.callsOf('setBackgroundMode').single.arguments, {'mode': 'off'});
  });

  testWidgets('a failing channel shows its own reason and stays picked', (tester) async {
    const reason = 'root 通道已断开，请重新选择以连接';
    final h = await pumpPhone(
      tester,
      const PhoneDndPage(),
      native: FakePhoneNative(
        status: privilegedStatus(
          mode: 'root',
          reason: reason,
          root: {'checked': true, 'available': true, 'reasonCode': 'rootDisconnected'},
          provider: 'shizuku',
          shizukuApp: true,
          running: true,
          granted: true,
        ),
      ),
    );
    expect(find.text('正在使用：Root'), findsOneWidget);
    expect(find.widgetWithText(PhoneNote, reason), findsOneWidget);
    expect(inRow('Root', '未就绪'), findsOneWidget);
    // Unfolded on its own to the one fix, which is asked for, not taken.
    expect(find.text('重新申请 root 授权'), findsOneWidget);
    // A working Shizuku is not slipped in instead.
    expect(inRow('Shizuku', '可以用'), findsOneWidget);
    expect(acting(h.native!), isEmpty);

    // A refused choice shows the native reason too, once.
    h.native!.results['setBackgroundMode'] = {'ok': false, 'reason': reason};
    await tester.tap(find.text('重新申请 root 授权'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('risk-confirm')));
    await tester.pumpAndSettle();
    expect(h.native!.callsOf('setBackgroundMode').single.arguments, {'mode': 'root'});
    expect(find.text(reason), findsOneWidget);
  });

  testWidgets('Sui answering the Shizuku interface: Shizuku says so, Sui asks through its own dialog', (tester) async {
    final h = await pumpPhone(
      tester,
      const PhoneDndPage(),
      native: FakePhoneNative(
        status: privilegedStatus(recommended: 'sui', provider: 'sui', shizukuApp: true, running: true),
      ),
    );
    expect(inRow('Shizuku', '由 Sui 提供'), findsOneWidget);
    expect(inRow('Sui', '待授权'), findsOneWidget);
    expect(find.descendant(of: channel('Sui'), matching: find.byType(FieldBadge)), findsOneWidget);

    await open(tester, 'Shizuku');
    expect(find.text('这台手机的 Shizuku 接口由 Sui 提供，请改用 Sui。'), findsOneWidget);
    expect(find.text('用 Shizuku 开启'), findsNothing);

    await open(tester, 'Sui');
    expect(find.text('Sui 接口可用'), findsOneWidget);
    await tester.tap(find.text('授权给 DSH Go'));
    await tester.pumpAndSettle();
    expect(h.native!.callsOf('requestShizukuPermission').single.arguments, {'provider': 'sui'});
    expect(h.native!.callsOf('setBackgroundMode'), isEmpty);
  });

  testWidgets('neither installed and Sui missing read differently', (tester) async {
    await pumpPhone(tester, const PhoneDndPage(), native: FakePhoneNative(status: privilegedStatus()));
    expect(inRow('Shizuku', '未安装'), findsOneWidget);
    expect(inRow('Sui', '未检测到'), findsOneWidget);
    await open(tester, 'Sui');
    expect(find.textContaining('没有检测到 Sui'), findsOneWidget);
    expect(find.text('授权给 DSH Go'), findsNothing);
    await open(tester, 'Shizuku');
    expect(find.text('打开 Shizuku 官网'), findsOneWidget);
  });

  testWidgets('an old native module keeps the three-way page, with nothing for Sui or root', (tester) async {
    final h = await pumpPhone(
      tester,
      const PhoneDndPage(),
      native: FakePhoneNative(
        status: phoneStatus(shizukuInstalled: true, shizukuRunning: true, shizukuGranted: true, paired: true),
      ),
    );
    expect(channel('Shizuku'), findsOneWidget);
    expect(channel('自连 ADB'), findsOneWidget);
    expect(find.text('Sui'), findsNothing);
    expect(find.text('Root'), findsNothing);
    expect(find.byType(FieldBadge), findsNothing);
    await open(tester, 'Shizuku');
    await tester.tap(find.text('用 Shizuku 开启'));
    await tester.pumpAndSettle();
    // The same wire as before: the old method with an old mode.
    expect(h.native!.callsOf('setBackgroundMode').single.arguments, {'mode': 'shizuku'});
    expect(h.native!.methods, isNot(contains('prepareRoot')));
  });

  testWidgets('switching from a working channel names the switch', (tester) async {
    await pumpPhone(
      tester,
      const PhoneDndPage(),
      native: FakePhoneNative(
        status: privilegedStatus(
          mode: 'adb',
          ready: true,
          provider: 'sui',
          running: true,
          granted: true,
          wirelessDebugging: true,
          paired: true,
          adbConnected: true,
        ),
      ),
    );
    await open(tester, 'Sui');
    expect(find.text('改用 Sui'), findsOneWidget);
    expect(button(tester, '改用 Sui').onPressed, isNotNull);
  });

  testWidgets('保持 is off by default and only its switch writes it, for the channel in use', (tester) async {
    final native = FakePhoneNative(
      status: privilegedStatus(mode: 'root', ready: true, root: {'checked': true, 'connected': true}),
    );
    await pumpPhone(tester, const PhoneDndPage(), native: native);
    final keep = find.widgetWithText(ListPageRow, '保持 root 通道');
    expect(find.descendant(of: keep, matching: find.textContaining('给不给仍由管理器决定')), findsOneWidget);
    expect(tester.widget<Switch>(find.descendant(of: keep, matching: find.byType(Switch))).value, isFalse);
    expect(native.callsOf('setBackgroundKeep'), isEmpty);

    await tester.tap(find.descendant(of: keep, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(native.callsOf('setBackgroundKeep').map((c) => c.arguments), [
      {'mode': 'root', 'enabled': true},
    ]);
    expect(acting(native), isEmpty);
  });

  testWidgets('with 保持 on, the line under it says how reconnecting goes', (tester) async {
    await pumpPhone(
      tester,
      const PhoneDndPage(),
      native: FakePhoneNative(
        status: privilegedStatus(
          mode: 'adb',
          paired: true,
          keep: {'enabled': true, 'mode': 'adb', 'phase': 'waiting', 'reasonCode': 'networkUnavailable'},
        ),
      ),
    );
    final keep = find.widgetWithText(ListPageRow, '保持自连 ADB 通道');
    expect(find.descendant(of: keep, matching: find.text('等连上 Wi‑Fi 后再连')), findsOneWidget);
    expect(tester.widget<Switch>(find.descendant(of: keep, matching: find.byType(Switch))).value, isTrue);
  });

  test('the main page line follows the channel actually in use', () {
    PhoneBackgroundStatus bg(Map<String, Object?> status) => PhoneStatus.fromMap(status).background;
    expect(dndSummary(bg(privilegedStatus(mode: 'sui', ready: true, provider: 'sui'))), 'Sui · 可以用了');
    expect(
      dndSummary(bg(privilegedStatus(mode: 'root', reason: 'root 未能启动，请检查 root 管理器与授权'))),
      'Root · root 未能启动，请检查 root 管理器与授权',
    );
    expect(dndSummary(bg(privilegedStatus())), '在看不见的屏幕上操作');
  });
}
