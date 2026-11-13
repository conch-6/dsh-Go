// One island (tavern_islands.dart): a message's HTML in a sandboxed web view,
// see-through and as tall as its content, under 酒馆设置 › 安全's choices.
// Links open outside; the page itself never navigates away. Tests swap the
// builder (no platform web view there).

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../tavern/tavern_islands.dart';
import '../../tavern/tavern_settings.dart';
import '../web/web_view_guard.dart';

/// Builds the island for a part's HTML. Tests swap it.
final tavernIslandBuilderProvider = Provider<Widget Function(String html)>(
  (ref) =>
      (html) => TavernHtmlIsland(key: ValueKey(html), html: html),
);

class TavernHtmlIsland extends ConsumerStatefulWidget {
  const TavernHtmlIsland({super.key, required this.html});

  final String html;

  /// Heights it may take (logical px): a sliver before it reports, and no
  /// taller than a long page.
  static const minHeight = 24.0;
  static const maxHeight = 4000.0;

  @override
  ConsumerState<TavernHtmlIsland> createState() => _TavernHtmlIslandState();
}

class _TavernHtmlIslandState extends ConsumerState<TavernHtmlIsland> {
  WebViewController? _controller;
  late final WebViewGuard _guard = WebViewGuard(onGone: _onGone);
  double _height = 48;
  bool _gone = false;
  (String, bool, bool, Brightness)? _loaded;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _open();
  }

  @override
  void didUpdateWidget(TavernHtmlIsland old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) _open();
  }

  /// Loads the page, again when what it shows or how it is guarded changes.
  void _open() {
    final theme = Theme.of(context);
    final (noScripts, offline) = ref.read(tavernSettingsProvider.select((s) => (s.islandNoScripts, s.islandOffline)));
    final key = (widget.html, noScripts, offline, theme.brightness);
    if (key == _loaded) return;
    _loaded = key;
    final document = tavernIslandDocument(
      widget.html,
      text: theme.colorScheme.onSurface,
      accent: theme.colorScheme.primary,
      fontSize: theme.textTheme.bodyLarge?.fontSize ?? 15,
      nonce: _nonce(),
      noScripts: noScripts,
      offline: offline,
    );
    final controller = _controller ??= WebViewController();
    final textZoom = MediaQuery.textScalerOf(context).scale(100).round().clamp(50, 300);
    final dark = theme.brightness == Brightness.dark;
    unawaited(() async {
      await Future.wait(
        [
          controller.setJavaScriptMode(JavaScriptMode.unrestricted),
          controller.setBackgroundColor(Colors.transparent),
          controller.addJavaScriptChannel('TavernIsland', onMessageReceived: (m) => _onHeight(m.message)),
          controller.setNavigationDelegate(NavigationDelegate(onNavigationRequest: _onNavigation)),
        ].map((f) => f.catchError((_) {})),
      );
      if (!mounted || controller != _controller) return;
      await _guard.attach(controller, dark: dark, textZoom: textZoom).catchError((_) {});
      if (!mounted || controller != _controller) return;
      await controller.loadHtmlString(document).catchError((_) {});
    }());
  }

  static final _random = Random.secure();
  static String _nonce() => List.generate(16, (_) => _random.nextInt(36).toRadixString(36)).join();

  void _onHeight(String message) {
    final h = double.tryParse(message);
    if (h == null || !mounted) return;
    final height = h.clamp(TavernHtmlIsland.minHeight, TavernHtmlIsland.maxHeight).toDouble();
    if ((height - _height).abs() >= 1) setState(() => _height = height);
  }

  /// The page itself stays put; a link opens outside the app.
  NavigationDecision _onNavigation(NavigationRequest request) {
    final url = request.url;
    if (url == 'about:blank' || url.startsWith('data:') || url.startsWith('about:srcdoc')) {
      return NavigationDecision.navigate;
    }
    if (!request.isMainFrame) return NavigationDecision.navigate;
    final uri = Uri.tryParse(url);
    if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
      unawaited(launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false));
    }
    return NavigationDecision.prevent;
  }

  void _onGone(bool crashed) {
    if (_gone || !mounted) return;
    setState(() => _gone = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_guard.destroy()));
  }

  @override
  void dispose() {
    _guard.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Its guards changed: load again.
    ref.listen(tavernSettingsProvider.select((s) => (s.islandNoScripts, s.islandOffline)), (_, _) => _open());
    final controller = _controller;
    if (_gone || controller == null) return const SizedBox(height: TavernHtmlIsland.minHeight);
    return AnimatedSize(
      duration: const Duration(milliseconds: 160),
      alignment: Alignment.topCenter,
      child: SizedBox(
        height: _height,
        child: WebViewWidget(controller: controller),
      ),
    );
  }
}
