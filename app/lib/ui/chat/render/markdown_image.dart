// Images in replies. `![…](chart.png)` usually names a file the agent just
// made in the session's workspace, so it is read the way the artifact card
// reads files (local engine: in place; remote Host: downloaded once into the
// cache); web and `data:` images load directly.

import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/custom_widgets/svg_image.dart' show NetworkSvg, isSvgUrl, memorySvg;

import '../../../l10n/l10n.dart';
import '../../../state/artifact_files.dart';
import '../../../state/artifacts.dart';
import '../../../state/chat_state.dart';
import '../../../state/sessions_state.dart';
import '../../../media/gallery.dart' show imageProviderBytes;
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../artifact_preview.dart';
import '../media/media_paths.dart';
import '../widgets/image_actions.dart';

/// Largest workspace image a reply downloads from a remote Host just to show
/// it inline (the Host's own image limit is 20 MiB).
const maxMarkdownImageBytes = 20 * 1024 * 1024;

/// Tallest an image is drawn in the reply; taller ones keep their aspect
/// ratio and get narrower. A tap opens the full image.
const maxMarkdownImageHeight = 480.0;

/// [source] decoded no larger than it is drawn inline (the reading width and
/// [maxMarkdownImageHeight], or a smaller size hint), in physical pixels; small images are not scaled up.
/// The full-screen viewer gets the original.
ImageProvider inlineImageProvider(ImageProvider source, double dpr, Size? hint) => ResizeImage(
  source,
  width: (math.min(hint?.width ?? AppSpace.readingWidth, AppSpace.readingWidth) * dpr).round(),
  height: (math.min(hint?.height ?? maxMarkdownImageHeight, maxMarkdownImageHeight) * dpr).round(),
  policy: ResizeImagePolicy.fit,
);

// -----------------------------------------------------------------------------
// Where an image comes from

/// Where the bytes of a Markdown image come from.
sealed class ImageSource {
  const ImageSource();
}

/// `http(s)://…`.
class WebImageSource extends ImageSource {
  const WebImageSource(this.url);
  final String url;
}

/// `data:image/png;base64,…`.
class DataImageSource extends ImageSource {
  const DataImageSource(this.url);
  final String url;
}

/// A file the session can see: absolute (`/root/workspace/x.png`), or
/// relative to the session's working directory (`test-image.jpg`).
class WorkspaceImageSource extends ImageSource {
  const WorkspaceImageSource(this.path);

  /// The local URI path, percent-escapes decoded once.
  final String path;
}

/// A scheme that is not an image address (`javascript:`, `intent:`…).
class UnsupportedImageSource extends ImageSource {
  const UnsupportedImageSource();
}

final _drive = RegExp(r'^[A-Za-z]:[\\/]');

/// Classifies a Markdown image destination.
ImageSource imageSourceOf(String url) {
  var target = url.trim();
  if (target.startsWith('<') && target.endsWith('>')) {
    target = target.substring(1, target.length - 1).trim();
  }
  final lower = target.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return WebImageSource(target);
  }
  if (lower.startsWith('data:')) return DataImageSource(target);
  if (!_drive.hasMatch(target)) {
    final path = resolveWorkspaceLink(target);
    return path == null ? const UnsupportedImageSource() : WorkspaceImageSource(path);
  }
  // Keep remote Windows paths as paths rather than parsing their drive as a URI scheme.
  final hash = target.indexOf('#');
  if (hash > 0) target = target.substring(0, hash);
  try {
    target = Uri.decodeFull(target);
  } on ArgumentError {
    // Keep it as written.
  } on FormatException {
    return const UnsupportedImageSource();
  }
  if (target.isEmpty) return const UnsupportedImageSource();
  return WorkspaceImageSource(target);
}

/// [path] (a workspace image as written) as the path to read.
///
/// Relative paths join [baseDir] (the folder of a previewed Markdown file),
/// else the session's working directory [cwd], else — on the local engine,
/// whose sessions all start there — [localWorkspaceDir]. On a remote Host
/// without a known working directory the path stays relative: the Host
/// resolves it against the session's own.
String workspaceImagePath(String path, {String? baseDir, String? cwd, bool local = false}) {
  final base = baseDir ?? cwd ?? (local ? localWorkspaceDir : null);
  return resolveSessionPath(path, cwd: base);
}

