import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'composer_quote.dart';
import 'connection_state.dart';
import 'draft_store.dart';
import 'drawer_view_state.dart';
import 'hosts_state.dart';
import 'read_list_cache.dart';
import 'read_list_identity.dart';
import 'sessions_state.dart';

/// Test seam; production always uses the authenticated Host bridge, never
/// direct phone filesystem access or archive as a substitute for deletion.
abstract interface class SessionDeletionBackend {
  Future<bool> supported(DshClient client);
  Future<void> delete(DshClient client, String sessionId);
}

class _HostSessionDeletion implements SessionDeletionBackend {
  const _HostSessionDeletion();
  @override
  Future<bool> supported(DshClient client) => client.supportsSessionDeletion();
  @override
  Future<void> delete(DshClient client, String sessionId) => client.deleteSessionPermanently(sessionId);
}

final sessionDeletionBackendProvider = Provider<SessionDeletionBackend>((ref) => const _HostSessionDeletion());

final sessionDeletionAvailableProvider = FutureProvider.autoDispose<bool>((ref) async {
  final connection = ref.watch(readListLiveConnectionProvider);
  if (connection == null || connection.client.mux.generation == null) return false;
  final ready = connection.client.mux.generations.listen((_) => ref.invalidateSelf());
  ref.onDispose(() => unawaited(ready.cancel()));
  return ref.watch(sessionDeletionBackendProvider).supported(connection.client);
});

/// Authority captured before an action sheet/confirmation. Listeners remember
/// *any* departure, so A -> B -> A cannot revive an old deletion confirmation.
class SessionDeletionOwner {
  SessionDeletionOwner._(this.container, this.connection, this.host, this.generation, this.readyNumber);

  static SessionDeletionOwner? capture(ProviderContainer container) {
    final connection = container.read(readListLiveConnectionProvider);
    final generation = connection?.client.mux.generation;
    if (connection == null || generation == null) return null;
    final owner = SessionDeletionOwner._(
      container,
      connection,
      container.read(activeHostProvider),
      generation,
      connection.client.mux.lastReadyGenerationNumber,
    );
    final host = container.listen(activeHostProvider, (_, next) {
      if (next != owner.host) owner._retired = true;
    });
    final live = container.listen(readListLiveConnectionProvider, (_, next) {
      if (!identical(next, connection)) owner._retired = true;
    });
    final active = container.listen(activeConnectionProvider, (_, next) {
      if (next.isLoading || next.hasError || !identical(next.value, connection)) owner._retired = true;
    });
    final mux = connection.client.mux.states.listen((_) {
      if (!identical(connection.client.mux.generation, generation)) owner._retired = true;
    });
    owner._close = () {
      host.close();
      live.close();
      active.close();
      unawaited(mux.cancel());
    };
    return owner;
  }

  final ProviderContainer container;
  final HostConnection connection;
  final HostRef host;
  final MuxGeneration generation;
  final int readyNumber;
  bool _retired = false;
  bool _closed = false;
  late final void Function() _close;

  bool get current {
    if (_retired || _closed) return false;
    try {
      final active = container.read(activeConnectionProvider);
      return !active.isLoading &&
          !active.hasError &&
          identical(active.value, connection) &&
          container.read(activeHostProvider) == host &&
          identical(container.read(readListLiveConnectionProvider), connection) &&
          identical(connection.client.mux.generation, generation) &&
          connection.client.mux.lastReadyGenerationNumber == readyNumber &&
          !_retired &&
          !_closed;
    } on StateError {
      return false;
    }
  }

  bool isCurrent(WidgetRef ref) =>
      current && identical(ProviderScope.containerOf(ref.context, listen: false), container);

  void close() {
    if (_closed) return;
    _closed = true;
    _close();
  }
}

SessionDeletionOwner? captureSessionDeletionOwner(WidgetRef ref) =>
    SessionDeletionOwner.capture(ProviderScope.containerOf(ref.context, listen: false));

class SessionDeletionResult {
  const SessionDeletionResult({this.deleted = const [], this.failures = const {}, this.retired = false});
  final List<String> deleted;

