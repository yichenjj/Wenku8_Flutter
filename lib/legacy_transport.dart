import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'legacy/relay_client.dart';
import 'legacy/web_catalog.dart';

/// The same v1.30 POST bridge. Android keeps its platform channel; the Linux
/// build runs the identical protocol in Dart against the injected API runtime.
/// Account cookies never cross into Dart or backups.
abstract final class LegacyTransport {
  static const channel = MethodChannel('org.mewx.wenku8/legacy_api');

  static bool _platformSettled = false;
  static RelayClient? _client;
  static Future<RelayClient?>? _creating;

  /// The in-process client on platforms without the platform channel, null
  /// when this build keeps using Android's bridge. The non-Linux answer is
  /// produced synchronously: a cached future created inside another test's
  /// fake-async zone would never resume for later callers.
  static Future<RelayClient?> platformClient() async {
    if (_platformSettled) return _client;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.linux) {
      _platformSettled = true;
      _client = null;
      return null;
    }
    _creating ??= _createClient();
    _client = await _creating!;
    _platformSettled = true;
    return _client;
  }

  static Future<RelayClient?> _createClient() async {
    final preferences = await SharedPreferences.getInstance();
    return RelayClient(preferences: preferences);
  }

  static Future<void> setUpdatePriority(bool enabled) async {
    final client = await platformClient();
    if (client != null) {
      client.setUpdatePriority(enabled);
      return;
    }
    try {
      await channel.invokeMethod<void>('updatePriority', {'enabled': enabled});
    } on MissingPluginException {
      // Non-Android clients keep the original transport.
    }
  }

  static Future<String> request(String action) async {
    final client = await platformClient();
    if (client != null) return _wrap(() => client.request(action));
    return _text('request', action);
  }

  static Future<String> accountRequest(String action) async {
    final client = await platformClient();
    if (client != null) return _wrap(() => client.accountRequest(action));
    return _text('accountRequest', action);
  }

  /// Read-only routes which the service may gate behind a signed-in session.
  /// Public discovery/search remain independent from account cookies.
  static Future<String> sessionRead(String action) async =>
      await hasSession() ? accountRequest(action) : request(action);

  static Future<String> login(String action) async {
    final client = await platformClient();
    if (client != null) return _wrap(() => client.login(action));
    return _text('login', action);
  }

  static Future<Uint8List> accountAvatar() async {
    final client = await platformClient();
    if (client != null) return _wrap(() => client.accountAvatar());
    final bytes = await channel.invokeMethod<Uint8List>('accountAvatar');
    if (bytes == null || bytes.isEmpty) throw const FormatException('账号暂无头像');
    return bytes;
  }

  static Future<String> _text(String method, String action) async {
    final text = await channel.invokeMethod<String>(method, {'action': action});
    if (text == null || text.trim().isEmpty) {
      throw const FormatException('接口返回空内容');
    }
    return text;
  }

  static Future<bool> hasSession() async {
    final client = await platformClient();
    if (client != null) return _wrap(() => client.hasSession());
    return await channel.invokeMethod<bool>('hasSession') ?? false;
  }

  static Future<void> clearSession() async {
    final client = await platformClient();
    if (client != null) return _wrap(() => client.clearSession());
    return channel.invokeMethod<void>('clearSession');
  }

  static Future<void> connectPublications(
    String username,
    String password,
  ) async {
    final client = await platformClient();
    if (client != null) {
      return _wrap(() => client.webLogin(username, password));
    }
    try {
      await channel.invokeMethod<void>('webLogin', {
        'username': username,
        'password': password,
      });
    } on PlatformException catch (failure) {
      if (failure.code.startsWith('WEB_')) {
        throw FormatException(failure.message ?? '分类连接未成功');
      }
      rethrow;
    }
  }

  static Future<String> publicationPage(int library, int page) async {
    final client = await platformClient();
    if (client != null) {
      return _wrap(() => client.publicationPage(library, page));
    }
    return (await channel.invokeMethod<String>('publicationPage', {
          'library': library,
          'page': page,
        })) ??
        '';
  }

  static Future<Uint8List> illustration(String url) async {
    final client = await platformClient();
    if (client != null) return _wrap(() => client.illustration(url));
    final bytes = await channel.invokeMethod<Uint8List>('illustration', {
      'url': url,
    });
    if (bytes == null || bytes.isEmpty) throw const FormatException('插图内容为空');
    return bytes;
  }

  static Future<void> clearIllustrations() async {
    final client = await platformClient();
    if (client != null) return _wrap(() => client.clearIllustrations());
    return channel.invokeMethod<void>('clearIllustrations');
  }

  static Future<String> encodeReview(String text) async {
    final client = await platformClient();
    if (client != null) return _wrap(() => client.encodeReview(text));
    try {
      final encoded = await channel.invokeMethod<String>('encodeReview', {
        'text': text,
      });
      if (encoded == null || encoded.isEmpty) {
        throw const FormatException('书评编码返回空内容');
      }
      return encoded;
    } on PlatformException catch (error) {
      if (error.code == 'REVIEW_ENCODING') {
        throw const FormatException('原版书评接口使用 GBK，请移除表情或特殊字符后重试；草稿仍保留');
      }
      rethrow;
    }
  }

  /// Android reported a blanket error for every bridge failure; the Dart
  /// client reproduces the same platform errors so the UI handling matches.
  static Future<T> _wrap<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on WebCatalogFailure catch (failure) {
      throw PlatformException(
        code: failure.code,
        message: failure.publicMessage,
      );
    } on ReviewEncodingException {
      throw PlatformException(
        code: 'REVIEW_ENCODING',
        message: 'Characters outside the review encoding',
      );
    } on ArgumentError {
      throw PlatformException(
        code: 'LEGACY_API_ERROR',
        message: 'Request or local storage failed',
      );
    } on Exception {
      throw PlatformException(
        code: 'LEGACY_API_ERROR',
        message: 'Request or local storage failed',
      );
    } on Error {
      // The injected runtime is missing or incompatible.
      throw PlatformException(
        code: 'LEGACY_API_RUNTIME',
        message: 'Legacy runtime unavailable',
      );
    }
  }
}