/// The file name to show for [url] (`test-image.jpg`), never a whole
/// `data:` payload.
String imageDisplayName(String url) {
  final source = imageSourceOf(url);
  final path = switch (source) {
    WorkspaceImageSource(:final path) => path,
    WebImageSource(:final url) => Uri.tryParse(url)?.path ?? url,
    DataImageSource() => '',
    UnsupportedImageSource() => url,
  };
  final name = baseName(path.trim());
  return name.isEmpty ? appL10n.chatImage : name;
}

// -----------------------------------------------------------------------------
// Session context

/// Which session's files a reply's images come from, for Markdown shown
/// outside the chat list (a previewed `.md` file; tests). Without one, the
/// conversation open in the chat ([currentSessionProvider]) is used.
class MarkdownImageScope extends InheritedWidget {
  const MarkdownImageScope({super.key, required this.sessionId, this.baseDir, required super.child});

  final String sessionId;

  /// Where relative paths start; null: the session's working directory.
  final String? baseDir;

  static MarkdownImageScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MarkdownImageScope>();

  @override
  bool updateShouldNotify(MarkdownImageScope oldWidget) =>
      sessionId != oldWidget.sessionId || baseDir != oldWidget.baseDir;
}

// -----------------------------------------------------------------------------
// Reading workspace images

/// A decoded-ready workspace image.
sealed class LoadedImage {
  const LoadedImage();
}

class RasterImage extends LoadedImage {
  const RasterImage(this.provider);
  final ImageProvider provider;
}

class SvgImageBytes extends LoadedImage {
  const SvgImageBytes(this.bytes);
  final Uint8List bytes;
}

/// Reads one image file of a session.
abstract interface class WorkspaceImageReader {
  Future<LoadedImage> read(String sessionId, String path);
}

/// Too big to fetch just to draw it inline.
class ImageTooLarge implements Exception {
  const ImageTooLarge();
}

/// Reads through [ArtifactFiles]: the local engine's file in place, a remote
/// Host's file downloaded once into the artifact cache (refetched only when
/// the Host reports a new version).
class ArtifactImageReader implements WorkspaceImageReader {
  const ArtifactImageReader(this.files);

  final ArtifactFiles files;

  @override
  Future<LoadedImage> read(String sessionId, String path) async {
    final connection = files.connection;
    if (connection == null) throw const ArtifactError('offline');
    if (!files.canFetch) throw const ArtifactError('unsupported');
    if (!connection.isLocal) {
      final stat = await connection.client.statFile(sessionId, path);
      if ((stat.bytes ?? 0) > maxMarkdownImageBytes) throw const ImageTooLarge();
    }
    final file = await files.materialize(sessionId, Artifact(path: path, origin: ArtifactOrigin.linked, turn: 0));
    if (isSvgUrl(path)) return SvgImageBytes(await file.readAsBytes());
    return RasterImage(FileImage(file));
  }
}

/// Remembers each image per (session, path) while the connection lasts, so
/// scrolling a reply back into view draws it at once instead of reading the
/// file again. A failed read is forgotten, so the next attempt reads afresh.
class CachedImageReader implements WorkspaceImageReader {
  CachedImageReader(this.inner, {this.capacity = 64, this.keeps});

  final WorkspaceImageReader inner;
  final int capacity;

  /// Whether a read image is worth holding; null holds all of them.
  final bool Function(LoadedImage image)? keeps;
  final _pending = <(String, String), Future<LoadedImage>>{};
  final _done = <(String, String), LoadedImage>{};

  /// The image when it has already been read; null while it is not.
  LoadedImage? peek(String sessionId, String path) {
    final key = (sessionId, path);
    final hit = _done.remove(key);
    if (hit != null) _done[key] = hit;
    return hit;
  }

  @override
  Future<LoadedImage> read(String sessionId, String path) {
    final key = (sessionId, path);
    final done = peek(sessionId, path);
    if (done != null) return SynchronousFuture(done);
    return _pending[key] ??= inner
        .read(sessionId, path)
        .then(
          (image) {
            _pending.remove(key);
            if (keeps?.call(image) == false) return image;
            _done[key] = image;
            while (_done.length > capacity) {
              _done.remove(_done.keys.first);
            }
            return image;
          },
          onError: (Object error, StackTrace stack) {
            _pending.remove(key);
            Error.throwWithStackTrace(error, stack);
          },
        );
  }

