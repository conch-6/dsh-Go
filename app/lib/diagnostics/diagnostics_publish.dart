// Publishes the diagnostics snapshot where the on-device engine's agent can
// read it: `$DSH_HOME/dsh-app/diagnostics.md`. The app's daemon writes it (the
// Dart side does not know the rootfs), after the engine comes up, when its
// observed connection settles, and whenever the person asks from 设置 → 诊断.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';
import '../state/connection_state.dart';
import 'diagnostics_bundle.dart';
import 'diagnostics_markdown.dart';

class PublishedDiagnostics {
  const PublishedDiagnostics({required this.bytes, this.hostPath});

  final int bytes;

  /// Where Android wrote it; for logs only, the agent reads the guest path.
  final String? hostPath;
}

class DiagnosticsPublisher {
  DiagnosticsPublisher({required this.collect});

  static const channel = MethodChannel('dsh/runtime');

  final Future<DiagnosticsSnapshot> Function(DateTime at) collect;
  Completer<PublishedDiagnostics?>? _pending;
  bool Function()? _pendingOwner;
  bool _publishing = false;
  bool _disposed = false;

  /// Collects, renders and writes the snapshot. Requests made while one is in
  /// flight share one later collection, so an old report cannot finish last.
  /// Null when the owner is disposed, the runtime is absent or writing fails.
  Future<PublishedDiagnostics?> publish({bool Function()? isCurrent}) {
    if (_disposed || isCurrent?.call() == false) return Future.value(null);
    if (_pending case final pending?) {
      // An explicit request is not revoked by a coalesced automatic refresh.
      if (_pendingOwner != null) _pendingOwner = isCurrent;
      return pending.future;
    }
    final pending = _pending = Completer<PublishedDiagnostics?>();
    _pendingOwner = isCurrent;
    unawaited(_drain());
    return pending.future;
  }

  Future<void> _drain() async {
    if (_publishing) return;
    _publishing = true;
    try {
      while (_pending != null) {
        final pending = _pending!;
        final owner = _pendingOwner;
        _pending = null;
        _pendingOwner = null;
        try {
          pending.complete(_disposed ? null : await _publish(owner));
        } catch (error, stack) {
          pending.completeError(error, stack);
        }
      }
    } finally {
      _publishing = false;
    }
  }

  void dispose() => _disposed = true;

  Future<PublishedDiagnostics?> _publish(bool Function()? isCurrent) async {
    if (isCurrent?.call() == false) return null;
    final snapshot = await collect(DateTime.now());
    if (_disposed || isCurrent?.call() == false) return null;
    final markdown = diagnosticsMarkdown(snapshot);
    try {
      final reply = await channel.invokeMapMethod<Object?, Object?>('publishDiagnostics', {'markdown': markdown});
      if (reply == null) return null;
      final bytes = reply['bytes'];
      return PublishedDiagnostics(
        bytes: bytes is num ? bytes.toInt() : markdown.length,
        hostPath: reply['path'] is String ? reply['path'] as String : null,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

final diagnosticsPublisherProvider = Provider<DiagnosticsPublisher>((ref) {
  final connection = ref.watch(connectionDiagnosticsProvider);
  (Object?, Object?) key() {
    final snapshot = connection.snapshot;
    return (snapshot['host'], snapshot['state']);
  }

  (Object?, Object?)? requested;
  var engineRun = Object();
  ref.listen(localRuntimeProvider.select((runtime) => runtime.status.phase), (previous, next) {
    if (previous != next) engineRun = Object();
  });
  final publisher = DiagnosticsPublisher(
    collect: (at) {
      requested = key();
      return collectDiagnostics(ref, at);
    },
  );
  Timer? refresh;
  void refreshObserved() {
    refresh = null;
    if (!ref.mounted || requested == null || ref.read(localRuntimeProvider).status.phase != RuntimePhase.running) {
      return;
    }
    final next = key();
    if (next == requested) return;
    requested = next;
    final owner = engineRun;
    publisher
        .publish(
          isCurrent: () =>
              ref.mounted &&
              identical(owner, engineRun) &&
              ref.read(localRuntimeProvider).status.phase == RuntimePhase.running,
        )
        .ignore();
  }

  final changes = connection.changes.listen((_) {
    // A provider rebuild clears its old observation before recording the new
    // one. Let that zero-delay refresh finish before comparing stable states.
    refresh ??= Timer(Duration.zero, refreshObserved);
  });
  ref.onDispose(() {
    refresh?.cancel();
    unawaited(changes.cancel());
    publisher.dispose();
  });
  return publisher;
});
