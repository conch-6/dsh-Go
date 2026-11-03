import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../remote/link_status.dart';
import '../remote/network_watch.dart';
import '../remote/relay/relay_backend.dart';
import '../remote/ssh/ssh_link.dart';
import '../remote/ssh/ssh_transport.dart';
import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';
import 'hosts_state.dart';
import 'permission_default_repair.dart';
import 'provider_backend.dart';
import 'provider_keys.dart';
import 'settings_state.dart';

/// A connected DSH host: the on-device engine, an SSH host or a relay device.
class HostConnection {
  const HostConnection({
    required this.client,
    this._label,
    required this.isLocal,
    this.kind = HostKind.local,
    this.hostId,
    this.name,
    this.workingDirectory,
  });

  final DshClient client;

  /// A fixed label (tests); null builds it from [kind] and [name].
  final String? _label;

  /// The host's own name (SSH / relay); null for 本机 or when not known.
  final String? name;

  /// Shown in the chat header: "本机", "电脑 · SSH", "家里的 Mac · 远程".
  /// Built on read, so it follows a language switch on a live connection.
  String get label => _label ?? hostLabel(kind, name);
  final bool isLocal;
  final HostKind kind;
  final String? hostId;

  /// Default cwd for new sessions on a remote host (absolute, `~` resolved);
  /// null lets the remote DSH pick.
  final String? workingDirectory;
}

typedef LocalClientConnector = Future<DshClient> Function({required Uri baseUri, required String token});

/// [DshClient.connect]; tests swap it to decide when a connect finishes.
final localClientConnectorProvider = Provider<LocalClientConnector>(
  (ref) =>
      ({required baseUri, required token}) =>
          DshClient.connect(baseUri: baseUri, token: token, backgroundLists: true, startMux: false),
);

/// Connects to the local `dsh web` once the native runtime reports it running.
class LocalConnectionController extends AsyncNotifier<HostConnection?> {
  @override
  Future<HostConnection?> build() async {
    // This build's ref: `ref` always points at the newest build, so only
    // `r.mounted` tells that a token change superseded this one.
    final r = ref;
    // Riverpod's own retries give up after a while; resume and network
    // changes try a failed connect again.
    final kicks = r.read(networkKicksProvider).listen((_) {
      if (r.mounted && state.hasError && !state.isLoading) r.invalidateSelf();
    });
    r.onDispose(() => unawaited(kicks.cancel()));
    final endpoint = r.watch(
      localRuntimeProvider.select((s) {
        final st = s.status;
        return st.phase == RuntimePhase.running ? (st.baseUrl, st.token) : (null, null);
      }),
    );
    final (baseUrl, token) = endpoint;
    if (baseUrl == null || token == null) return null;

    final client = await r.read(localClientConnectorProvider)(baseUri: Uri.parse(baseUrl), token: token);
    if (!r.mounted) {
      await client.close();
      return null;
    }
    r.onDispose(() => unawaited(client.close()));
    (Object, StackTrace)? readyFailure;
    final ready = client.mux.ready(timeout: const Duration(seconds: 20));
    unawaited(
      ready.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          readyFailure = (error, stack);
          // Error/retry states retain their previous value. Retire our published
          // connection before closing it, without changing an unpublished build.
          if (r.mounted && identical(state.value?.client, client)) {
            state = const AsyncData(null);
          }
          unawaited(client.close());
        },
      ),
    );

    // Keep DSH's own credential store in sync with the key saved in the app.
    r.listen(settingsProvider.select((s) => s.apiKey), (prev, next) {
      if (next == prev) return;
      if (next.isNotEmpty) {
        unawaited(_pushKey(client, next));
      } else if (prev != null && prev.isNotEmpty) {
        unawaited(client.clearProviderKey().catchError((_) {}));
      }
    });
    final apiKey = r.read(settingsProvider).apiKey;
    if (apiKey.isNotEmpty) await _pushKey(client, apiKey);
    if (!r.mounted) return null;
    if (readyFailure case final failure?) Error.throwWithStackTrace(failure.$1, failure.$2);
    final connection = HostConnection(client: client, isLocal: true);
    // HTTP is usable now; keep build pending so ready failures retain Riverpod's retry policy.
    state = AsyncData(connection);
    await ready;
    if (!r.mounted) return null;
    // Custom providers' keys kept on the phone go back in where the engine
    // lost them; never awaited (the catalog refreshes when they land).
    unawaited(
      healProviderKeys(
        ClientProviderBackend(client, isLocal: true, hostLabel: appL10n.commonThisPhone),
        r.read(providerKeyVaultProvider),
      ).catchError((_) => const <String>[]),
    );
    // An Auto default an older app saved keeps DSH's permission presets from
    // starting; it comes out once, with a restart.
    unawaited(clearAutoDefaultPreset(r.container));

    return connection;
  }

  Future<void> _pushKey(DshClient client, String key) async {
    try {
      await client.setProviderKey(key);
    } catch (_) {
      // Rejected when the launch environment already provides the key; harmless.
    }
  }
}

