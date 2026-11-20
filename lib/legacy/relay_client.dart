import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:ui' as ui;

import 'gbk_codec.dart';
import 'magic_version.dart';
import 'public_gateway.dart';
import 'session_jar.dart';
import 'web_catalog.dart';

/// The relay rejects reviews carrying characters outside its GBK encoding.
class ReviewEncodingException implements Exception {
  const ReviewEncodingException();
}

/// The Dart port of the Android bridge (`Wenku8Bridge.kt`): one signed relay
/// identity plus an image cache, with the same bounded responses and cookies.
class RelayClient {
  RelayClient({required SharedPreferences preferences})
      : _accountStore = _SessionStore(preferences, 'wenku_account_session'),
        _webStore = _SessionStore(preferences, 'wenku_web_session') {
    _webCatalog = WenkuWebCatalogClient();
    _publication = WenkuPublicationSession(_webCatalog);
  }

  static const _relay = 'https://wenku8-relay.mewx.org/';
  static const _versionInput = '1.30';
  static const _maxResponseBytes = 8 * 1024 * 1024;
  static const _maxImageBytes = 8 * 1024 * 1024;
  static const _maxCacheBytes = 256 * 1024 * 1024;

  final WenkuPublicGateway _gateway = WenkuPublicGateway();
  late final WenkuWebCatalogClient _webCatalog;
  late final WenkuPublicationSession _publication;
  final _SessionStore _accountStore;
  final _SessionStore _webStore;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..autoUncompress = true;

  ApiSessionCookies? _session;
  ApiSessionCookies? _web;
  bool _sessionLoaded = false;
  int _sessionRevision = 0;
  Directory? _illustrations;
  final _accountLock = _Lock();
  final _imageLock = _Lock();

  void setUpdatePriority(bool enabled) => _gateway.updatePriority = enabled;

  // ---------------------------------------------------------------- account

  Future<bool> hasSession() => _accountLock.run(() async {
        await _ensureSession();
        return _session?.hasSession == true;
      });

  Future<void> clearSession() {
    return _accountLock.run(() async {
      await _accountStore.write(null);
      await _webStore.write(null);
      _session = null;
      _web = null;
      _publication.reset();
      _sessionRevision++;
    });
  }

  Future<String> login(String action) => _accountLock.run(() async {
        if (!action.startsWith('action=login&') &&
            !action.startsWith('action=loginemail&')) {
          throw const FormatException('invalid login action');
        }
        final reply = await _request(action, null);
        final text = utf8.decode(reply.body);
        if (text.trim() == '1') {
          final cookie = ApiSessionCookies.empty.merge(reply.cookies);
          if (!cookie.hasSession) {
            throw const FormatException('missing session');
          }
          await _accountStore.write(cookie.stored());
          // Never retain another account's website session.
          await _webStore.write(null);
          _web = null;
          _publication.reset();
          _session = cookie;
          _sessionRevision++;
        }
        return text;
      });

  Future<String> accountRequest(String action) => _accountLock.run(() async {
        final revision = _sessionRevision;
        await _ensureSession();
        final cookie = _session;
        if (cookie == null) return '4';
        final reply = await _request(action, cookie);
        final text = utf8.decode(reply.body);
        final next = cookie.merge(reply.cookies);
        if (next != cookie && text.trim() != '4') {
          await _accountStore.write(next.hasSession ? next.stored() : null);
          _session = next.hasSession ? next : null;
        }
        if (revision != _sessionRevision) {
          throw const FormatException('session changed');
        }
        return text;
      });

  Future<Uint8List> accountAvatar() => _accountLock.run(() async {
        final revision = _sessionRevision;
        await _ensureSession();
        final cookie = _session;
        if (cookie?.hasSession != true || revision != _sessionRevision) {
          throw const FormatException('account session unavailable');
        }
        final reply = await _request('action=avatar', cookie);
        if (reply.body.length > 2 * 1024 * 1024) {
          throw const FormatException('avatar too large');
        }
        final bytes = Uint8List.fromList(reply.body);
        await _validateImage(bytes);
        if (revision != _sessionRevision) {
          throw const FormatException('session changed');
        }
        return bytes;
      });

  Future<void> webLogin(String username, String password) =>
      _accountLock.run(() async {
        final revision = _sessionRevision;
        await _ensureSession();
        final cookie = _session;
        if (cookie?.hasSession != true || revision != _sessionRevision) {
          throw WebCatalogFailure('WEB_LOGIN_FAILED', '请先登录文库账号');
        }
        final web = await _webCatalog.login(username, password, cookie!);
        await _webStore.write(
            web.cookies.hasWebLogin ? web.cookies.stored() : null);
        _web = web.cookies.hasWebLogin ? web.cookies : null;
      });