  /// Forgets [path] so it is read again (a retry after a failure).
  void forget(String sessionId, String path) {
    _pending.remove((sessionId, path));
    _done.remove((sessionId, path));
  }
}

/// Reads images the connected engine serves itself, such as a plugin's
/// `/api/…` assets: they need the session's cookie, which NetworkImage can't
/// send. [path] is the image's full URL or root-relative API path.
class EngineImageReader implements WorkspaceImageReader {
  const EngineImageReader(this.client);

  final DshClient? client;

  @override
  Future<LoadedImage> read(String sessionId, String path) async {
    final client = this.client;
    if (client == null) throw const ArtifactError('offline');
    final bytes = await client.readEngineUrl(path, maxBytes: maxMarkdownImageBytes);
    return isSvgUrl(path) ? SvgImageBytes(bytes) : RasterImage(MemoryImage(bytes));
  }
}

/// Largest engine image held in memory between reads. These hold their bytes,
/// unlike workspace images (a file handle): small assets such as emoji repeat
/// in a chat, and anything bigger is read again when it scrolls back.
const maxHeldEngineImageBytes = 256 * 1024;

/// Images from the engine's own address; one cache per connection, at most
/// 8 MiB of bytes.
final engineImageReaderProvider = Provider<CachedImageReader>(
  (ref) => CachedImageReader(
    EngineImageReader(ref.watch(artifactFilesProvider).connection?.client),
    capacity: 32,
    keeps: (image) => switch (image) {
      RasterImage(provider: MemoryImage(:final bytes)) || SvgImageBytes(:final bytes) =>
        bytes.length <= maxHeldEngineImageBytes,
      _ => true,
    },
  ),
);

/// The reader reply images use; one cache per connection.
final workspaceImageReaderProvider = Provider<CachedImageReader>(
  (ref) => CachedImageReader(ArtifactImageReader(ref.watch(artifactFilesProvider))),
);

/// A short sentence for a failed image (shown under its file name).
String imageErrorText(Object error) {
  final code = switch (error) {
    ImageTooLarge() => 'too-large',
    ArtifactError(:final code) => code,
    PlatformException(:final code) => code,
    DshRemoteException(:final code) => code,
    DshTransportException() || DshCarrierLostException() => 'offline',
    _ => '',
  };
  return switch (code) {
    'missing' || 'workspace-file/not-found' => appL10n.chatImageNotFound,
    'offline' => appL10n.chatImageOffline,
    'too-large' || 'workspace-file/too-large' => appL10n.chatImageTooLarge,
    'unsupported' || 'workspace-file/unsupported' || 'workspace-file/not-allowed' => appL10n.chatImageReadFailed,
    _ => appL10n.chatImageDisplayFailed,
  };
}

// -----------------------------------------------------------------------------
// The image in a reply

/// Natural sizes of images already drawn, so the placeholder of an image
/// coming back into view has the right shape and nothing below it moves.
final _knownSizes = <String, Size>{};

void _rememberSize(String key, Size size) {
  _knownSizes.remove(key);
  _knownSizes[key] = size;
  while (_knownSizes.length > 256) {
    _knownSizes.remove(_knownSizes.keys.first);
  }
}

/// `data:` images decoded once per address.
final _dataImages = <String, Uint8List?>{};

Uint8List? _dataBytes(String url) {
  final hit = _dataImages.remove(url);
  if (hit != null || _dataImages.containsKey(url)) {
    _dataImages[url] = hit;
    return hit;
  }
  Uint8List? bytes;
  try {
    bytes = UriData.parse(url).contentAsBytes();
  } on FormatException {
    bytes = null;
  }
  _dataImages[url] = bytes;
  while (_dataImages.length > 32) {
    _dataImages.remove(_dataImages.keys.first);
  }
  return bytes;
}

/// The gpt_markdown image builder: [MarkdownImage] for every `![…](…)` and
/// `<img>`. [width] / [height] come from a `WxH` alt text.
Widget markdownImageBuilder(BuildContext context, String url, double? width, double? height) =>
    MarkdownImage(url: url, width: width, height: height);

/// One image in a reply: no wider than the column, its own aspect ratio,
/// rounded like the code wells beside it. While it loads, a calm box of the
/// right (or a 4:3) shape; when it cannot be shown, its file name and why.
/// A tap opens it full screen.
class MarkdownImage extends ConsumerStatefulWidget {
  const MarkdownImage({super.key, required this.url, this.width, this.height});

