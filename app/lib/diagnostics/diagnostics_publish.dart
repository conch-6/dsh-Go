// Publishes the diagnostics snapshot where the on-device engine's agent can
// read it: `$DSH_HOME/dsh-app/diagnostics.md`. The app's daemon writes it (the
// Dart side does not know the rootfs), after the engine comes up and whenever
// the person asks from 设置 → 诊断.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  /// Collects, renders and writes the snapshot. Null when the runtime is not
  /// installed or the native write failed.
  Future<PublishedDiagnostics?> publish() async {
    final snapshot = await collect(DateTime.now());
    final markdown = diagnosticsMarkdown(snapshot);
    try {
      final reply = await channel.invokeMapMethod<Object?, Object?>('publishDiagnostics', {
        'markdown': markdown,
      });
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

final diagnosticsPublisherProvider = Provider<DiagnosticsPublisher>(
  (ref) => DiagnosticsPublisher(collect: (at) => collectDiagnostics(ref, at)),
);
