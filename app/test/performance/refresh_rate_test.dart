import 'package:dsh_app/performance/performance_state.dart';
import 'package:dsh_app/performance/refresh_rate.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RefreshRateService.instance.resetForTest();
  });

  Future<void> waitLoaded(ProviderContainer container) async {
    final notifier = container.read(performancePrefsProvider.notifier);
    await notifier.ready;
    for (var i = 0; i < 40; i++) {
      if (container.read(performancePrefsProvider).loaded) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('preferences did not finish loading');
  }

  test('the stored choice loads and saves', () async {
    SharedPreferences.setMockInitialValues({'performance.refresh_rate': 'system'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await waitLoaded(container);
    expect(container.read(performancePrefsProvider).refreshRate, RefreshRateMode.system);
    await container.read(performancePrefsProvider.notifier).setRefreshRate(RefreshRateMode.max);
    expect(container.read(performancePrefsProvider).refreshRate, RefreshRateMode.max);
    expect((await SharedPreferences.getInstance()).getString('performance.refresh_rate'), 'max');
  });

  test('the default is auto, and old installs read as auto', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await waitLoaded(container);
    expect(container.read(performancePrefsProvider).refreshRate, RefreshRateMode.auto);
  });

  test('mode changes reach the platform once', () async {
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(RefreshRateService.channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(RefreshRateService.channel, null));

    final service = RefreshRateService.instance;
    service.start();
    await service.setMode(RefreshRateMode.max);
    await service.setMode(RefreshRateMode.max); // same value: no second call
    await Future<void>.delayed(Duration.zero);

    final modes = calls
        .where((call) => call.method == 'setRefreshRateMode')
        .map((call) => (call.arguments as Map<Object?, Object?>)['mode'])
        .toList();
    expect(modes, ['auto', 'max']);
  });
}
