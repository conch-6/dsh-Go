import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/phone_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// Records cancels; two sessions, one of them running.
class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final cancelled = <String>[];

  @override
  Future<List<SessionSummary>> listSessions() async => [
    SessionSummary(sessionId: 'busy', updatedAt: DateTime(2026), running: true, blank: false, agentAvailable: true),
    SessionSummary(sessionId: 'idle', updatedAt: DateTime(2026), running: false, blank: false, agentAvailable: true),
  ];

  @override
  Future<void> cancel(String sessionId) async => cancelled.add(sessionId);
}

class _Local extends LocalConnectionController {
  _Local(this.client);
  final DshClient client;

  @override
  Future<HostConnection?> build() async => HostConnection(client: client, label: '本机', isLocal: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('停止 on the overlay cancels the turn running on the local engine', () async {
    final native = FakePhoneNative(status: phoneStatus(taskActive: true))..install();
    final client = _Client();
    final container = ProviderContainer(overrides: [localConnectionProvider.overrideWith(() => _Local(client))]);
    addTearDown(container.dispose);
    await container.read(localConnectionProvider.future);

    container.listen(phoneStopWatcherProvider, (_, _) {});
    await pumpEventQueue();
    expect(native.listening, isTrue);

    native.push(phoneStatus(taskActive: false, taskStopped: true));
    await pumpEventQueue();
    expect(client.cancelled, ['busy']);

    // Still stopped on the next event: nothing more to cancel.
    native.push(phoneStatus(taskActive: false, taskStopped: true));
    await pumpEventQueue();
    expect(client.cancelled, ['busy']);
  });

  for (final initiallyModern in [false, true]) {
    test('launch capability survives retired task lists and late status (initial=$initiallyModern)', () async {
      Map<String, Object?> status(int launch, bool modern, bool stopped) => {
        ...phoneStatus(taskStopped: stopped), 'taskProtocol': 1, 'tasks': [],
        'callerCapability': {'launch': launch, 'modernSeen': modern},
      };
      final native = FakePhoneNative(status: status(1, initiallyModern, false))..install();
      final client = _Client();
      final container = ProviderContainer(overrides: [localConnectionProvider.overrideWith(() => _Local(client))]);
      addTearDown(container.dispose);
      await container.read(localConnectionProvider.future);
      container.listen(phoneStopWatcherProvider, (_, _) {});
      await pumpEventQueue();
      if (!initiallyModern) {
        native.push(status(1, true, false));
        await pumpEventQueue();
      }
      native.push(status(1, false, true));
      await pumpEventQueue();
      expect(client.cancelled, isEmpty);
      native.push(status(2, false, true)); // New launch establishes a baseline only.
      await pumpEventQueue();
      expect(client.cancelled, isEmpty);
      native.push(status(1, false, false)); // An old launch cannot reset stopped.
      await pumpEventQueue();
      native.push(status(2, false, true));
      await pumpEventQueue();
      expect(client.cancelled, isEmpty);
      native.push(status(2, false, false));
      await pumpEventQueue();
      native.push(status(2, false, true));
      await pumpEventQueue();
      expect(client.cancelled, ['busy']);
    });
  }

  for (final capability in [null, {'launch': 1.0, 'modernSeen': false}, {'launch': 1, 'modernSeen': 0}]) {
    test('modern protocol with unknown capability never cancels all: $capability', () async {
      Map<String, Object?> status(bool stopped) => {
        ...phoneStatus(taskStopped: stopped), 'taskProtocol': 1, 'tasks': [],
        'callerCapability': ?capability,
      };
      final native = FakePhoneNative(status: status(false))..install();
      final client = _Client();
      final container = ProviderContainer(overrides: [localConnectionProvider.overrideWith(() => _Local(client))]);
      addTearDown(container.dispose);
      await container.read(localConnectionProvider.future);
      container.listen(phoneStopWatcherProvider, (_, _) {});
      await pumpEventQueue();
      native.push(status(true));
      await pumpEventQueue();
      expect(client.cancelled, isEmpty);
    });
  }

  test('modern tasks prohibit fallback even when the capability snapshot says false', () async {
    Map<String, Object?> status(bool stopped, bool hasModern) => {
      ...phoneStatus(taskStopped: stopped), 'taskProtocol': 1,
      'callerCapability': {'launch': 1, 'modernSeen': false},
      'tasks': [if (hasModern) {'id': 9, 'sessionId': 'modern', 'active': true}],
    };
    final native = FakePhoneNative(status: status(false, true))..install();
    final client = _Client();
    final container = ProviderContainer(overrides: [localConnectionProvider.overrideWith(() => _Local(client))]);
    addTearDown(container.dispose);
    await container.read(localConnectionProvider.future);
    container.listen(phoneStopWatcherProvider, (_, _) {});
    await pumpEventQueue();
    native.push(status(true, false));
    await pumpEventQueue();
    expect(client.cancelled, isEmpty);
  });

  test('revision rejects old stop edges and resets before legacy cancellation', () async {
    Map<String, Object?> status(int revision, bool stopped) => {
      ...phoneStatus(taskStopped: stopped), 'statusRevision': revision,
      'taskProtocol': 1, 'tasks': [],
      'callerCapability': {'launch': 1, 'modernSeen': false},
    };
    final native = FakePhoneNative(status: status(3, false))..install();
    final client = _Client();
    final container = ProviderContainer(overrides: [localConnectionProvider.overrideWith(() => _Local(client))]);
    addTearDown(container.dispose);
    await container.read(localConnectionProvider.future);
    container.listen(phoneStopWatcherProvider, (_, _) {});
    await pumpEventQueue();
    expect(native.listening, isTrue);
    native.push(status(2, true));
    await pumpEventQueue();
    expect(client.cancelled, isEmpty);
    for (final value in <Object?>[null, '4', 4.0, -1]) {
      native.push({...status(4, true), 'statusRevision': value});
      await pumpEventQueue();
    }
    final missing = status(4, true)..remove('statusRevision');
    native.push(missing);
    await pumpEventQueue();
    expect(client.cancelled, isEmpty);
    native.push(status(5, true));
    await pumpEventQueue();
    expect(client.cancelled, ['busy']);
    native.push(status(4, false));
    await pumpEventQueue();
    native.push(status(5, true));
    await pumpEventQueue();
    expect(client.cancelled, ['busy']);
    native.push(status(6, false));
    await pumpEventQueue();
    native.push(status(7, true));
    await pumpEventQueue();
    expect(client.cancelled, ['busy', 'busy']);
  });

  test('invalid initial status revision cannot establish a stop watcher baseline', () async {
    final native = FakePhoneNative(status: {...phoneStatus(), 'statusRevision': '1'})..install();
    final client = _Client();
    final container = ProviderContainer(overrides: [localConnectionProvider.overrideWith(() => _Local(client))]);
    addTearDown(container.dispose);
    await container.read(localConnectionProvider.future);
    container.listen(phoneStopWatcherProvider, (_, _) {});
    await pumpEventQueue();
    expect(native.listening, isFalse);
    native.push({...phoneStatus(taskStopped: true), 'statusRevision': 2});
    await pumpEventQueue();
    expect(client.cancelled, isEmpty);
  });

  test('without the native side nothing is watched', () async {
    final client = _Client();
    final container = ProviderContainer(overrides: [localConnectionProvider.overrideWith(() => _Local(client))]);
    addTearDown(container.dispose);
    container.listen(phoneStopWatcherProvider, (_, _) {});
    await pumpEventQueue();
    expect(client.cancelled, isEmpty);
  });
}
