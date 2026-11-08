// Serves the companion page to its WebView from 127.0.0.1: the page and its
// script from the app's assets, everything Live2D from the installed pack. A
// server rather than file:// because the framework fetches shaders and model
// files, which a file page can't. Any app on the phone can reach a loopback
// port, so every path starts with a per-launch random token; nothing else
// answers. Lives only as long as the page.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import 'companion_pack.dart';

const _contentTypes = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.frag': 'text/plain; charset=utf-8',
  '.vert': 'text/plain; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.wav': 'audio/wav',
  '.mp3': 'audio/mpeg',
};

/// The page's own files, under `assets/companion/`.
const _appFiles = {'index.html', 'scene.js', 'stage.js', 'stage.css'};

class CompanionServer {
  CompanionServer._(this._server, this._token, this._assets, this._pack);

  static Future<CompanionServer> start(AssetBundle assets, Directory pack) async {
    final random = Random.secure();
    final token = base64Url.encode(List.generate(24, (_) => random.nextInt(256))).replaceAll('=', '');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return CompanionServer._(server, token, assets, pack).._listen();
  }

  final HttpServer _server;
  final String _token;
  final AssetBundle _assets;
  final Directory _pack;

  /// The page, with [query] for the stage's start-up options.
  Uri pageUrl({Map<String, String> query = const {}}) => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: _server.port,
    pathSegments: [_token, 'app', 'index.html'],
    queryParameters: query.isEmpty ? null : query,
  );

  bool ownsUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.scheme == 'http' &&
        uri.host == '127.0.0.1' &&
        uri.port == _server.port &&
        uri.pathSegments.firstOrNull == _token;
  }

  Future<void> close() => _server.close(force: true);

  void _listen() {
    _server.listen(
      (request) => unawaited(
        _handle(request).catchError((Object _) {
          // The page went away mid-response.
        }),
      ),
    );
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final List<String> segments;
    try {
      segments = request.uri.pathSegments;
    } on FormatException {
      return _refuse(response);
    }
    if (request.method != 'GET' && request.method != 'HEAD') return _refuse(response);
    if (segments.length < 3 || !_same(segments[0], _token)) return _refuse(response);

    final path = segments.sublist(2).join('/');
    if (!isSafePackPath(path) || segments.sublist(2).any((s) => s.contains('/'))) return _refuse(response);
    final type = _contentTypes[_extension(path)] ?? 'application/octet-stream';

    switch (segments[1]) {
      case 'app' when _appFiles.contains(path):
        final data = await _assets.load('assets/companion/$path');
        _headers(response, type, data.lengthInBytes);
        if (request.method == 'GET') response.add(Uint8List.sublistView(data));
        await response.close();
      case 'pack':
        final file = File('${_pack.path}/$path');
        if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file) {
          return _refuse(response);
        }
        _headers(response, type, await file.length());
        if (request.method == 'GET') await response.addStream(file.openRead());
        await response.close();
      default:
        return _refuse(response);
    }
  }

  void _headers(HttpResponse response, String type, int length) {
    response.headers
      ..set(HttpHeaders.contentTypeHeader, type)
      ..set('X-Content-Type-Options', 'nosniff')
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    response.contentLength = length;
  }

  Future<void> _refuse(HttpResponse response) async {
    response.statusCode = HttpStatus.notFound;
    await response.close();
  }
}

String _extension(String path) {
  final dot = path.lastIndexOf('.');
  return dot < 0 ? '' : path.substring(dot).toLowerCase();
}

/// Comparison that doesn't stop at the first different byte.
bool _same(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}
