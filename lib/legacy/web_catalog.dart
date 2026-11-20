import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'gbk_codec.dart';
import 'session_jar.dart';

/// Failure carrying a stable code; the transport layer maps it to the same
/// `WEB_*` platform errors the Kotlin bridge reported.
class WebCatalogFailure implements Exception {
  WebCatalogFailure(this.code, this.publicMessage);

  final String code;
  final String publicMessage;

  @override
  String toString() => publicMessage;
}

class CatalogPage {
  CatalogPage(this.html, this.cookies);

  final String html;
  final ApiSessionCookies cookies;
}

/// Official website session, deliberately separate from the API relay session.
class WenkuWebCatalogClient {
  WenkuWebCatalogClient({HttpClient? client})
      : _client = client ?? HttpClient()
          ..connectionTimeout = const Duration(seconds: 8)
          ..autoUncompress = true;

  final HttpClient _client;
  final Uri _origin = Uri.https('www.wenku8.net', '/');

  Future<CatalogPage> login(
    String username,
    String password,
    ApiSessionCookies account,
  ) async {
    if (username.trim().isEmpty ||
        username.length > 254 ||
        password.isEmpty ||
        password.length > 30) {
      throw ArgumentError('invalid web login credentials');
    }
    if (!Gbk.canEncode(username) || !Gbk.canEncode(password)) {
      throw WebCatalogFailure(
          'WEB_LOGIN_FAILED', '官网账号使用 GBK 编码，无法提交这些字符');
    }
    final body = 'username=${Gbk.urlEncode(username)}'
        '&password=${Gbk.urlEncode(password)}'
        '&action=login&usecookie=315360000';
    // Seed the site's PHP session before submitting the same transient
    // account login. No second password form or stored password is needed.
    final initial = await _request(
        _origin.resolve('login.php'), account.websiteSession(), null);
    final reply = await _request(
      _origin.resolve('login.php?do=submit'),
      initial.cookies,
      body,
    );
    if (!reply.cookies.hasWebLogin) {
      final message = reply.html.contains('验证码')
          ? '官网要求额外验证，暂时无法连接分类'
          : '官网未接受本次账号登录，当前文库账号仍保持登录';
      throw WebCatalogFailure('WEB_LOGIN_FAILED', message);
    }
    return reply;
  }

  Future<CatalogPage> page(int library, int page, ApiSessionCookies? cookies) {
    if (library < 1 || library > 10000 || page < 1 || page > 100000) {
      throw ArgumentError('invalid publication page');
    }
    if (cookies == null) {
      throw WebCatalogFailure('WEB_LOGIN_REQUIRED', '请先登录文库账号');
    }
    return _request(
      _origin.resolve(
        'modules/article/articlelist.php?class=$library&sort=lastupdate&page=$page',
      ),
      cookies,
      null,
    );
  }

