import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../media/gallery.dart' show imageProviderBytes;
import '../../../state/attachments.dart';
import '../../shell/page_frame.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'image_actions.dart';
import 'plus_panel.dart';
import 'stream_motion.dart';

export 'plus_panel.dart' show AttachSource;

/// The ＋ panel's tiles alone: without [files] (DSH Remote stages no files)
/// the two photo ones. The chat page opens the whole panel ([showPlusPanel]).
Future<AttachSource?> showAttachMenu(BuildContext context, {bool files = true}) async {
  final choice = await showPlusPanel(context, files: files);
  return choice is AttachChoice ? choice.source : null;
}

/// 40dp round ＋ at the composer's leading edge.
class AttachButton extends StatelessWidget {
  const AttachButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: l10n.chatAddAttachment,
      child: Tooltip(
        message: l10n.chatAddAttachment,
        child: InkResponse(
          onTap: onPressed == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onPressed!();
                },
          radius: 20,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: scheme.onSurface.withValues(alpha: 0.06), shape: BoxShape.circle),
            child: Icon(
              AppIcons.add,
              size: 22,
              color: enabled ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.38),
            ),
          ),
        ),
      ),
    );
  }
}

/// Picked-but-unsent attachments, in a strip above the composer's text.
class ComposerTray extends StatelessWidget {
  const ComposerTray({super.key, required this.items, required this.onRemove, this.labels = const []});

  final List<DraftAttachment> items;
  final ValueChanged<DraftAttachment> onRemove;

  /// A small label on the tile at the same position (generation mode's
  /// 首帧 / 尾帧), 6 in from its bottom-left corner.
  final List<Widget?> labels;

  static const height = 56 + _overhang;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final a = items[i];
          final tile = a.isImage
              ? _Thumb(
                  size: const Size.square(56),
                  heroTag: 'draft-${a.id}',
                  image: MemoryImage(a.bytes),
                  onTap: () => openImageViewer(context, MemoryImage(a.bytes), heroTag: 'draft-${a.id}', name: a.name),
                )
              : FileCard(name: a.name, bytes: a.size, height: 56, tinted: true);
          final label = i < labels.length ? labels[i] : null;
          return _Removable(
            onRemove: () => onRemove(a),
            label: l10n.chatRemoveAttachment(a.name),
            child: label == null
                ? tile
                : Stack(
                    children: [
                      tile,
                      Positioned(left: 6, bottom: 6, child: label),
                    ],
                  ),
          );
        },
      ),
    );
  }
}

/// How far the remove badge sticks out past a tray tile's corner.
const _overhang = 8.0;

class _Removable extends StatelessWidget {
  const _Removable({required this.child, required this.onRemove, required this.label});

  final Widget child;
  final VoidCallback onRemove;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The badge overhangs the tile's corner; the inset keeps all of it inside
    // the stack, so the whole circle is tappable.
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: _overhang, right: _overhang),
          child: child,
        ),
        Positioned(
          top: 0,
          right: 0,
          child: Semantics(
            container: true,
            button: true,
            label: label,
            child: GestureDetector(
              onTap: onRemove,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: 0.72),
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.surface, width: 1.5),
                  ),
                  child: Icon(AppIcons.close, size: 13, color: scheme.surface),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Attachments of one user message, right-aligned above its bubble: local
/// bytes while the message is in flight, then the session's stored copies.
class SentAttachments extends StatelessWidget {
  const SentAttachments.pending(this.drafts, {super.key}) : sessionId = null, images = const [], files = const [];

  const SentAttachments.echoed({super.key, required String this.sessionId, required this.images, required this.files})
    : drafts = const [];

  final List<DraftAttachment> drafts;
  final String? sessionId;
  final List<ImageAttachment> images;
  final List<FileAttachment> files;

  bool get isEmpty => drafts.isEmpty && images.isEmpty && files.isEmpty;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final imageCount = drafts.where((d) => d.isImage).length + images.length;
    // One image shows large at its own aspect; several become a grid of squares.
    final single = imageCount == 1;
    final children = <Widget>[
      for (final d in drafts)
        if (d.isImage)
          _Thumb(
            size: single ? null : const Size.square(88),
            heroTag: 'draft-${d.id}',
            image: MemoryImage(d.bytes),
            onTap: () => openImageViewer(context, MemoryImage(d.bytes), heroTag: 'draft-${d.id}', name: d.name),
          ),
      for (final img in images) _SessionImage(sessionId: sessionId!, attachment: img, single: single),
      for (final d in drafts)
        if (!d.isImage) FileCard(name: d.name, bytes: d.size),
      for (final f in files) FileCard(name: f.name ?? l10n.chatFile, bytes: f.bytes),
    ];
    return Wrap(alignment: WrapAlignment.end, spacing: 4, runSpacing: 4, children: children);
  }
}