  final String url;
  final double? width;
  final double? height;

  @override
  ConsumerState<MarkdownImage> createState() => _MarkdownImageState();
}

class _MarkdownImageState extends ConsumerState<MarkdownImage> {
  late ImageSource _source = imageSourceOf(widget.url);

  /// Workspace images: the session and the path read.
  String? _sessionId;
  String? _path;

  /// An image the connected engine serves itself: read with its cookie.
  String? _engineUrl;
  Future<LoadedImage>? _future;
  LoadedImage? _loaded;
  Object? _error;

  /// Bumped by a retry, so a failed web image is fetched again.
  int _attempt = 0;

  String get _sizeKey => '${_sessionId ?? ''}\n${_path ?? widget.url}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(MarkdownImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _source = imageSourceOf(widget.url);
      _resolve();
    }
  }

  void _resolve() {
    final source = _source;
    final url = source is WebImageSource ? source.url : widget.url.trim();
    final engine =
        (source is WebImageSource || source is WorkspaceImageSource) &&
        (ref.read(artifactFilesProvider).connection?.client.isEngineUrl(url) ?? false);
    if (source is WebImageSource || engine) {
      final next = engine ? url : null;
      if (next == _engineUrl && (next == null || _future != null || _loaded != null)) return;
      _engineUrl = next;
      _sessionId = null;
      _path = null;
      _future = null;
      _loaded = null;
      _error = null;
      if (next != null) _load();
      return;
    }
    _engineUrl = null;
    if (source is! WorkspaceImageSource) return;
    final scope = MarkdownImageScope.maybeOf(context);
    final sessionId = scope?.sessionId ?? ref.read(currentSessionProvider);
    if (sessionId == null) {
      _sessionId = null;
      _path = null;
      _future = null;
      _loaded = null;
      _error = const ArtifactError('offline');
      return;
    }
    final local = ref.read(artifactFilesProvider).isLocal;
    final baseDir = scope?.baseDir;
    final path = workspaceImagePath(
      source.path,
      baseDir: baseDir,
      cwd: baseDir == null && !source.path.startsWith('/') ? _cwdOf(sessionId) : null,
      local: local,
    );
    if (sessionId == _sessionId && path == _path && (_future != null || _loaded != null)) return;
    _sessionId = sessionId;
    _path = path;
    _load();
  }

  /// The session's working directory, when the app knows it. Only a chat
  /// already open is asked: reading one would start watching the session.
  String? _cwdOf(String sessionId) {
    final chat = chatProvider(sessionId);
    final header = ref.exists(chat) ? ref.read(chat.notifier).header : null;
    return header?.cwd ?? ref.read(sessionsProvider).value?.where((s) => s.sessionId == sessionId).firstOrNull?.cwd;
  }

  void _load() {
    final engineUrl = _engineUrl;
    final reader = ref.read(engineUrl != null ? engineImageReaderProvider : workspaceImageReaderProvider);
    final sessionId = engineUrl != null ? '' : _sessionId!;
    final path = engineUrl ?? _path!;
    _error = null;
    _loaded = reader.peek(sessionId, path);
    if (_loaded != null) {
      _future = null;
      return;
    }
    final future = _future = reader.read(sessionId, path);
    future.then(
      (image) {
        if (!mounted || _future != future) return;
        setState(() => _loaded = image);
      },
      onError: (Object error) {
        if (!mounted || _future != future) return;
        setState(() => _error = error);
      },
    );
  }

  /// The resized provider last drawn: a retry evicts it as well.
  ImageProvider? _inlineProvider;

  void _retry() {
    _inlineProvider?.evict();
    setState(() {
      _attempt += 1;
      final source = _source;
      if (_engineUrl != null) {
        ref.read(engineImageReaderProvider).forget('', _engineUrl!);
        _load();
      } else if (source is WorkspaceImageSource && _sessionId != null && _path != null) {
        ref.read(workspaceImageReaderProvider).forget(_sessionId!, _path!);
        _load();
      } else if (source is WebImageSource) {
        PaintingBinding.instance.imageCache.evict(NetworkImage(source.url));
        // The connection may have arrived since this image was first drawn.
        _resolve();
      }
    });
  }

  void _open(ImageProvider? image) {
    final source = _source;
    final sessionId = _sessionId;
    final path = _path;
    if (source is WorkspaceImageSource && sessionId != null && path != null) {
      Navigator.of(context).push(
        ArtifactPreviewPage.route(
          sessionId: sessionId,
          artifact: Artifact(path: path, origin: ArtifactOrigin.linked, turn: 0),
        ),
      );
      return;
    }
    if (image != null) {
      Navigator.of(context).push(ImageViewerPage.route(title: imageDisplayName(widget.url), image: image));
    }
  }

  @override
  Widget build(BuildContext context) {
    // A replaced connection has its own cookie and cache: read through it again.
    ref.listen(artifactFilesProvider.select((files) => files.connection?.client), (_, _) {
      if (_source is! WebImageSource && _source is! WorkspaceImageSource) return;
      setState(() {
        _engineUrl = null;
        _resolve();
      });
    });
    final l10n = context.l10n;
    // A media card above already shows this file: not a second time. Only
    // for a conversation already open (a previewed file never starts one).
    if (_source is WorkspaceImageSource &&
        _sessionId != null &&
        _path != null &&
        ref.exists(chatProvider(_sessionId!))) {
      final shown = ref.watch(sessionMediaPathsProvider(_sessionId!));
      if (shownInMediaCard(shown, _path!)) return const SizedBox.shrink();
    }
    final name = imageDisplayName(widget.url);
    Widget placeholder() => _ImagePlaceholder(size: _knownSizes[_sizeKey], hint: _hint);
    Widget failed(Object? error) {
      final message = error == null ? l10n.chatImageDisplayFailed : imageErrorText(error);
      // Too big to draw inline, but the full-screen preview can still show it.
      if (error is ImageTooLarge) {
        return _ImageError(name: name, message: message, action: l10n.chatImageTapToView, onTap: () => _open(null));
      }
      return _ImageError(name: name, message: message, action: l10n.chatImageTapToRetry, onTap: _retry);
    }

    Widget read() {
      final loaded = _loaded;
      if (_error != null) return failed(_error);
      if (loaded == null) return placeholder();
      return switch (loaded) {
        RasterImage(:final provider) => _raster(provider, placeholder: placeholder, failed: failed),
        // The preview page shows bitmaps only.
        SvgImageBytes(:final bytes) => _framed(
          memorySvg(bytes, fit: BoxFit.contain, error: (_) => failed(null)),
          onTap: null,
        ),
      };
    }

    final source = _source;
    final Widget child;
    switch (source) {
      case UnsupportedImageSource():
        child = _ImageError(name: name, message: l10n.chatImageUnsupportedAddress);
      case WebImageSource() when _engineUrl != null:
        child = read();
      case WebImageSource(:final url) when isSvgUrl(url):
        child = _framed(
          NetworkSvg(
            url,
            key: ValueKey(_attempt),
            fit: BoxFit.contain,
            loading: (_) => placeholder(),
            error: (_) => failed(null),
          ),
          onTap: null,
        );
      case WebImageSource(:final url):
        child = _raster(NetworkImage(url), placeholder: placeholder, failed: failed);
      case DataImageSource(:final url):
        final bytes = _dataBytes(url);
        if (bytes == null) {
          child = failed(null);
        } else if (isSvgUrl(url)) {
          child = _framed(memorySvg(bytes, fit: BoxFit.contain, error: (_) => failed(null)), onTap: null);
        } else {
          child = _raster(MemoryImage(bytes), placeholder: placeholder, failed: failed);
        }
      case WorkspaceImageSource():
        child = read();
    }
    return Semantics(image: true, label: name, child: child);
  }

  Size? get _hint {
    final w = widget.width;
    final h = widget.height;
    return w != null && h != null && w > 0 && h > 0 ? Size(w, h) : null;
  }

  Widget _raster(
    ImageProvider provider, {
    required Widget Function() placeholder,
    required Widget Function(Object? error) failed,
  }) {
    final resized = inlineImageProvider(provider, MediaQuery.devicePixelRatioOf(context), _hint);
    _inlineProvider = resized;
    return _SizeProbe(
      provider: resized,
      sizeKey: _sizeKey,
      child: Image(
        key: ValueKey((resized, _attempt)),
        image: resized,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        frameBuilder: (context, image, frame, synchronous) {
          if (frame == null) return placeholder();
          return _framed(image, onTap: () => _open(provider), onLongPress: () => _actions(provider));
        },
        errorBuilder: (context, error, _) => failed(error),
      ),
    );
  }

  /// [image] constrained to the column and [maxMarkdownImageHeight] (or the
  /// alt text's `WxH`), clipped to the well radius with a hairline edge so a
  /// white image still has a shape on a white page.
  Widget _framed(Widget image, {required VoidCallback? onTap, VoidCallback? onLongPress}) {
    final colors = Theme.of(context).colorScheme;
    final hint = _hint;
    Widget framed = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: hint?.width ?? double.infinity,
        maxHeight: hint?.height ?? maxMarkdownImageHeight,
      ),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: ShapeDecoration(
          shape: RoundedSuperellipseBorder(
            borderRadius: AppShape.radiusMd,
            side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.6), width: 0.5),
          ),
        ),
        child: Squircle.clip(radius: AppShape.md, child: image),
      ),
    );
    if (onTap != null || onLongPress != null) {
      framed = GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, onLongPress: onLongPress, child: framed);
    }
    return framed;
  }

  /// Long-press on a drawn picture: 「保存到相册」 / 「分享」 with its own bytes
  /// (the workspace file, the web image, the `data:` payload), not the
  /// smaller copy drawn inline. Wins over the reply's own long-press menu.
  void _actions(ImageProvider provider) => showImageActions(
    context,
    image: provider,
    load: () => imageProviderBytes(provider),
    name: imageDisplayName(widget.url),
  );
}

