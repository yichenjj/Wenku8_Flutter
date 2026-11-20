import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Image-only backup gateway; all catalogue/account requests retain the
/// existing Cloudflare relay. Ported from the Android bridge's spare gateway.
class WenkuPublicGateway {
  WenkuPublicGateway();

  static const _gateway = 'https://app.3952039.xyz';
  static const _imageHosts = {
    'img.wenku8.com',
    'pic.wenku8.com',
    'pic.wenku8.cn',
    'pic.wenku8.net',
    'pic.777743.xyz',
  };
  static final _coverAction =
      RegExp(r'^action=book&do=cover&aid=([1-9]\d{0,7})(?:&t=0)?$');
  static final _imagePath = RegExp(
    r'^/(?:image|pictures|\d+)/[a-zA-Z0-9_/-]+\.(?:jpe?g|png|gif|webp)$',
    caseSensitive: false,
  );

  bool updatePriority = false;
  int _active = 0;
  int _bypassUntilMs = 0;

  Uri? coverUrl(String action) {
    final match = _coverAction.firstMatch(action);
    final aid = match?.group(1);
    if (aid == null) return null;
    final id = int.parse(aid);
    return Uri.parse('https://img.wenku8.com/image/${id ~/ 1000}/$id/${id}s.jpg');
  }

  /// The site's verified image-only CDN hosts, https, no query or fragments.
  bool allowsImage(Uri source) =>
      source.scheme == 'https' &&
      source.userInfo.isEmpty &&
      source.port == -1 &&
      source.query.isEmpty &&
      source.fragment.isEmpty &&
      _imageHosts.contains(source.host) &&
      _imagePath.hasMatch(source.path);

  Future<Uint8List?> cover(String action) async {
    final url = coverUrl(action);
    if (url == null) return null;
    return image(url);
  }

  Future<Uint8List?> image(Uri source) async {
    if (!allowsImage(source)) return null;
    final encoded =
        base64Url.encode(utf8.encode(source.toString())).replaceAll('=', '');
    return _attempt('/image/$encoded');
  }

  Future<Uint8List?> _attempt(String path) async {
    if (updatePriority ||
        DateTime.now().millisecondsSinceEpoch < _bypassUntilMs ||
        _active >= 2) {
      return null;
    }
    _active++;
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(milliseconds: 2500)
        ..autoUncompress = true;
      final request =
          await client.openUrl('GET', Uri.parse('$_gateway$path').normalizePath());
      request.headers.set('User-Agent', 'Wenku8-Flutter');
      request.followRedirects = false;
      final response = await request.close().timeout(
            const Duration(seconds: 4),
          );
      try {
        if (response.statusCode != 200) {
          final retryAfter =
              int.tryParse(response.headers.value('retry-after') ?? '');
          _bypass(
            retryAfter == null
                ? 60
                : retryAfter.clamp(60, 86400),
          );
          return null;
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (builder.length + chunk.length > 8 * 1024 * 1024) {
            throw Exception('gateway image too large');
          }
          builder.add(chunk);
        }
        final bytes = builder.takeBytes();
        if (bytes.isEmpty) throw Exception('gateway image empty');
        return bytes;
      } finally {
        unawaited(response.detachSocket().then((socket) => socket.destroy(),
            onError: (Object _) {}));
      }
    } catch (_) {
      _bypass(60);
      return null;
    } finally {
      client?.close(force: true);
      _active--;
    }
  }

  void _bypass(int seconds) {
    _bypassUntilMs =
        DateTime.now().millisecondsSinceEpoch + seconds * 1000;
  }
}
