import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

/// The picture of what a [RepaintBoundary] with this [key] draws, as PNG bytes,
/// [pixelRatio] pixels per logical pixel; null when the boundary isn't on screen.
Future<Uint8List?> capturePng(GlobalKey key, {double pixelRatio = 3}) async {
  final boundary = key.currentContext?.findRenderObject();
  if (boundary is! RenderRepaintBoundary) return null;
  final image = await boundary.toImage(pixelRatio: pixelRatio);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// Hands a PNG on: [name] and [bytes] are the picture, [text] goes with it where
/// the app it is shared to takes one. [origin] is what was tapped, for the share
/// sheet's arrow on an iPad. Returns false when the member cancelled.
typedef SaveImage = Future<bool> Function(String name, Uint8List bytes, String text, Rect? origin);

const _pngFiles = XTypeGroup(
  label: 'PNG',
  extensions: ['png'],
  mimeTypes: ['image/png'],
  uniformTypeIdentifiers: ['public.png'],
);

bool get _isDesktop =>
    !kIsWeb && {TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.windows}.contains(defaultTargetPlatform);

/// A save dialog on desktop; elsewhere the share sheet, which on the web
/// downloads the file when the browser can't share it.
Future<bool> shareOrSaveImage(String name, Uint8List bytes, String text, Rect? origin) async {
  final file = XFile.fromData(bytes, mimeType: 'image/png', name: name);
  if (_isDesktop) {
    final location = await getSaveLocation(suggestedName: name, acceptedTypeGroups: const [_pngFiles]);
    if (location == null) return false;
    await file.saveTo(location.path);
    return true;
  }
  final result = await SharePlus.instance.share(
    ShareParams(files: [file], fileNameOverrides: [name], text: text, sharePositionOrigin: origin),
  );
  return result.status != ShareResultStatus.dismissed;
}