/// Listens to [provider] once to learn its natural size (for [_knownSizes]).
class _SizeProbe extends StatefulWidget {
  const _SizeProbe({required this.provider, required this.sizeKey, required this.child});

  final ImageProvider provider;
  final String sizeKey;
  final Widget child;

  @override
  State<_SizeProbe> createState() => _SizeProbeState();
}

class _SizeProbeState extends State<_SizeProbe> {
  ImageStream? _stream;
  late final _listener = ImageStreamListener((info, _) {
    _rememberSize(widget.sizeKey, Size(info.image.width / info.scale, info.image.height / info.scale));
    info.dispose();
    _stop();
  }, onError: (_, _) => _stop());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_knownSizes.containsKey(widget.sizeKey)) return;
    _stop();
    _stream = widget.provider.resolve(createLocalImageConfiguration(context))..addListener(_listener);
  }

  void _stop() {
    _stream?.removeListener(_listener);
    _stream = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A calm box where an image is about to be: the image's own shape when it
/// has been seen before (or the alt text says `WxH`), 4:3 otherwise.
class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({this.size, this.hint});

  final Size? size;
  final Size? hint;

  @override
  Widget build(BuildContext context) {
    final dsh = DshColors.of(context);
    final known = size ?? hint;
    final aspect = known == null || known.height <= 0 ? 4 / 3 : known.width / known.height;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: known?.width ?? double.infinity,
        maxHeight: hint?.height ?? maxMarkdownImageHeight,
      ),
      child: AspectRatio(
        aspectRatio: aspect,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: dsh.codeWellBg,
            shape: RoundedSuperellipseBorder(
              borderRadius: AppShape.radiusMd,
              side: BorderSide(color: dsh.codeWellBorder, width: 0.5),
            ),
          ),
          child: Center(child: Icon(AppIcons.image, size: 22, color: dsh.textTertiary)),
        ),
      ),
    );
  }
}

/// An image that cannot be shown: a small icon, its file name and why, on
/// the code-well tone — never a grey box with a broken-image glyph.
class _ImageError extends StatelessWidget {
  const _ImageError({required this.name, required this.message, this.action, this.onTap});

  final String name;
  final String message;

  /// What a tap does (`轻点重试`), appended to [message].
  final String? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final text = theme.textTheme.bodyMedium;
    Widget tile = DecoratedBox(
      decoration: ShapeDecoration(
        color: dsh.codeWellBg,
        shape: RoundedSuperellipseBorder(
          borderRadius: AppShape.radiusMd,
          side: BorderSide(color: dsh.codeWellBorder, width: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.imageBroken, size: 20, color: dsh.textTertiary),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text?.copyWith(color: theme.colorScheme.onSurface, height: 1.35),
                  ),
                  Text(
                    action == null ? message : '$message · $action',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.35),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (onTap != null) {
      tile = GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: tile);
    }
    return tile;
  }
}
