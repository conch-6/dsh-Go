// The typed wrapper over `dsh/phone`: parsing the contract's maps, and staying
// usable when the native side is missing or throws.

import 'package:dsh_app/phone/phone_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final channel = PhoneChannel();

  test('status parses every field of the contract', () async {
    final native = FakePhoneNative(
      status: phoneStatus(
        a11y: true,
        notifications: false,
        mode: 'shizuku',
        backgroundReady: false,
        backgroundReason: 'Shizuku 没有在运行',
        shizukuInstalled: true,
        wirelessDebugging: null,
        paired: true,
        taskActive: true,
        taskApp: '美团',
        taskPaused: true,
      ),
    )..install();
    final s = await channel.status();
    expect(native.methods, ['status']);
    expect(s.ready, isTrue);
    expect(s.enabled, isTrue);
    expect(s.bridgeListening, isTrue);
    expect(s.a11y.ok, isTrue);
    expect(s.notifications, isFalse);
    expect(s.background.mode, PhoneBackgroundMode.shizuku);
    expect(s.background.reason, 'Shizuku 没有在运行');
    expect(s.background.androidOk, isTrue);
    expect(s.background.shizuku.installed, isTrue);
    expect(s.background.shizuku.running, isFalse);
    expect(s.background.adb.wirelessDebugging, isNull);
    expect(s.background.adb.paired, isTrue);
    expect(s.task.active, isTrue);
    expect(s.task.app, '美团');
    expect(s.task.paused, isTrue);
    expect(s.device.manufacturer, 'vivo');
    expect(s.device.sdkInt, 35);
    expect(s.device.mayNeedRestrictedSettings, isTrue);
  });

  test('a status without the optional device entry still parses', () async {
    FakePhoneNative(status: phoneStatus(device: null)).install();
    final s = await channel.status();
    expect(s.ready, isTrue);
    expect(s.device.manufacturer, isNull);
    // Unknown → the restricted-settings hint may apply.
    expect(s.device.mayNeedRestrictedSettings, isTrue);
    expect(const PhoneDevice(sdkInt: 32, sideloaded: true).mayNeedRestrictedSettings, isFalse);
    expect(const PhoneDevice(sdkInt: 34, sideloaded: false).mayNeedRestrictedSettings, isFalse);
  });

  test('a missing native side reads as 未就绪 and every call degrades', () async {
    removePhoneNative();
    final s = await channel.status();
    expect(s.ready, isFalse);
    expect(await channel.setEnabled(true), isFalse);
    expect(await channel.openAccessibilitySettings(), isFalse);
    final test = await channel.testScreen();
    expect(test.ok, isFalse);
    expect(test.reason, phoneNotReadyReason);
    final pair = await channel.adbPair('123456');
    expect(pair.ok, isFalse);
    expect(pair.reason, phoneNotReadyReason);
    expect(await channel.getPolicies(), isNull);
    expect(await channel.actionLog(), isEmpty);
  });

  test('PlatformException becomes a reason, not a crash', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(phoneMethods, (
      call,
    ) async {
      throw PlatformException(code: 'boom', message: '无障碍服务没有连接');
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        phoneMethods,
        null,
      ),
    );
    final s = await channel.status();
    expect(s.ready, isFalse);
    expect(s.error, '无障碍服务没有连接');
    final r = await channel.testScreen();
    expect(r.ok, isFalse);
    expect(r.reason, '无障碍服务没有连接');
    expect((await channel.adbConnect()).reason, '无障碍服务没有连接');
  });

  test('method arguments follow the contract', () async {
    final native = FakePhoneNative()..install();
    await channel.setEnabled(true);
    await channel.setBackgroundMode(PhoneBackgroundMode.adb);
    await channel.adbPair('482913', port: 37123);
    await channel.adbConnect(port: 45269);
    await channel.actionLog(limit: 7);
    await channel.setPolicies(
      const PhonePolicies(
        denyPackages: ['cmb.pb'],
        confirmEveryWritePackages: ['com.tencent.mm'],
        labels: {'cmb.pb': '招商银行'},
      ),
    );
    expect(native.callsOf('setEnabled').single.arguments, {'enabled': true});
    expect(native.callsOf('setBackgroundMode').single.arguments, {'mode': 'adb'});
    expect(native.callsOf('adbPair').single.arguments, {'code': '482913', 'port': 37123});
    expect(native.callsOf('adbConnect').single.arguments, {'port': 45269});
    expect(native.callsOf('actionLog').single.arguments, {'limit': 7});
    // Only the two lists and the confirm mode go over the wire.
    expect(native.callsOf('setPolicies').single.arguments, {
      'denyPackages': ['cmb.pb'],
      'confirmEveryWritePackages': ['com.tencent.mm'],
      'confirmMode': 'ask',
    });
  });

  test('policies: rules, labels, defaults and edits', () async {
    FakePhoneNative(
      policies: {
        ...defaultPolicies(),
        'labels': {'com.unionpay': '云闪付 App'},
        'defaults': {
          'denyPackages': ['com.eg.android.AlipayGphone', 'com.unionpay'],
          'confirmEveryWritePackages': ['com.tencent.mm'],
        },
      },
    ).install();
    final p = (await channel.getPolicies())!;
    expect(p.ruleFor('com.eg.android.AlipayGphone'), AppRule.deny);
    expect(p.ruleFor('com.tencent.mm'), AppRule.confirmEachStep);
    expect(p.ruleFor('com.taobao.taobao'), AppRule.normal);
    expect(p.labelFor('com.unionpay'), '云闪付 App'); // native label wins
    expect(p.labelFor('com.tencent.mm'), '微信'); // built-in fallback
    expect(p.labelFor('org.example.x'), 'org.example.x');
    expect(p.defaultRuleFor('com.tencent.mm'), AppRule.confirmEachStep);

    final edited = p.withRule('com.tencent.mm', AppRule.normal).withRule('com.taobao.taobao', AppRule.deny);
    expect(edited.confirmEveryWritePackages, isEmpty);
    expect(edited.denyPackages, contains('com.taobao.taobao'));
    expect(edited.defaultConfirm, ['com.tencent.mm']);
  });

  test('action log entries tolerate time formats and odd decisions', () async {
    FakePhoneNative(
      log: [
        {'time': 1761000000, 'tool': 'tap', 'decision': 'denied'},
        {'time': '2026-10-23T08:00:00Z', 'tool': 'type', 'decision': 'confirmed-app'},
        {'tool': 'scroll', 'decision': 'something-new'},
        {'time': 1761000000000, 'tool': 'handoff', 'decision': 'timeout'},
        {'time': 1761000000000, 'tool': 'tap', 'decision': 'allowed'},
        {'time': 1761000000000, 'tool': 'open', 'decision': 'refused:system-page'},
        {'time': 1761000000000, 'tool': 'tap', 'decision': 'paused'},
      ],
    ).install();
    final log = await channel.actionLog();
    expect(log, hasLength(7));
    expect(log[0].time, DateTime.fromMillisecondsSinceEpoch(1761000000 * 1000));
    expect(log[0].decision, PhoneDecision.denied);
    expect(log[1].time, DateTime.utc(2026, 10, 23, 8).toLocal());
    expect(log[1].decision, PhoneDecision.allowed);
    expect(log[2].time, isNull);
    expect(log[2].decision, PhoneDecision.unknown);
    expect(log[2].rawDecision, 'something-new');
    // Native `timeout` is the tool running out of time, not an unanswered question.
    expect(log[3].decision, PhoneDecision.failed);
    // Native `allowed` means no question was needed.
    expect(log[4].decision, PhoneDecision.done);
    expect(log[5].decision, PhoneDecision.blocked);
    expect(log[6].decision, PhoneDecision.stopped);
  });
}