final localConnectionProvider = AsyncNotifierProvider<LocalConnectionController, HostConnection?>(
  LocalConnectionController.new,
);

// ── Remote links ─────────────────────────────────────────────────────────────

/// Network changes and app resumes; remote links re-check on each.
final networkKicksProvider = Provider<Stream<void>>((ref) => networkKicks());

/// Opens SSH connections (dartssh2); tests swap in a fake server.
final sshTransportFactoryProvider = Provider<SshTransportFactory>((ref) => DartSshTransport.connect);

/// Builds the link for one remote host. Overridable so tests can inject fake
/// transports.
typedef SshLinkFactory = SshHostLink Function(Ref ref, SshHostConfig config);

final sshLinkFactoryProvider = Provider<SshLinkFactory>(
  (ref) => (ref, config) {
    final hosts = ref.read(hostsProvider.notifier);
    return SshHostLink(
      config: config,
      loadSecrets: () => hosts.loadSecrets(config.id),
      pinHostKey: (key) => hosts.pinHostKey(config.id, key),
      transportFactory: ref.read(sshTransportFactoryProvider),
      // No prompt here: a host becomes active only after its key was
      // confirmed in the UI (test connection / host sheet), so an unknown key
      // at this point fails closed.
      kicks: ref.read(networkKicksProvider),
    );
  },
);

/// The live link to a remote host; null for 本机 or an unknown host. Kept while
/// something watches it (the active connection, a status row); closed after.
final hostLinkProvider = Provider.autoDispose.family<HostLink?, HostRef>((ref, host) {
  switch (host.kind) {
    case HostKind.local:
      return null;
    case HostKind.ssh:
      // Reconnect only for changes that matter to the session (not a rename
      // or a freshly pinned key).
      final key = ref.watch(hostsProvider.select((s) => s.sshById(host.id)?.connectionKey));
      if (key == null) return null;
      final config = ref.read(hostsProvider).sshById(host.id)!;
      final link = ref.read(sshLinkFactoryProvider)(ref, config);
      // Renames, cwd and re-pinned keys apply in place.
      ref.listen(hostsProvider.select((s) => s.sshById(host.id)), (_, next) {
        if (next != null && next.connectionKey == link.config.connectionKey) link.updateConfig(next);
      });
      ref.onDispose(() => unawaited(link.close()));
      return link;
    case HostKind.relay:
      final backend = ref.watch(relayBackendProvider);
      final link = RelayHostLink(
        backend: backend,
        hostId: host.id,
        // Fresh presence straight from the server (the account list on the
        // remote page refreshes on its own).
        resolveHost: () async {
          final hosts = await backend.listHosts(refresh: true);
          for (final h in hosts) {
            if (h.id == host.id) return h;
          }
          return null;
        },
        kicks: ref.read(networkKicksProvider),
      );
      final statuses = link.statuses.listen((status) {
        if (status.phase == HostLinkPhase.failed && status.error?.kind == HostLinkErrorKind.notLoggedIn) {
          unawaited(ref.read(relayAccountProvider.notifier).recheck());
        }
      });
      ref.onDispose(() {
        unawaited(statuses.cancel());
        unawaited(link.close());
      });
      return link;
  }
});

/// Status of a host's link for the UI (idle for 本机).
final hostLinkStatusProvider = StreamProvider.autoDispose.family<HostLinkStatus, HostRef>((ref, host) async* {
  final link = ref.watch(hostLinkProvider(host));
  if (link == null) {
    yield HostLinkStatus.idle;
    return;
  }
  yield link.status;
  yield* link.statuses;
});

/// Display name of a host as currently known.
final hostNameProvider = Provider.autoDispose.family<String?, HostRef>((ref, host) {
  return switch (host.kind) {
    HostKind.local => appL10n.commonThisPhone,
    HostKind.ssh => ref.watch(hostsProvider.select((s) => s.sshById(host.id)?.name)),
    HostKind.relay => ref.watch(relayAccountProvider.select((a) => a.value?.hostById(host.id)?.name)) ?? host.name,
  };
});

/// Connection to a remote host, following its link through reconnects.
class RemoteConnectionController extends AsyncNotifier<HostConnection?> {
  RemoteConnectionController(this.host);

  final HostRef host;

