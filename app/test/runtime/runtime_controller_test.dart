import 'dart:async';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge extends RuntimeBridge {
  final stream = StreamController<RuntimeEvent>.broadcast(sync: true);
  final initialStatus = Completer<RuntimeStatus>();
  final initialLogs = Completer<RuntimeLogSnapshot>();

  @override
  Stream<RuntimeEvent> get events => stream.stream;
  @override
  Future<RuntimeStatus> status() => initialStatus.future;
  @override
  Future<RuntimeLogSnapshot> logSnapshot({int lines = 300}) => initialLogs.future;
}

void main() {
  late _Bridge bridge;
  late ProviderContainer container;
  setUp(() {
    bridge = _Bridge();
    container = ProviderContainer(overrides: [runtimeBridgeProvider.overrideWithValue(bridge)]);
    container.read(localRuntimeProvider);
  });
  tearDown(() async {
    container.dispose();
    await bridge.stream.close();
  });

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('late logs cannot overwrite a newer running event', () async {
    bridge.initialStatus.complete(const RuntimeStatus(phase: RuntimePhase.starting));
    await flush();
    expect(container.read(localRuntimeProvider).loaded, isTrue);
    bridge.stream.add(const RuntimeStatusEvent(RuntimeStatus(phase: RuntimePhase.running)));
    bridge.initialLogs.complete(const RuntimeLogSnapshot([RuntimeLogEntry(1, 'old log', 'stdout')], 1));
    await flush();
    expect(container.read(localRuntimeProvider).status.phase, RuntimePhase.running);
    expect(container.read(localRuntimeLogsProvider), ['old log']);
  });

  test('keeps the most recent 1000 log lines', () async {
    bridge.initialStatus.complete(const RuntimeStatus(phase: RuntimePhase.installed));
    bridge.initialLogs.complete(const RuntimeLogSnapshot([], 0));
    await flush();
    for (var i = 0; i < 1005; i++) {
      bridge.stream.add(RuntimeLogsEvent([RuntimeLogEntry(i + 1, 'line $i', 'stdout')]));
    }
    final logs = container.read(localRuntimeLogsProvider);
    expect(logs.length, 1000);
    expect(logs.first, 'line 5');
    expect(logs.last, 'line 1004');
  });

  test('leaving installation clears progress and notices advance sequence', () {
    bridge.stream.add(const RuntimeStatusEvent(RuntimeStatus(phase: RuntimePhase.installing)));
    bridge.stream.add(const RuntimeProgressEvent(step: 'extract', done: 1, total: 2));
    expect(container.read(localRuntimeProvider).progress?.done, 1);
    bridge.stream.add(const RuntimeStatusEvent(RuntimeStatus(phase: RuntimePhase.running)));
    expect(container.read(localRuntimeProvider).progress, isNull);
    bridge.stream.add(const RuntimeNoticeEvent('已启动'));
    expect(container.read(localRuntimeProvider).notice?.seq, 1);
    bridge.stream.add(const RuntimeNoticeEvent('已启动'));
    expect(container.read(localRuntimeProvider).notice?.seq, 2);
  });

  test('a status failure still ends initial loading', () async {
    bridge.initialStatus.completeError(StateError('offline'));
    await flush();
    expect(container.read(localRuntimeProvider).loaded, isTrue);
  });
}