  /// Session id -> stable, localizable reason; never raw Host messages/paths.
  final Map<String, String> failures;
  final bool retired;
}

class SessionDeletionController extends Notifier<bool> {
  @override
  bool build() => false;

  Future<SessionDeletionResult> delete(List<String> sessionIds, {required SessionDeletionOwner owner}) async {
    final ids = sessionIds.toSet().toList();
    bool owned() => ref.mounted && identical(ref.container, owner.container) && owner.current;
    if (!owned()) return const SessionDeletionResult(retired: true);
    if (state) return SessionDeletionResult(failures: {for (final id in ids) id: 'busy'});
    if (ids.isEmpty) return const SessionDeletionResult();
    final deleted = <String>[];
    final failures = <String, String>{};
    final backend = ref.read(sessionDeletionBackendProvider);
    final client = owner.connection.client;
    final identity = ref.read(readListIdentityProvider);
    state = true;
    try {
      if (!owned()) return const SessionDeletionResult(retired: true);
      // Recheck after confirmation; support is not inferred from an old read.
      final bool supported;
      try {
        supported = await backend.supported(client);
      } catch (error) {
        return SessionDeletionResult(failures: {for (final id in ids) id: _failureCode(error)}, retired: !owned());
      }
      if (!owned()) return const SessionDeletionResult(retired: true);
      if (!supported) return SessionDeletionResult(failures: {for (final id in ids) id: 'unavailable'});
      for (final id in ids) {
        if (!owned()) break;
        final sessions = ref.read(sessionsProvider.notifier);
        final rejection = sessions.beginDeletion(id);
        if (rejection != null) {
          failures[id] = rejection;
          continue;
        }
        try {
          if (!owned()) break;
          await backend.delete(client, id);
          // A late response belongs to its old Host, never to a new screen.
          if (!owned()) break;
          deleted.add(id);
          ref.read(readListCacheProvider).invalidateKind(ReadListKind.sessions, identity);
          ref.read(draftStoreProvider.notifier).forget(id);
          if (!owned()) break;
          ref.read(composerQuoteProvider.notifier).clear(id);
          if (!owned()) break;
          sessions.confirmDeleted(id);
          if (!owned()) break;
          if (ref.read(currentSessionProvider) == id) ref.read(currentSessionProvider.notifier).select(null);
          if (!owned()) break;
          await ref.read(drawerViewProvider.notifier).forgetSessions({id}, isCurrent: owned);
        } catch (error) {
          if (!owned()) break;
          // A cleanup failure must not relabel an acknowledged deletion as a
          // failed destructive request. UI refresh can recover local metadata.
          if (!deleted.contains(id)) {
            final code = _failureCode(error);
            failures[id] = code;
            if (code == 'connection-lost' || code == 'protocol-error') {
              // The server may have committed before its reply was lost. Stop
              // the batch; further deletes require another explicit intent.
              for (final remaining in ids.skip(ids.indexOf(id) + 1)) {
                failures[remaining] = 'not-attempted';
              }
              break;
            }
          }
        } finally {
          if (owned()) sessions.endDeletion(id);
        }
      }
      return SessionDeletionResult(
        deleted: List.unmodifiable(deleted),
        failures: Map.unmodifiable(failures),
        retired: !owned(),
      );
    } finally {
      if (ref.mounted) state = false;
    }
  }
}

String _failureCode(Object error) => switch (error) {
  DshRemoteException(:final code) =>
    const {'session-active', 'session-related', 'writer-held', 'not-found', 'unavailable', 'busy'}.contains(code)
        ? code
        : 'failed',
  DshProtocolException() => 'protocol-error',
  DshHttpException() ||
  DshTransportException() ||
  DshCarrierLostException() ||
  DshClosedException() => 'connection-lost',
  _ => 'failed',
};

final sessionDeletionProvider = NotifierProvider<SessionDeletionController, bool>(SessionDeletionController.new);
final sessionDeletionBusyProvider = Provider<bool>((ref) => ref.watch(sessionDeletionProvider));
