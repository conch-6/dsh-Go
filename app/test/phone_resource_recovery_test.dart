import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_app/phone/phone_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('physical recovery is optional for an older native status', () {
    final status = PhoneBackgroundStatus.fromMap(<Object?, Object?>{'mode': 'off'});
    expect(status.resourceRecovery, isNull);
  });

  test('background status preserves pending physical recovery and its real retry flag', () {
    final status = PhoneBackgroundStatus.fromMap(<Object?, Object?>{
      'resourceRecovery': <String, Object?>{
        'v': 1, 'state': 'pending', 'count': 2, 'canRetry': true,
        'reason': 'recoveryPresent',
      },
    });
    expect(status.resourceRecovery?.state, 'pending');
    expect(status.resourceRecovery?.count, 2);
    expect(status.resourceRecovery?.canRetry, isTrue);
    expect(status.resourceRecovery?.blocked, isTrue);
  });

  test('malformed recovery fields cannot become a valid retry action', () {
    final valid = <String, Object?>{
      'v': 1, 'state': 'pending', 'count': 1, 'canRetry': true,
    };
    for (final bad in <Map<String, Object?>>[
      {...valid, 'v': 1.0},
      {...valid, 'count': 257},
      {...valid, 'count': -1},
      {...valid, 'canRetry': 1},
      {...valid, 'state': 'recovering'},
      {...valid, 'state': 'released'},
      {...valid, 'reason': <String, Object?>{}},
    ]) {
      expect(PhoneResourceRecovery.parse(bad), isNull);
    }
  });

  test('retry uses only the fixed physical recovery method and preserves refusal', () async {
    const methods = MethodChannel('test/physical-recovery');
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return <String, Object?>{'ok': false, 'reason': 'recoveryPresent'};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(methods, null));
    final result = await PhoneChannel(methods: methods).retryBackgroundRecovery();
    expect(result.ok, isFalse);
    expect(result.reason, 'recoveryPresent');
    expect(calls, hasLength(1));
    expect(calls.single.method, 'retryBackgroundRecovery');
    expect(calls.single.arguments, isNull);
  });
}
