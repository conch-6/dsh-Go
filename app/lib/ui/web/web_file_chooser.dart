import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// A document chooser belongs to the document that requested it. Navigation,
/// a renderer loss or disposal retires it even if Android returns a file later.
/// The platform returns temporary content URIs, without copying file contents
/// into Dart or granting the page access to app-private filesystem paths.
class WebFileChooser {
  WebFileChooser({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('dsh/web-files');

  final MethodChannel _channel;
  int _generation = 0;
  bool _disposed = false;
  bool _busy = false;
  String? _owner;

  Future<void> attach(WebViewController controller) async {
    final platform = controller.platform;
    if (platform is! AndroidWebViewController) return;
    await platform.setOnShowFileSelector(
      (params) => choose(params, webViewId: platform.webViewIdentifier, currentUrl: controller.currentUrl),
    );
  }

  @visibleForTesting
  Future<List<String>> choose(
    FileSelectorParams params, {
    required int webViewId,
    required Future<String?> Function() currentUrl,
  }) async {
    // A file upload never creates/overwrites a local file. Capture is a hint:
    // use the system document UI without silently acquiring camera/mic access.
    if (_disposed || _busy || params.mode == FileSelectorMode.save) return const [];
    _busy = true;
    final generation = _generation;
    final owner = '$webViewId:$generation';
    try {
      final url = await currentUrl();
      final uri = Uri.tryParse(url ?? '');
      if (_disposed || generation != _generation || uri == null || !['http', 'https'].contains(uri.scheme)) {
        return const [];
      }
      _owner = owner;
      final files = await _channel.invokeListMethod<String>('pick', {
        'owner': owner,
        'webViewId': webViewId,
        'url': url,
        'acceptTypes': params.acceptTypes,
        'multiple': params.mode == FileSelectorMode.openMultiple,
      });
      final after = await currentUrl();
      if (_disposed || generation != _generation || after != url) return const [];
      if (files == null || files.isEmpty) return const [];
      // Native also validates grants/providers. Never hand a file:// path or
      // a malformed plugin response to the WebView.
      if (files.any((raw) {
        final uri = Uri.tryParse(raw);
        return uri == null || uri.scheme != 'content' || uri.authority.isEmpty;
      })) {
        return const [];
      }
      if (params.mode == FileSelectorMode.open && files.length != 1) return const [];
      return files;
    } on Object {
      // The WebChromeClient must always receive an answer, including when a
      // renderer/platform disappears while either URL or chooser is pending.
      return const [];
    } finally {
      if (_owner == owner) _owner = null;
      _busy = false;
    }
  }

  void invalidate() {
    _generation++;
    final owner = _owner;
    _owner = null;
    if (owner != null) {
      unawaited(_channel.invokeMethod<void>('cancel', {'owner': owner}).catchError((Object _) {}));
    }
  }

  void dispose() {
    _disposed = true;
    invalidate();
  }
}
