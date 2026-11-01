import 'dart:async';

import 'package:dsh_app/state/composer_quote.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/session_deletion_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../workspace/support.dart';
import 'read_list_refresh_test.dart' show SwitchConnection, switchConnectionProvider;

class _SwitchHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;

  void set(HostRef host) => state = host;
}

class _Backend implements SessionDeletionBackend {
  bool support = true;
  final calls = <String>[];
  final failures = <String, Object>{};
  final gates = <String, Completer<void>>{};
  void Function(String)? afterDelete;

  @override
  Future<bool> supported(DshClient client) async => support;
  @override
  Future<void> delete(DshClient client, String sessionId) async {
    calls.add(sessionId);
    if (gates[sessionId] case final gate?) await gate.future;
    if (failures[sessionId] case final error?) throw error;
    afterDelete?.call(sessionId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(ProviderContainer, FakeWorkspaceHost, _Backend)> start({bool running = false}) async {
    final host = FakeWorkspaceHost();
    host.seedSession('s1', 'First', DateTime.now(), running: running);
    host.seedSession('s2', 'Second', DateTime.now());
    final connection = workspaceHost(host);
    await connection.client.mux.start();
    final backend = _Backend();
    final container = ProviderContainer(
      overrides: [
        switchConnectionProvider.overrideWith(() => SwitchConnection(connection)),
        activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
        activeHostProvider.overrideWith(_SwitchHost.new),
        readListIdentityProvider.overrideWithValue(null),
        sessionDeletionBackendProvider.overrideWithValue(backend),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await connection.client.close();
    });
    await container.read(sessionsProvider.future);
    await container.read(drawerViewProvider.notifier).ready();
    backend.afterDelete = (id) => host.sessions.removeWhere((s) => s['sessionId'] == id);
    return (container, host, backend);
  }

  SessionDeletionOwner owner(ProviderContainer container) {
    final value = SessionDeletionOwner.capture(container)!;
    addTearDown(value.close);
    return value;
  }

  test('only acknowledged rows, selection and drafts are cleared; failed row stays', () async {
    final (container, _, backend) = await start();
    final drafts = container.read(draftStoreProvider.notifier);
    drafts.save('s1', 'private draft', const []);
    drafts.save('s2', 'keep draft', const []);
    container.read(composerQuoteProvider.notifier).set('s1', 'quote');
    container.read(currentSessionProvider.notifier).select('s1');
    await container.read(drawerViewProvider.notifier).createFolder('Folder', sessionIds: ['s1', 's2']);
    backend.failures['s2'] = const DshRemoteException('writer-held', 'private details');
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    expect(result.deleted, ['s1']);
    expect(result.failures, {'s2': 'writer-held'});
    expect(result.retired, isFalse);
    expect(container.read(sessionsProvider).value!.map((s) => s.sessionId), ['s2']);
    expect(container.read(currentSessionProvider), isNull);
    expect(container.read(draftStoreProvider).drafts.containsKey('s1'), isFalse);
    expect(container.read(draftStoreProvider).drafts['s2']?.text, 'keep draft');
    expect(container.read(composerQuoteProvider).containsKey('s1'), isFalse);
    expect(container.read(drawerViewProvider).folders.single.sessionIds, ['s2']);
    expect(container.read(sessionDeletionBusyProvider), isFalse);
  });

  test('running row and pending archive never reach destructive backend', () async {
    final (container, _, backend) = await start(running: true);
    final pending = container.read(sessionsProvider.notifier).scheduleArchive(['s2']);
    addTearDown(pending.release);
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    expect(result.failures, {'s1': 'session-active', 's2': 'archive-pending'});
    expect(backend.calls, isEmpty);
    pending.cancel();
  });

  test('unsupported Host preserves all rows and sends no deletion', () async {
    final (container, _, backend) = await start();
    backend.support = false;
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: owner(container));
    expect(result.failures, {'s1': 'unavailable'});
    expect(backend.calls, isEmpty);
    expect(container.read(sessionsProvider).value, hasLength(2));
  });

  test('host A -> B -> A irrevocably retires an old deletion authority', () async {
    final (container, _, backend) = await start();
    final captured = owner(container);
    expect(captured.current, isTrue);
    final hosts = container.read(activeHostProvider.notifier) as _SwitchHost;
    hosts.set(HostRef.ssh('pc'));
    hosts.set(HostRef.local);
    expect(captured.current, isFalse);
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: captured);
    expect(result.retired, isTrue);
    expect(backend.calls, isEmpty);
  });

  test('late response after owner departure cannot clear new selection or send next item', () async {
    final (container, _, backend) = await start();
    backend.gates['s1'] = Completer<void>();
    final operation = container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    await Future<void>.delayed(Duration.zero);
    expect(backend.calls, ['s1']);
    (container.read(activeHostProvider.notifier) as _SwitchHost).set(HostRef.ssh('pc'));
    (container.read(activeHostProvider.notifier) as _SwitchHost).set(HostRef.local);
    container.read(currentSessionProvider.notifier).select('s2');
    backend.gates['s1']!.complete();
    final result = await operation;
    expect(result.retired, isTrue);
    expect(backend.calls, ['s1']);
    expect(container.read(currentSessionProvider), 's2');
  });

  test('duplicate intent is busy and does not send twice', () async {
    final (container, _, backend) = await start();
    backend.gates['s1'] = Completer<void>();
    final captured = owner(container);
    final operation = container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: captured);
    await Future<void>.delayed(Duration.zero);
    final duplicate = await container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: captured);
    expect(duplicate.failures, {'s1': 'busy'});
    expect(backend.calls, ['s1']);
    backend.gates['s1']!.complete();
    await operation;
  });

  test('lost or invalid response stops batch without retry; remaining items not attempted', () async {
    final (container, _, backend) = await start();
    backend.failures['s1'] = const DshTransportException('reply lost');
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    expect(backend.calls, ['s1']);
    expect(result.failures, {'s1': 'connection-lost', 's2': 'not-attempted'});
    expect(container.read(sessionsProvider).value, hasLength(2));
  });

  test('late old inventory cannot resurrect a confirmed deletion', () async {
    final (container, _, backend) = await start();
    backend.afterDelete = null; // Fake stale session/list continues serving the old row.
    final result = await container.read(sessionDeletionProvider.notifier).delete(['s1'], owner: owner(container));
    expect(result.deleted, ['s1']);
    await container.read(sessionsProvider.notifier).refresh();
    expect(container.read(sessionsProvider).value!.map((s) => s.sessionId), ['s2']);
  });

  test('deleted final folder member is removed even with empty remaining inventory', () async {
    final (container, _, _) = await start();
    await container.read(drawerViewProvider.notifier).createFolder('Last', sessionIds: ['s1', 's2']);
    await container.read(sessionDeletionProvider.notifier).delete(['s1', 's2'], owner: owner(container));
    expect(container.read(sessionsProvider).value, isEmpty);
    expect(container.read(drawerViewProvider).folders.single.sessionIds, isEmpty);
  });

  test('late restore and outgoing screen saves cannot resurrect a forgotten draft', () async {
    SharedPreferences.setMockInitialValues({DraftStore.preferenceKey: '{"s1":{"t":"saved","at":1}}'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(draftStoreProvider.notifier);
    store.forget('s1');
    store.save('s1', 'outgoing screen', const []);
    await store.flush();
    expect(container.read(draftStoreProvider).drafts.containsKey('s1'), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(DraftStore.preferenceKey), '{}');
  });
}