/// Largest side of a lone image in a message.
const _singleMax = 208.0;

class _Thumb extends StatelessWidget {
  const _Thumb({required this.image, required this.heroTag, this.size, this.aspect, this.onTap, this.onLongPress});

  final ImageProvider image;
  final Object heroTag;

  /// Fixed box (cover); null = natural aspect within [_singleMax].
  final Size? size;

  /// Known width / height when [size] is null, so the box doesn't jump on load.
  final double? aspect;
  final VoidCallback? onTap;

  /// 「保存到相册」 / 「分享」 (sent images).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final placeholder = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decodeWidth = ((size?.width ?? _singleMax) * dpr).round();
    Widget picture = Image(
      image: ResizeImage(image, width: decodeWidth, policy: ResizeImagePolicy.fit),
      fit: size == null ? BoxFit.contain : BoxFit.cover,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, sync) =>
          frame == null && !sync ? ColoredBox(color: placeholder, child: const SizedBox.expand()) : child,
    );
    if (size case final s?) {
      picture = SizedBox.fromSize(size: s, child: picture);
    } else if (aspect case final a? when a > 0) {
      final w = a >= 1 ? _singleMax : _singleMax * a;
      picture = SizedBox(width: w, height: w / a, child: picture);
    } else {
      picture = ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _singleMax, maxHeight: _singleMax, minWidth: 48, minHeight: 48),
        child: picture,
      );
    }
    return Semantics(
      image: true,
      button: onTap != null,
      label: l10n.chatImage,
      child: StreamPress(
        enabled: onTap != null,
        child: GestureDetector(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Hero(
            tag: heroTag,
            child: Squircle.clip(radius: AppShape.md, child: picture),
          ),
        ),
      ),
    );
  }
}

class _SessionImage extends ConsumerWidget {
  const _SessionImage({required this.sessionId, required this.attachment, required this.single});

  final String sessionId;
  final ImageAttachment attachment;
  final bool single;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(sessionImageProvider((sessionId, attachment)));
    final w = attachment.width, h = attachment.height;
    final aspect = (w != null && h != null && h > 0) ? w / h : 1.0;
    final box = single ? null : const Size.square(88);
    final tag = 'img-$sessionId-${attachment.attachmentId}';
    return switch (bytes) {
      AsyncData(:final value) => _Thumb(
        size: box,
        aspect: aspect,
        heroTag: tag,
        image: MemoryImage(value),
        onTap: () => openImageViewer(context, MemoryImage(value), heroTag: tag, name: attachment.name),
        onLongPress: () =>
            showImageActions(context, image: MemoryImage(value), load: () async => value, name: attachment.name),
      ),
      AsyncError() => _ImagePlaceholder(size: box, aspect: aspect, failed: true),
      _ => _ImagePlaceholder(size: box, aspect: aspect),
    };
  }
}

class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({required this.size, required this.aspect, this.failed = false});

  final Size? size;
  final double aspect;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final w = size?.width ?? (aspect >= 1 ? _singleMax : _singleMax * aspect);
    final h = size?.height ?? w / aspect;
    return Container(
      width: w,
      height: h,
      decoration: ShapeDecoration(color: scheme.onSurface.withValues(alpha: 0.06), shape: AppShape.card),
      child: failed ? Icon(AppIcons.imageBroken, size: 22, color: DshColors.of(context).textTertiary) : null,
    );
  }
}

/// A file attachment: type badge, name, "PDF · 1.2 MB".
class FileCard extends StatelessWidget {
  const FileCard({super.key, required this.name, this.bytes, this.height = 56, this.tinted = false});

  final String name;
  final int? bytes;
  final double height;

