import 'dart:async';

import 'package:dsh_app/phone/phone_channel.dart';
import 'package:dsh_app/ui/phone/dnd_mode_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'support.dart';

Map<String, Object?> cleanupStatus({String state = 'unknown', bool canRetry = true, String? handle = 'original-handle'}) {
  final base = privilegedStatus(mode: 'shizuku', provider: 'shizuku', shizukuApp: true,
    running: true, granted: true, reason: 'Needs an explicit new check');
  return {...base, 'background': {
    ...(base['background'] as Map).cast<String, Object?>(),
    'gateCleanup': {'v': 1, 'state': state, 'canRetry': canRetry, 'handle': handle},
  }};
}

void main() {
  test('only exact versioned cleanup metadata enables the original handle', () {
    expect(PhoneGateCleanup.parse({'v': 1, 'state': 'unknown', 'canRetry': true, 'handle': 'A'})!.handle, 'A');
    for (final map in <Map<String, Object?>>[
      {}, {'v': 1.0, 'state': 'unknown', 'canRetry': true, 'handle': 'A'},
      {'v': 2, 'state': 'unknown', 'canRetry': true, 'handle': 'A'},
      {'v': 1, 'state': 'pending', 'canRetry': true, 'handle': 'A'},
      {'v': 1, 'state': 'unknown', 'canRetry': true, 'handle': null},
      {'v': 1, 'state': 'idle', 'canRetry': true, 'handle': null},
      {'v': 1, 'state': 'released', 'canRetry': false, 'handle': 'A'},
    ]) { expect(PhoneGateCleanup.parse(map), isNull); }
  });

  testWidgets('explicit retry sends only the displayed handle and never automatically selects a mode', (tester) async {
    final native = FakePhoneNative(status: cleanupStatus());
    final completed = Completer<Map<String, Object?>>();
    native.onRetryGateCleanup = (args) async {
      expect(args, {'v': 1, 'handle': 'original-handle'});
      final result = await completed.future;
      native.status = cleanupStatus(state: 'idle', canRetry: false, handle: null);
      return result;
    };
    await pumpPhone(tester, const PhoneDndPage(), native: native);
    expect(native.callsOf('retryBackgroundGateCleanup'), isEmpty);
    expect(tester.widget<FilledButton>(find.byType(FilledButton).first).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('phone-gate-cleanup-retry')));
    await tester.pump();
    expect(native.callsOf('retryBackgroundGateCleanup'), hasLength(1));
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('phone-gate-cleanup-retry'))).onPressed, isNull);
    completed.complete({'ok': true});
    await settlePhone(tester);
    expect(find.byKey(const ValueKey('phone-gate-cleanup')), findsNothing);
    expect(native.callsOf('setBackgroundMode'), isEmpty);
    expect(native.callsOf('prepareRoot'), isEmpty);
    // The selected same channel really has a usable explicit retest button after cleanup.
    final use = find.byType(FilledButton).first;
    expect(tester.widget<FilledButton>(use).onPressed, isNotNull);
    await tester.tap(use);
    await settlePhone(tester);
    expect(native.callsOf('setBackgroundMode').single.arguments, {'mode': 'shizuku'});
    expect(native.callsOf('retryBackgroundGateCleanup'), hasLength(1));
  });

  testWidgets('pending or unavailable cleanup never offers a retry or a new resource', (tester) async {
    final native = FakePhoneNative(status: cleanupStatus(state: 'pending', canRetry: false));
    await pumpPhone(tester, const PhoneDndPage(), native: native);
    expect(native.methods, ['status', 'getPolicies', 'actionLog']);
    native.calls.clear();
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('phone-gate-cleanup-retry'))).onPressed, isNull);
    native.push(cleanupStatus(canRetry: false));
    await settlePhone(tester);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('phone-gate-cleanup-retry'))).onPressed, isNull);
    expect(tester.widget<FilledButton>(find.byType(FilledButton).first).onPressed, isNull);
    expect(native.methods, isEmpty);
  });

  testWidgets('failed cleanup keeps the card and does not show a successful mode', (tester) async {
    final native = FakePhoneNative(status: cleanupStatus())
      ..results['retryBackgroundGateCleanup'] = {'ok': false, 'reason': 'Original release still unknown'};
    await pumpPhone(tester, const PhoneDndPage(), native: native);
    await tester.tap(find.byKey(const ValueKey('phone-gate-cleanup-retry')));
    await settlePhone(tester);
    expect(find.byKey(const ValueKey('phone-gate-cleanup')), findsOneWidget);
    expect(find.text('Original release still unknown'), findsOneWidget);
    expect(native.callsOf('setBackgroundMode'), isEmpty);
  });
}