  Future<CatalogPage> _request(
    Uri start,
    ApiSessionCookies initial,
    String? form,
  ) async {
    var url = start;
    var cookies = initial;
    var body = form;
    for (var hop = 0; hop <= 3; hop++) {
      final request = await _client.openUrl(body == null ? 'GET' : 'POST', url);
      request.followRedirects = false;
      request.headers.set('Accept', 'text/html,application/xhtml+xml');
      if (cookies.header().isNotEmpty) {
        request.headers.set('Cookie', cookies.header());
      }
      if (body != null) {
        request.headers.set('Content-Type',
            'application/x-www-form-urlencoded; charset=GBK');
        request.headers.set('Referer', _origin.resolve('login.php').toString());
        request.add(utf8.encode(body));
      }
      final response = await request.close().timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw WebCatalogFailure(
                'WEB_UNAVAILABLE', '官网分类暂时不可用，请稍后重试'),
          );
      try {
        cookies = cookies.merge(response.headers['set-cookie'] ?? const []);
        final status = response.statusCode;
        if (const {301, 302, 303, 307, 308}.contains(status)) {
          final location = response.headers.value('location');
          if (location == null || location.isEmpty) {
            throw WebCatalogFailure('WEB_RESPONSE', '分类跳转地址无效');
          }
          final next = url.resolve(location);
          if (hop == 3 ||
              next.scheme != _origin.scheme ||
              next.host != _origin.host ||
              next.port != _origin.port ||
              next.userInfo.isNotEmpty) {
            throw WebCatalogFailure('WEB_RESPONSE', '分类连接地址发生变化，请稍后重试');
          }
          url = next;
          if (status != 307 && status != 308) body = null;
          continue;
        }
        if (status == 403 || status == 429) {
          throw WebCatalogFailure(
              'WEB_UNAVAILABLE', '官网暂时拒绝分类请求，请稍后重试；当前账号仍保持登录');
        }
        if (status < 200 || status > 299) {
          throw WebCatalogFailure('WEB_UNAVAILABLE', '官网分类暂时不可用，请稍后重试');
        }
        final bytes = await _readBounded(response, 2 * 1024 * 1024);
        final html = _decode(bytes, response.headers.contentType);
        return CatalogPage(html, cookies);
      } finally {
        unawaited(response.detachSocket().then((socket) => socket.destroy(),
            onError: (Object _) {}));
      }
    }
    throw WebCatalogFailure('WEB_RESPONSE', '分类跳转次数过多');
  }

  static String _decode(List<int> bytes, ContentType? contentType) {
    final declaredUtf8 =
        contentType?.toString().toLowerCase().contains('utf-8') == true ||
        latin1
            .decode(bytes.take(2048).toList())
            .toLowerCase()
            .contains(RegExp('charset\\\\s*=\\\\s*["\']?utf-8'));
    if (declaredUtf8) return utf8.decode(bytes, allowMalformed: true);
    return Gbk.decode(bytes);
  }

  static Future<Uint8List> _readBounded(HttpClientResponse response, int limit) {
    final completer = Completer<Uint8List>();
    final builder = BytesBuilder(copy: false);
    late StreamSubscription<List<int>> subscription;
    subscription = response.listen((chunk) {
      if (builder.length + chunk.length > limit) {
        subscription.cancel();
        completer.completeError(
            WebCatalogFailure('WEB_RESPONSE', '分类页面超过大小限制'));
        return;
      }
      builder.add(chunk);
    }, onDone: () {
      if (!completer.isCompleted) completer.complete(builder.takeBytes());
    }, onError: (Object error) {
      if (!completer.isCompleted) completer.completeError(error);
    }, cancelOnError: true);
    return completer.future;
  }
}

class PublicationReply {
  PublicationReply(this.body, {this.apiCookies, this.webCookies});

  final String body;
  final ApiSessionCookies? apiCookies;
  final ApiSessionCookies? webCookies;
}

/// One signed-in identity, with API-first classification. A retired list action
/// is not an expired account; its official-site fallback reuses the same jar.
class WenkuPublicationSession {
  WenkuPublicationSession(this.website);

  final WenkuWebCatalogClient website;
  bool _websiteOnly = false;
  ApiSessionCookies? _observedAccount;

  void reset() {
    _websiteOnly = false;
    _observedAccount = null;
  }

  Future<PublicationReply> read(
    int library,
    int page,
    ApiSessionCookies? account,
    ApiSessionCookies? web,
    Future<({String body, ApiSessionCookies cookies})> Function(
            String action, ApiSessionCookies cookies)
        request,
  ) async {
    if (library < 1 || library > 10000 || page < 1 || page > 100000) {
      throw ArgumentError('invalid publication page');
    }
    final jar = account;
    if (jar == null || !jar.hasSession) {
      throw WebCatalogFailure('WEB_LOGIN_REQUIRED', '请先登录文库账号');
    }
    if (_observedAccount != jar) {
      _websiteOnly = false;
      _observedAccount = jar;
    }
    if (!_websiteOnly) {
      final result = await request(
        'action=novellist&sort=$library&page=$page&t=0',
        jar,
      );
      final body = result.body.trim().replaceFirst('\uFEFF', '').trimLeft();
      final shape = RegExp(r'^(?:<\?xml[^>]*>\s*)?<result(?:\s|/|>)');
      if (shape.hasMatch(body)) {
        return PublicationReply(body, apiCookies: result.cookies);
      }
      if (body != '4') {
        throw WebCatalogFailure('WEB_RESPONSE', '出版分类返回格式有误，请稍后重试');
      }
      _websiteOnly = true;
    }
    final result = await website.page(library, page, web ?? jar.websiteSession());
    return PublicationReply(
      result.html,
      webCookies: (web != null || result.cookies.hasWebLogin)
          ? result.cookies
          : null,
    );
  }
}
