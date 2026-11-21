import 'dart:convert';
import 'dart:typed_data';

import 'gb18030_ranges.dart';
import 'gbk_table.dart';

/// GBK support for the review encoder and the website client. The original
/// Android runtime used the JVM charset; these tables reproduce CP936 for the
/// two-byte range (ASCII passes through untouched). Decoding additionally
/// resolves four-byte GB18030 sequences (CJK extensions and beyond), while
/// encoding stays GBK-conservative so the login/review guards keep their
/// "server speaks GBK" semantics.
abstract final class Gbk {
  /// Returns the GBK bytes for [text], or null when any character is outside
  /// the encoding.
  static Uint8List? tryEncode(String text) {
    final out = BytesBuilder();
    for (final unit in text.codeUnits) {
      if (unit < 0x80) {
        out.addByte(unit);
        continue;
      }
      final gbk = _encodeOne(unit);
      if (gbk == null) return null;
      out.addByte(gbk >> 8 & 0xff);
      out.addByte(gbk & 0xff);
    }
    return out.takeBytes();
  }

  static bool canEncode(String text) {
    for (final unit in text.codeUnits) {
      if (unit < 0x80) continue;
      if (_encodeOne(unit) == null) return false;
    }
    return true;
  }

  /// Decodes GBK bytes; four-byte GB18030 sequences resolve through the
  /// linear range table and invalid bytes degrade to U+FFFD.
  static String decode(List<int> bytes) {
    final buffer = StringBuffer();
    for (var i = 0; i < bytes.length;) {
      final byte = bytes[i];
      if (byte < 0x80) {
        buffer.writeCharCode(byte);
        i++;
        continue;
      }
      final second = i + 1 < bytes.length ? bytes[i + 1] : -1;
      final validTrail =
          second >= 0x40 && second <= 0xfe && second != 0x7f;
      if (byte >= 0x81 && byte <= 0xfe && validTrail) {
        final codepoint = _decodeOne(byte << 8 | second);
        buffer.writeCharCode(codepoint ?? 0xfffd);
        i += 2;
        continue;
      }
      if (byte >= 0x81 && byte <= 0xfe && second >= 0x30 && second <= 0x39) {
        // Four-byte GB18030 sequence; a truncated or mis-shaped tail still
        // consumes the whole shape so stray bytes never re-parse as text.
        final third = i + 2 < bytes.length ? bytes[i + 2] : -1;
        final fourth = i + 3 < bytes.length ? bytes[i + 3] : -1;
        if (third >= 0x81 && third <= 0xfe && fourth >= 0x30 && fourth <= 0x39) {
          final index = (byte - 0x81) * 12600 +
              (second - 0x30) * 1260 +
              (third - 0x81) * 10 +
              (fourth - 0x30);
          buffer.writeCharCode(_fourByteDecode(index) ?? 0xfffd);
        } else {
          buffer.writeCharCode(0xfffd);
        }
        i += 4;
        continue;
      }
      buffer.writeCharCode(0xfffd);
      i++;
    }
    return buffer.toString();
  }

  /// Java's `URLEncoder.encode(text, "GBK")`: percent-escapes every byte except
  /// `[A-Za-z0-9.\-*_]`, and renders spaces as `+`.
  static String urlEncode(String text) {
    final bytes = tryEncode(text);
    if (bytes == null) {
      throw const FormatException('GBK 编码无法表示这些字符');
    }
    final buffer = StringBuffer();
    const hex = '0123456789ABCDEF';
    for (final byte in bytes) {
      if (byte >= 0x61 && byte <= 0x7a ||
          byte >= 0x41 && byte <= 0x5a ||
          byte >= 0x30 && byte <= 0x39 ||
          byte == 0x2e || // .
          byte == 0x2d || // -
          byte == 0x2a || // *
          byte == 0x5f) {
        // _
        buffer.writeCharCode(byte);
      } else if (byte == 0x20) {
        buffer.write('+');
      } else {
        buffer.write('%');
        buffer.write(hex[byte >> 4 & 0xf]);
        buffer.write(hex[byte & 0xf]);
      }
    }
    return buffer.toString();
  }

  static int? _encodeOne(int unit) => _lookup(gbkEncodeTable, unit << 16);

  static int? _decodeOne(int gbk) => _lookup(gbkDecodeTable, gbk << 16);

  /// Four-byte linear index -> code point, or null for the unmapped holes.
  static int? _fourByteDecode(int index) {
    final ranges = gb18030FourByteRanges;
    var low = 0;
    var high = ranges.length ~/ 3 - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final base = mid * 3;
      final start = ranges[base];
      final length = ranges[base + 2];
      if (index < start) {
        high = mid - 1;
      } else if (index >= start + length) {
        low = mid + 1;
      } else {
        return ranges[base + 1] + (index - start);
      }
    }
    return null;
  }

  /// Entries are packed `(key << 16 | value)` and sorted by key; [probe]
  /// supplies the shifted key.
  static int? _lookup(List<int> entries, int probe) {
    var low = 0;
    var high = entries.length - 1;
    final key = probe & 0xffff0000;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final entry = entries[mid];
      final entryKey = entry & 0xffff0000;
      if (entryKey == key) return entry & 0xffff;
      if (entryKey < key) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return null;
  }
}

/// Convenience so callers can hand GBK strings straight to UTF-8 sinks.
const GbkCodec gbk = GbkCodec();

class GbkCodec extends Encoding {
  const GbkCodec();

  @override
  Converter<List<int>, String> get decoder => const _GbkDecoder();

  @override
  Converter<String, List<int>> get encoder => const _GbkEncoder();

  @override
  String get name => 'gbk';
}

class _GbkDecoder extends Converter<List<int>, String> {
  const _GbkDecoder();

  @override
  String convert(List<int> input) => Gbk.decode(input);
}

class _GbkEncoder extends Converter<String, List<int>> {
  const _GbkEncoder();

  @override
  List<int> convert(String input) => Gbk.tryEncode(input) ?? <int>[];
}
