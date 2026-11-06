import 'dart:async';

import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/diagnostics/diagnostics_publish.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/phone_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/voice_settings.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Runtime extends LocalRuntimeController {
  @override
  LocalRuntimeState build() =>
      const LocalRuntimeState(loaded: true, status: RuntimeStatus(phase: RuntimePhase.running));

  void phase(RuntimePhase phase) => state = LocalRuntimeState(loaded: true, status: RuntimeStatus(phase: phase));
}

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true);
}

class _Active extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

class _Local extends LocalConnectionController {
  _Local(this.ready);
  final Completer<HostConnection?> ready;

  @override
  Future<HostConnection?> build() => ready.future;

  void emit(AsyncValue<HostConnection?> next) => state = next;
}

class _Bridge extends RuntimeBridge {
  @override
  Stream<RuntimeEvent> get events => const Stream.empty();

  @override
  Future<List<String>> logs({int lines = 500}) async => const [];
}

class _Channel extends DiagnosticsChannel {
  @override
  Future<NativeDiagnostics> info() async => const NativeDiagnostics();

  @override
  Future<List<String>> engineLog({int maxBytes = 512 * 1024}) async => const [];
}

class _Phone extends PhoneChannel {
  @override
  Future<PhoneStatus> status() async => const PhoneStatus.notReady();
}

class _Voice extends VoiceSettingsController {
  _Voice([this.hold]);
  Completer<VoiceMode>? hold;
  int reads = 0;

  @override
  VoiceMode build() => VoiceMode.auto;

  @override
  Future<VoiceMode> ready() {
    reads++;
    return hold?.future ?? Future.value(VoiceMode.auto);
  }
}

class _Fixture {
  _Fixture({List<Override> extra = const [], _Voice? voice}) {
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        activeHostProvider.overrideWith(_Active.new),
        localConnectionProvider.overrideWith(() => _Local(ready)),
        localRuntimeProvider.overrideWith(() => runtime),
        settingsProvider.overrideWith(_Settings.new),
        voiceSettingsProvider.overrideWith(() => voice ?? _Voice()),
        runtimeBridgeProvider.overrideWithValue(_Bridge()),
        diagnosticsChannelProvider.overrideWithValue(_Channel()),
        phoneChannelProvider.overrideWithValue(_Phone()),
        ...extra,
      ],
    );
    addTearDown(close);
    addTearDown(client.close);
  }

  final ready = Completer<HostConnection?>();
  final runtime = _Runtime();
  final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:9')));
  late final ProviderContainer container;
  bool closed = false;

  HostConnection get connected => HostConnection(client: client, isLocal: true);
  DiagnosticsPublisher get publisher => container.read(diagnosticsPublisherProvider);

  void observe() => container.listen(activeConnectionProvider, (_, _) {});

  void close() {
    if (closed) return;
    closed = true;
    container.dispose();
  }
}

DiagnosticsSnapshot _snapshot(String connection) => DiagnosticsSnapshot(
  at: DateTime.utc(2026, 11, 3),
  status: const RuntimeStatus(phase: RuntimePhase.running),
  settings: const AppSettings(),
  connection: {'host': 'local', 'state': connection},
  appErrors: const [],
);

Future<void> _flush(WidgetTester tester) async {
  // Riverpod schedules dependency refreshes on zero-delay timers. Advance
  // those as well as the Future microtasks without advancing wall time.
  await tester.pump(Duration.zero);
  await tester.pump(Duration.zero);
}