  Future<String> publicationPage(int library, int page) =>
      _accountLock.run(() async {
        final revision = _sessionRevision;
        await _ensureSession();
        if (revision != _sessionRevision) {
          throw const FormatException('session changed');
        }
        final reply = await _publication.read(
          library,
          page,
          _session,
          _web,
          (action, cookie) async {
            final response = await _request(action, cookie);
            return (
              body: utf8.decode(response.body),
              cookies: cookie.merge(response.cookies),
            );
          },
        );
        final apiCookies = reply.apiCookies;
        if (apiCookies != null && apiCookies != _session) {
          await _accountStore
              .write(apiCookies.hasSession ? apiCookies.stored() : null);
          _session = apiCookies.hasSession ? apiCookies : null;
        }
        final webCookies = reply.webCookies;
        if (webCookies != null && webCookies != _web) {
          await _webStore
              .write(webCookies.hasWebLogin ? webCookies.stored() : null);
          _web = webCookies.hasWebLogin ? webCookies : null;
        }
        return reply.body;
      });

  Future<void> _ensureSession() async {
    if (_sessionLoaded) return;
    final account = await _accountStore.read();
    final web = await _webStore.read(requireSession: false);
    _session =
        account == null ? null : ApiSessionCookies.fromStored(account);
    _web = web == null
        ? null
        : ApiSessionCookies.fromStored(web, requireSession: false);
    _sessionLoaded = true;
  }

  // ------------------------------------------------------------------ guest

  Future<String> request(String action) async {
    final reply = await _request(action, null);
    return utf8.decode(reply.body);
  }

  Future<Uint8List> cover(int aid) async {
    if (aid <= 0) throw ArgumentError('invalid cover id');
    final reply = await _request('action=book&do=cover&aid=$aid', null);
    return Uint8List.fromList(reply.body);
  }

  Future<Uint8List> illustration(String url) => _imageLock.run(() async {
        final source = _checkedImageUrl(url);
        final name = sha256.convert(utf8.encode(url)).toString();
        final directory = _illustrations ??= Directory(
          '${(await getApplicationSupportDirectory()).path}/wenku8-illustrations-v1',
        );
        final file = File('${directory.path}/$name');
        if (await file.exists()) {
          try {
            final cached = await file.readAsBytes();
            if (cached.isEmpty || cached.length > _maxImageBytes) {
              throw const FormatException('cached illustration out of bounds');
            }
            await _validateImage(cached);
            unawaited(_touch(file));
            return cached;
          } catch (_) {
            unawaited(file.delete().catchError((Object _) {}));
          }
        }
        final bytes = await _downloadImage(source);
        try {
          await directory.create(recursive: true);
          final temporary = File('${directory.path}/$name.part');
          await temporary.writeAsBytes(bytes, flush: true);
          await temporary.rename(file.path);
          unawaited(_evict(directory, keep: file));
        } catch (_) {
          // An online illustration survives a cache write error.
        }
        return bytes;
      });

  Future<void> clearIllustrations() => _imageLock.run(() async {
        final directory = _illustrations;
        if (directory != null && await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });

  Future<String> encodeReview(String text) async {
    if (text.length > 10000) {
      throw const FormatException('review too long');
    }
    if (!Gbk.canEncode(text)) {
      throw const ReviewEncodingException();
    }
    return base64Encode(utf8.encode(Gbk.urlEncode(text)));
  }

  // ---------------------------------------------------------------- private

  Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {}
  }

  Future<void> _evict(Directory directory, {required File keep}) async {
    try {
      final files =
          (await directory.list(followLinks: false).toList())
              .whereType<File>()
              .toList();
      final dated = <(File, DateTime)>[];
      var total = 0;
      for (final file in files) {
        try {
          final modified = await file.lastModified();
          dated.add((file, modified));
          total += await file.length();
        } catch (_) {}
      }
      if (total <= _maxCacheBytes) return;
      dated.sort((a, b) => a.$2.compareTo(b.$2));
      for (final (file, _) in dated) {
        if (total <= _maxCacheBytes) break;
        if (file.path == keep.path) continue;
        try {
          final length = await file.length();
          await file.delete();
          total -= length;
        } catch (_) {}
      }
    } catch (_) {}
  }