  /// On the composer's glass (a faint fill) rather than a bubble-coloured card.
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaces = DshSurfaces.of(context);
    final dsh = DshColors.of(context);
    final ext = _extension(name);
    final (icon, tint) = _iconFor(ext);
    final badge = dsh.identity[tint % dsh.identity.length];
    final onBadge = dsh.onIdentity[tint % dsh.onIdentity.length];
    final meta = [if (ext != null) ext.toUpperCase(), if (bytes != null) formatBytes(bytes!)].join(' · ');
    // 外圆角 16、内边距 8、类型块圆角 8:内外同心(16 − 8)。
    return Container(
      height: height,
      constraints: const BoxConstraints(minWidth: 140, maxWidth: 220),
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
      decoration: ShapeDecoration(
        color: tinted ? theme.colorScheme.onSurface.withValues(alpha: 0.05) : surfaces.userBubble,
        shape: Squircle.border(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: height - 16,
            height: height - 16,
            decoration: ShapeDecoration(color: badge, shape: Squircle.border(8)),
            child: Icon(icon, size: 20, color: onBadge),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge),
                if (meta.isNotEmpty)
                  Text(
                    meta,
                    maxLines: 1,
                    style: AppType.tabular(
                      theme.textTheme.labelSmall!.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String? _extension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return null;
    final ext = name.substring(dot + 1);
    return ext.length > 6 ? null : ext.toLowerCase();
  }

  static (IconData, int) _iconFor(String? ext) => switch (ext) {
    'pdf' => (AppIcons.pdf, 1),
    'doc' || 'docx' || 'odt' || 'rtf' => (AppIcons.document, 0),
    'xls' || 'xlsx' || 'csv' || 'tsv' || 'ods' => (AppIcons.spreadsheet, 3),
    'ppt' || 'pptx' || 'key' => (AppIcons.slides, 2),
    'zip' || 'tar' || 'gz' || 'tgz' || 'xz' || '7z' || 'rar' => (AppIcons.zip, 5),
    'md' || 'txt' || 'log' => (AppIcons.plainText, 0),
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'heic' || 'bmp' || 'svg' => (AppIcons.image, 2),
    'mp3' || 'wav' || 'm4a' || 'flac' || 'ogg' => (AppIcons.audio, 4),
    'mp4' || 'mov' || 'mkv' || 'webm' => (AppIcons.video, 4),
    'py' ||
    'js' ||
    'ts' ||
    'dart' ||
    'json' ||
    'yaml' ||
    'yml' ||
    'sh' ||
    'java' ||
    'kt' ||
    'c' ||
    'cpp' ||
    'h' ||
    'go' ||
    'rs' ||
    'html' ||
    'css' ||
    'sql' ||
    'toml' ||
    'xml' => (AppIcons.code, 3),
    _ => (AppIcons.file, 5),
  };
}

/// Full-screen look at one image: pinch to zoom, tap or swipe away to close;
/// 「保存到相册」 top right, mirroring the close key; long-press for the
/// picture's menu. [name] is what the gallery calls the saved copy.
Future<void> openImageViewer(BuildContext context, ImageProvider image, {required Object heroTag, String? name}) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      transitionDuration: AppMotion.of(context, AppMotion.standard),
      reverseTransitionDuration: AppMotion.of(context, AppMotion.quick),
      pageBuilder: (context, animation, _) => FadeTransition(
        opacity: animation,
        child: _ImageViewer(image: image, heroTag: heroTag, name: name),
      ),
    ),
  );
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.image, required this.heroTag, this.name});

  final ImageProvider image;
  final Object heroTag;
  final String? name;

  Future<Uint8List> _bytes() => imageProviderBytes(image);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final padding = MediaQuery.paddingOf(context);
    // Its own (see-through) Scaffold: a toast shows above the dark veil, not
    // under it on the page behind.
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.of(context).maybePop(),
                onLongPress: () => showImageActions(context, image: image, load: _bytes, name: name),
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0).abs() > 600) {
                    Navigator.of(context).maybePop();
                  }
                },
                child: InteractiveViewer(
                  maxScale: 5,
                  child: Center(
                    child: Hero(
                      tag: heroTag,
                      child: Image(image: image, fit: BoxFit.contain),
                    ),
                  ),
                ),
              ),
            ),
            // Close and save: the same glass key, 12 in from either side.
            Positioned(
              top: padding.top + 6,
              left: 12,
              right: 12,
              child: Theme(
                data: buildDarkTheme(
                  accent: DshSurfaces.of(context).accent,
                  glassBlur: DshSurfaces.of(context).blurEnabled,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    GlassIconButton(
                      icon: AppIcons.close,
                      tooltip: l10n.commonClose,
                      grouped: false,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    GallerySaveButton(load: _bytes, name: name, grouped: false),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
