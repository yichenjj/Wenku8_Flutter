import 'dart:io';

/// A relay-scoped cookie jar, matching the Android bridge's jar: only the site
/// session is transferable, guest requests never receive or mutate it.
class ApiSessionCookies {
  ApiSessionCookies._(this.values);

  final Map<String, String> values;

  static const _prefix = 'cookies-v2:';
  static final _sessionId = RegExp(r'^[A-Za-z0-9,-]{8,256}$');
  static final _cookieName = RegExp(r"^[!#$%&'*+.^_`|~A-Za-z0-9-]+$");
  // Workers can combine Set-Cookie fields; split on commas that start a new
  // cookie, never inside an Expires date.
  static final _combined = RegExp(r",\s*(?=[!#$%&'*+.^_`|~A-Za-z0-9-]+=)");

  static final ApiSessionCookies empty = ApiSessionCookies._(const {});

  bool get hasSession => _sessionId.hasMatch(values['PHPSESSID'] ?? '');
  bool get hasWebLogin => (values['jieqiUserInfo'] ?? '').isNotEmpty;

  String header() =>
      values.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');

  String stored() => _prefix + header();

  /// Only the site's CMS session is transferable from its API relay. Relay
  /// infrastructure cookies remain scoped to the API, not another host.
  ApiSessionCookies websiteSession() => _checked({
        for (final entry in values.entries)
          if (entry.key == 'PHPSESSID' || entry.key.startsWith('jieqi'))
            entry.key: entry.value,
      });

  ApiSessionCookies merge(List<String> headers) {
    final next = Map<String, String>.of(values);
    for (final header in headers) {
      for (final field in header.split(_combined)) {
        final cookie = _ParsedCookie.parse(field);
        if (cookie == null) continue;
        _validate(cookie.name, cookie.value);
        if (cookie.hasExpired || cookie.value.isEmpty) {
          next.remove(cookie.name);
        } else {
          next[cookie.name] = cookie.value;
        }
      }
    }
    return _checked(next);
  }

  static ApiSessionCookies fromStored(String value,
      {bool requireSession = true}) {
    // Existing plain session ids stay usable across upgrades.
    if (_sessionId.hasMatch(value)) {
      return _checked({'PHPSESSID': value});
    }
    if (!value.startsWith(_prefix)) {
      throw const FormatException('unrecognised stored cookie format');
    }
    final pairs = <String, String>{};
    for (final part in value.substring(_prefix.length).split('; ')) {
      final separator = part.indexOf('=');
      if (separator <= 0) {
        throw const FormatException('stored cookie pair missing =');
      }
      final name = part.substring(0, separator);
      final cookieValue = part.substring(separator + 1);
      _validate(name, cookieValue);
      pairs[name] = cookieValue;
    }
    final jar = _checked(pairs);
    if (requireSession && !jar.hasSession) {
      throw const FormatException('stored cookie lost its session');
    }
    return jar;
  }

  static ApiSessionCookies _checked(Map<String, String> input) {
    if (input.length > 32) {
      throw const FormatException('too many cookies');
    }
    for (final entry in input.entries) {
      _validate(entry.key, entry.value);
    }
    final jar = ApiSessionCookies._(Map.unmodifiable(input));
    if (jar.header().length > 16384) {
      throw const FormatException('cookie header too large');
    }
    return jar;
  }

  static void _validate(String name, String value) {
    if (!_cookieName.hasMatch(name)) {
      throw FormatException('invalid cookie name');
    }
    if (value.length > 8192 ||
        !value.codeUnits.every((unit) => unit >= 0x21 && unit <= 0x7e)) {
      throw const FormatException('invalid cookie value');
    }
  }
}

class _ParsedCookie {
  _ParsedCookie._(this.name, this.value, this.hasExpired);

  final String name, value;
  final bool hasExpired;

  /// A port of Java's HttpCookie.parse for the fields the relay actually
  /// sends: the first name/value pair wins, Expires decides expiry.
  static _ParsedCookie? parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final attributes = trimmed.split(';');
    final head = attributes.first;
    final separator = head.indexOf('=');
    final name = (separator <= 0 ? head : head.substring(0, separator)).trim();
    var value = separator <= 0 ? '' : head.substring(separator + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    var hasExpired = false;
    for (final attribute in attributes.skip(1)) {
      final body = attribute.trim();
      if (body.length <= 8 || !body.toLowerCase().startsWith('expires=')) {
        continue;
      }
      final date = body.substring(8).trim();
      try {
        hasExpired = HttpDate.parse(date).isBefore(DateTime.now());
      } on FormatException {
        // An unparseable expiry keeps the cookie, matching the JVM parser.
      }
    }
    return _ParsedCookie._(name, value, hasExpired);
  }
}
