import 'package:dsh_app/phone/phone_channel.dart';
import 'package:dsh_app/ui/phone/dnd_mode_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'support.dart';

/// A connected, authorized Shizuku channel; [extra] adds raw native `background` fields.
Map<String, Object?> connectedStatus([Map<String, Object?> extra = const {}]) {
  final base = privilegedStatus(
    mode: 'shizuku',
    ready: true,
    provider: 'shizuku',
    shizukuApp: true,
    running: true,
    granted: true,
  );
  return {
    ...base,
    'background': {...(base['background'] as Map).cast<String, Object?>(), ...extra},
  };
}

void main() {
  test('a failed self-check is only a note on an otherwise ready status', () {
    final status = PhoneBackgroundStatus.fromMap(
      (connectedStatus({'selfCheckWarning': 'Self-check did not pass'})['background'] as Map).cast<Object?, Object?>(),
    );
    expect(status.effectiveReady, isTrue);
    expect(status.selfCheckWarning, 'Self-check did not pass');
    expect(PhoneBackgroundStatus.fromMap(const <Object?, Object?>{'mode': 'off'}).selfCheckWarning, isNull);
  });

  testWidgets('a ready channel shows the self-check note and triggers nothing by itself', (tester) async {
    final native = FakePhoneNative(status: connectedStatus({'selfCheckWarning': 'Self-check did not pass'}));
    await pumpPhone(tester, const PhoneDndPage(), native: native);
    expect(find.byKey(const ValueKey('phone-dnd-self-check-warning')), findsOneWidget);
    expect(find.text('Self-check did not pass'), findsOneWidget);
    expect(native.methods, ['status', 'getPolicies', 'actionLog']);
  });

  testWidgets('fields of the removed cleanup and recovery gates show nothing and block nothing', (tester) async {
    final native = FakePhoneNative(
      status: connectedStatus({
        'gateCleanup': {'v': 1, 'state': 'unknown', 'canRetry': true, 'handle': 'old'},
        'resourceRecovery': {'v': 1, 'state': 'pending', 'count': 2, 'canRetry': true},
      }),
    );
    await pumpPhone(tester, const PhoneDndPage(), native: native);
    expect(find.byKey(const ValueKey('phone-gate-cleanup')), findsNothing);
    expect(find.byKey(const ValueKey('phone-resource-recovery')), findsNothing);
    expect(find.byKey(const ValueKey('phone-dnd-self-check-warning')), findsNothing);
    expect(native.methods, ['status', 'getPolicies', 'actionLog']);
  });
}