  Uri _checkedImageUrl(String raw) {
    final uri = Uri.parse(raw);
    final host = uri.host.toLowerCase();
    final supported = host == 'pic.777743.xyz' ||
        const ['wenku8.com', 'wenku8.net', 'wenku8.cn']
            .any((suffix) => host == suffix || host.endsWith('.$suffix'));
    if (!supported ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443) ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('unsupported image address');
    }
    return uri;
  }

  Future<Uint8List> _downloadImage(Uri source) async {
    try {
      return await _downloadImageDirect(source);
    } catch (failure) {
      final bytes = await _gateway.image(source);
      if (bytes != null) {
        try {
          await _validateImage(bytes);
          return bytes;
        } catch (_) {
          // Preserve the original failure.
        }
      }
      throw failure;
    }
  }

  Future<Uint8List> _downloadImageDirect(Uri source) async {
    var url = source;
    for (var hop = 0; hop <= 3; hop++) {
      final request = await _http.openUrl('GET', url);
      request.followRedirects = false;
      final response =
          await request.close().timeout(const Duration(seconds: 12));
      try {
        final status = response.statusCode;
        if (const {301, 302, 303, 307, 308}.contains(status)) {
          if (hop == 3) throw const FormatException('too many image redirects');
          final location = response.headers.value('location');
          if (location == null || location.isEmpty) {
            throw const FormatException('missing image redirect');
          }
          url = _checkedImageRedirect(url, location);
          continue;
        }
        if (status < 200 || status > 299) {
          throw HttpException('image status $status');
        }
        final bytes = await _readBounded(response, _maxImageBytes);
        await _validateImage(bytes);
        return bytes;
      } finally {
        unawaited(response.drain<void>().catchError((Object _) {}));
      }
    }
    throw const FormatException('image redirect limit');
  }

  /// Recheck every hop, upgrading the site's historical HTTP redirects while
  /// keeping percent-escaped paths and query signatures byte-for-byte.
  Uri _checkedImageRedirect(Uri from, String location) {
    final next = from.resolve(location);
    if (next.scheme != 'http' && next.scheme != 'https') {
      throw const FormatException('unsafe image redirect');
    }
    if (next.hasPort && next.port != 80 && next.port != 443) {
      throw const FormatException('unsafe image redirect');
    }
    var authority = next.authority;
    if (next.port == 80) {
      authority = authority.replaceFirst(RegExp(r':80$'), '');
    }
    final secure = Uri.parse('https://$authority${next.path}'
        '${next.hasQuery ? '?${next.query}' : ''}'
        '${next.hasFragment ? '#${next.fragment}' : ''}');
    return _checkedImageUrl(secure.toString());
  }

  Future<({List<int> body, List<String> cookies})> _request(
    String action,
    ApiSessionCookies? cookie,
  ) async {
    if (action.isEmpty || action.length > 60000) {
      throw const FormatException('invalid action');
    }
    try {
      final encoded = base64Encode(utf8.encode(action));
      final body = '&appver=${MagicVersion.call(_versionInput)}'
          '&request=$encoded'
          '&timetoken=${DateTime.now().millisecondsSinceEpoch}';
      final request = await _http.openUrl('POST', Uri.parse(_relay));
      request.headers.set(
        'Content-Type',
        'application/x-www-form-urlencoded; charset=UTF-8',
      );
      if (cookie != null && cookie.header().isNotEmpty) {
        request.headers.set('Cookie', cookie.header());
      }
      request.add(utf8.encode(body));
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 || response.statusCode > 299) {
        throw HttpException('relay status ${response.statusCode}');
      }
      final bytes =
          await _readBounded(response, _maxResponseBytes)
              .timeout(const Duration(seconds: 10));
      return (
        body: bytes,
        cookies: response.headers['set-cookie'] ?? const <String>[],
      );
    } on Exception {
      if (cookie == null) {
        // The existing catalogue relay already uses Cloudflare. Only public
        // image bytes use the small spare gateway allowance.
        final bytes = await _gateway.cover(action);
        if (bytes != null) {
          await _validateImage(bytes);
          return (body: bytes, cookies: const <String>[]);
        }
      }
      rethrow;
    }
  }

  static Future<Uint8List> _readBounded(
    HttpClientResponse response,
    int limit,
  ) async {
    final completer = Completer<Uint8List>();
    final builder = BytesBuilder(copy: false);
    late StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (chunk) {
        if (builder.length + chunk.length > limit) {
          subscription.cancel();
          completer.completeError(const FormatException('response too large'));
          return;
        }
        builder.add(chunk);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(builder.takeBytes());
      },
      onError: (Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  Future<void> _validateImage(List<int> bytes) async {
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
    final frame = await codec.getNextFrame();
    final width = frame.image.width;
    final height = frame.image.height;
    frame.image.dispose();
    codec.dispose();
    if (width <= 0 || height <= 0 || width * height > 50000000) {
      throw const FormatException('invalid image payload');
    }
  }
}

/// Serialises the account operations the Android bridge ran on a dedicated
/// single-thread executor.
class _Lock {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }
}

/// Session persistence. The Android bridge sealed the payload in the keystore;
/// desktop keeps the same `cookies-v2:` payload in the profile directory.
class _SessionStore {
  _SessionStore(this._preferences, this._scope);

  final SharedPreferences _preferences;
  final String _scope;

  Future<String?> read({bool requireSession = true}) async {
    final value = _preferences.getString('$_scope.sealed');
    if (value == null) return null;
    try {
      ApiSessionCookies.fromStored(value, requireSession: requireSession);
      return value;
    } catch (_) {
      await _preferences.remove('$_scope.sealed');
      return null;
    }
  }

  Future<void> write(String? value) async {
    if (value == null) {
      await _preferences.remove('$_scope.sealed');
      return;
    }
    // Validate before persisting, matching the sealed round-trip.
    ApiSessionCookies.fromStored(value, requireSession: false);
    await _preferences.setString('$_scope.sealed', value);
  }
}