  @override
  Future<HostConnection?> build() async {
    final link = ref.watch(hostLinkProvider(host));
    if (link == null) return null;
    final name = ref.watch(hostNameProvider(host));

    HostConnection wrap(DshClient client) => HostConnection(
      client: client,
      name: name,
      isLocal: false,
      kind: host.kind,
      hostId: host.id,
      workingDirectory: link is SshHostLink ? link.resolvedWorkingDirectory : null,
    );

    if (link is SshHostLink) {
      ref.listen(hostsProvider.select((s) => s.sshById(host.id)), (previous, next) {
        if (next == null || next.connectionKey != link.config.connectionKey) return;
        // hostLinkProvider does this too; doing it here first keeps wrap() current.
        link.updateConfig(next);
        if (next.workingDirectory != previous?.workingDirectory) {
          if (link.currentClient case final client?) state = AsyncData(wrap(client));
        }
        // A reset and re-pinned key: connect again instead of staying failed.
        if (next.hostKeyFingerprint != previous?.hostKeyFingerprint &&
            (state.hasError || link.status.phase == HostLinkPhase.failed)) {
          ref.invalidateSelf();
        }
      });
    }
    final clients = link.clients.listen((client) => state = AsyncData(wrap(client)));
    // After a failed first open, the link may still come back on its own
    // (network kick, "重试"): pick the client up then.
    final statuses = link.statuses.listen((s) {
      if (s.isConnected && state.hasError && !state.isLoading) ref.invalidateSelf();
    });
    ref.onDispose(() {
      unawaited(clients.cancel());
      unawaited(statuses.cancel());
    });
    return wrap(await link.open());
  }

  /// Gives up any backoff and connects again now.
  void retry() {
    final link = ref.read(hostLinkProvider(host));
    if (link == null) return;
    final phase = link.status.phase;
    // A link still retrying on its own just skips its wait.
    if (phase != HostLinkPhase.reconnecting && (phase == HostLinkPhase.failed || state.hasError)) {
      ref.invalidateSelf();
    } else {
      link.retry();
    }
  }
}

final remoteConnectionProvider = AsyncNotifierProvider.autoDispose
    .family<RemoteConnectionController, HostConnection?, HostRef>(RemoteConnectionController.new);

/// Last observation of the active connection, for diagnostics only. Stores
/// enum names, booleans and a timestamp; never clients, hosts, or raw errors.
/// Reading it does not observe or rebuild any connection provider.
class ConnectionDiagnostics {
  static const _unobserved = <String, Object?>{'host': 'not_observed', 'state': 'not_observed'};
  Map<String, Object?> _value = _unobserved;

  Map<String, Object?> get snapshot => Map.unmodifiable(_value);

  void _observe(Ref ref, HostRef host, AsyncValue<HostConnection?> connection) {
    final error = connection.error;
    final value = <String, Object?>{
      'host': host.kind.name,
      'state': switch (connection) {
        AsyncData(:final value) => value == null ? 'disconnected' : 'connected',
        AsyncError() => 'failed',
        _ => 'connecting',
      },
      'observedAtEpochMs': DateTime.now().millisecondsSinceEpoch,
      if (error is HostLinkError) ...{'errorKind': error.kind.name, 'retryable': error.retryable},
    };
    _value = value;
    void clear() {
      if (identical(_value, value)) _value = _unobserved;
    }

    ref.onDispose(clear);
    if (host.isLocal) return;

    // Called only by the normal active-connection flow, never by export.
    final link = ref.read(hostLinkProvider(host));
    if (link == null) return;
    void record(HostLinkStatus status) {
      if (!identical(_value, value)) return;
      value['observedAtEpochMs'] = DateTime.now().millisecondsSinceEpoch;
      value['link'] = Map<String, Object?>.unmodifiable({
        'phase': status.phase.name,
        if (status.step != null) 'step': status.step!.name,
        'attempt': status.attempt,
        if (status.path case final path?) 'transport': path.name,
        if (status.network case final network?) ...{
          if (network.connectDuration case final duration?) 'connectDurationMs': duration.inMilliseconds,
          if (network.roundTripTime case final duration?) 'roundTripTimeMs': duration.inMilliseconds,
          'fallbackReason': ?network.safeFallbackReason,
        },
        if (status.error case final error?) ...{'errorKind': error.kind.name, 'retryable': error.retryable},
      });
    }

    record(link.status);
    final sub = link.statuses.listen(record, onDone: clear);
    ref.onDispose(() => unawaited(sub.cancel()));
  }
}

final connectionDiagnosticsProvider = Provider((ref) => ConnectionDiagnostics());

/// The host the chat UI talks to: the one picked in the host switcher.
///
/// `AsyncData(null)` while not connected, loading while connecting, the
/// [HostConnection] once ready.
final activeConnectionProvider = Provider<AsyncValue<HostConnection?>>((ref) {
  final host = ref.watch(activeHostProvider);
  final connection = _connectionForHost(ref, host);
  ref.read(connectionDiagnosticsProvider)._observe(ref, host, connection);
  return connection;
});

AsyncValue<HostConnection?> _connectionForHost(Ref ref, HostRef host) {
  switch (host.kind) {
    case HostKind.local:
      return ref.watch(localConnectionProvider);
    case HostKind.ssh:
      final known = ref.watch(hostsProvider.select((s) => !s.loaded || s.sshById(host.id) != null));
      if (!known) return ref.watch(localConnectionProvider);
      final loaded = ref.watch(hostsProvider.select((s) => s.loaded));
      if (!loaded) return const AsyncLoading();
      return ref.watch(remoteConnectionProvider(host));
    case HostKind.relay:
      return ref.watch(remoteConnectionProvider(host));
  }
}