void main() {
  final written = <String>[];
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    written.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      DiagnosticsPublisher.channel,
      (call) async {
        if (call.method != 'publishDiagnostics') return null;
        final markdown = (call.arguments as Map<Object?, Object?>)['markdown'] as String;
        written.add(markdown);
        return {'bytes': markdown.length};
      },
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      DiagnosticsPublisher.channel,
      null,
    );
  });

  for (final succeeds in [true, false]) {
    testWidgets('the startup connecting snapshot is refreshed when connection ${succeeds ? 'succeeds' : 'fails'}', (
      tester,
    ) async {
      final f = _Fixture()..observe();
      await f.publisher.publish();
      expect(written.single, contains('- state：connecting'));
      if (succeeds) {
        f.ready.complete(f.connected);
      } else {
        f.ready.completeError(StateError('synthetic connection failure'));
      }
      await _flush(tester);
      expect(written, hasLength(2));
      expect(written.last, contains('- state：${succeeds ? 'connected' : 'failed'}'));
    });
  }

  testWidgets('a connection that settles during the first collection still gets a later report', (tester) async {
    final hold = Completer<VoiceMode>();
    final voice = _Voice(hold);
    final f = _Fixture(voice: voice)..observe();
    final first = f.publisher.publish();
    await _flush(tester);
    expect(voice.reads, 1);
    f.ready.complete(f.connected);
    await _flush(tester);
    expect(written, isEmpty);
    hold.complete(VoiceMode.auto);
    await first;
    await _flush(tester);
    expect(written, hasLength(2));
    expect(written.last, contains('- state：connected'));
  });

  for (final restart in [false, true]) {
    testWidgets('a delayed automatic report is retired when its engine run ${restart ? 'restarts' : 'stops'}', (
      tester,
    ) async {
      final voice = _Voice();
      final f = _Fixture(voice: voice)..observe();
      await f.publisher.publish();
      final hold = voice.hold = Completer<VoiceMode>();
      f.ready.complete(f.connected);
      await _flush(tester);
      expect(voice.reads, 2, reason: 'the automatic replacement is collecting');
      f.runtime.phase(RuntimePhase.installed);
      if (restart) f.runtime.phase(RuntimePhase.running);
      final explicit = f.publisher.publish();
      hold.complete(VoiceMode.auto);
      expect(await explicit, isA<PublishedDiagnostics>());
      await _flush(tester);
      expect(written, hasLength(2), reason: 'only the initial and later explicit report may write');
      expect(written.last, contains('- state：connected'));
    });
  }

  testWidgets('a manual report coalesced with a queued refresh remains valid after engine stop', (tester) async {
    final hold = Completer<VoiceMode>();
    final voice = _Voice(hold);
    final f = _Fixture(voice: voice)..observe();
    final first = f.publisher.publish();
    await _flush(tester);
    f.ready.complete(f.connected);
    await _flush(tester);
    final explicit = f.publisher.publish();
    f.runtime.phase(RuntimePhase.installed);
    hold.complete(VoiceMode.auto);
    await first;
    expect(await explicit, isA<PublishedDiagnostics>());
    await _flush(tester);
    expect(written, hasLength(2));
    expect(written.last, contains('- state：connected'));
  });

  testWidgets('repeating the same observed state does not rewrite the snapshot', (tester) async {
    final f = _Fixture()..observe();
    f.ready.complete(f.connected);
    await _flush(tester);
    await f.publisher.publish();
    final local = f.container.read(localConnectionProvider.notifier) as _Local;
    local.emit(AsyncData(f.connected));
    await _flush(tester);
    expect(written, hasLength(1));
    expect(written.single, contains('- state：connected'));
  });

  testWidgets('publishing never initializes a connection or a Host link', (tester) async {
    var connectionReads = 0;
    var linkReads = 0;
    final f = _Fixture(
      extra: [
        activeConnectionProvider.overrideWith((ref) {
          connectionReads++;
          return const AsyncData<HostConnection?>(null);
        }),
        hostLinkProvider.overrideWith((ref, host) {
          linkReads++;
          return null;
        }),
      ],
    );
    await f.publisher.publish();
    await _flush(tester);
    expect(connectionReads, 0);
    expect(linkReads, 0);
    expect(written.single, contains('- state：not_observed'));
  });

  testWidgets('reading the publisher does not enable writes before a publish request', (tester) async {
    final f = _Fixture();
    f.publisher;
    f.observe();
    f.ready.complete(f.connected);
    await _flush(tester);
    expect(written, isEmpty);
  });

  testWidgets('a stopped engine prevents automatic refresh but still permits an explicit report', (tester) async {
    final f = _Fixture()..observe();
    await f.publisher.publish();
    f.runtime.phase(RuntimePhase.installed);
    f.ready.complete(f.connected);
    await _flush(tester);
    expect(written, hasLength(1));
    await f.publisher.publish();
    expect(written, hasLength(2));
    expect(written.last, contains('- state：connected'));
  });

  testWidgets('overlapping requests coalesce into one later collection and cannot write in reverse order', (
    tester,
  ) async {
    var collections = 0;
    final firstSnapshot = Completer<DiagnosticsSnapshot>();
    final publisher = DiagnosticsPublisher(
      collect: (_) {
        collections++;
        return collections == 1 ? firstSnapshot.future : Future.value(_snapshot('connected'));
      },
    );
    final first = publisher.publish();
    final second = publisher.publish();
    final third = publisher.publish();
    await _flush(tester);
    final beforeRelease = collections;
    firstSnapshot.complete(_snapshot('connecting'));
    await Future.wait([first, second, third]);
    expect(beforeRelease, 1);
    expect(collections, 2);
    expect(written, hasLength(2));
    expect(written.first, contains('- state：connecting'));
    expect(written.last, contains('- state：connected'));
  });

  testWidgets('a failed current collection does not discard the next requested report', (tester) async {
    var collections = 0;
    final firstSnapshot = Completer<DiagnosticsSnapshot>();
    final publisher = DiagnosticsPublisher(
      collect: (_) {
        collections++;
        return collections == 1 ? firstSnapshot.future : Future.value(_snapshot('connected'));
      },
    );
    final first = publisher.publish().then<Object?>((value) => value, onError: (Object error) => error);
    final second = publisher.publish();
    firstSnapshot.completeError(StateError('synthetic collection failure'));
    expect(await first, isA<StateError>());
    expect(await second, isA<PublishedDiagnostics>());
    expect(written.single, contains('- state：connected'));
  });

  testWidgets('disposing the publisher owner during the final collection await prevents a late write', (tester) async {
    final hold = Completer<VoiceMode>();
    final voice = _Voice(hold);
    final f = _Fixture(voice: voice);
    final result = f.publisher.publish();
    await _flush(tester);
    expect(voice.reads, 1, reason: 'the report has reached its final asynchronous source');
    f.close();
    hold.complete(VoiceMode.auto);
    expect(await result, isNull);
    expect(written, isEmpty);
  });
}
