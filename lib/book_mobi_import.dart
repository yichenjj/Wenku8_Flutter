import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'book_epub_writer.dart';

/// Pure-Dart Kindle/PalmDOC converter, mirroring the Android native
/// `libwenku_mobi` pipeline: MOBI 6 and KF8 records decompress (PalmDOC or
/// HUFF/CDIC), trailing entries trim per record, resources land in the EPUB,
/// and the failure messages match the Kotlin `convert()` status mapping.
///
/// Algorithms follow the KindleUnpack/libmobi semantics: the backwards-encoded
/// trailing entries, the multibyte overlap trim, and the HUFF/CDIC bitstream.
class BookMobiImport {
  static const _maxRawTextBytes = 512 * 1024 * 1024;
  static const _maxChapters = 10000;

  final Directory work;

  BookMobiImport(this.work);

  /// Converts [source] into an EPUB written to [output].
  void convert(File source, File output) {
    final Uint8List pdb;
    try {
      pdb = source.readAsBytesSync();
    } catch (_) {
      throw const FormatException('MOBI 文件损坏或格式不受支持');
    }
    final records = _PdbRecords(pdb);
    if (records.length < 2) {
      throw const FormatException('MOBI 文件损坏或格式不受支持');
    }
    final record0 = records[0];
    if (record0.length < 16) {
      throw const FormatException('MOBI 文件损坏或格式不受支持');
    }

    final compression = _u16(record0, 0);
    final textRecordCount = _u16(record0, 8);
    final encryption = _u16(record0, 12);
    if (textRecordCount <= 0) {
      throw const FormatException('MOBI 文件损坏或格式不受支持');
    }
    if (encryption != 0) {
      throw const FormatException('不支持受 DRM 保护的 Kindle 电子书');
    }

    final isMobi = record0.length >= 132 &&
        record0[16] == 0x4d &&
        record0[17] == 0x4f &&
        record0[18] == 0x42 &&
        record0[19] == 0x49; // 'MOBI'
    var textEncoding = 1252;
    var extraFlags = 0;
    var fullName = '';
    var author = '';
    var boundaryRecord = -1;
    _HuffCdic? huffman;
    if (isMobi) {
      final headerLength = _u32(record0, 20);
      if (headerLength < 4 || 16 + headerLength > record0.length) {
        throw const FormatException('MOBI 文件损坏或格式不受支持');
      }
      final mobiType = _u32(record0, 24);
      if (mobiType != 2 && mobiType != 3 && mobiType != 8) {
        throw const FormatException('MOBI 文件损坏或格式不受支持');
      }
      textEncoding = _u32(record0, 28);
      if (textEncoding != 65001 && textEncoding != 1252) {
        throw const FormatException('MOBI 文件损坏或格式不受支持');
      }
      final mobiVersion = _u32(record0, 104); // offset 0x68
      if (mobiVersion >= 5 && headerLength >= 0xe4) {
        extraFlags = _u32(record0, 16 + headerLength - 4);
      }
      final nameOffset = _u32(record0, 84); // 0x54
      final nameLength = _u32(record0, 88); // 0x58
      if (nameOffset > 0 &&
          nameLength > 0 &&
          nameOffset + nameLength <= record0.length) {
        fullName = _decode(
          record0.sublist(nameOffset, nameOffset + nameLength),
          textEncoding,
        ).trim();
      }
      final exthFlags = _u32(record0, 128); // 0x80
      if (exthFlags & 0x40 != 0) {
        final exth = _Exth(record0, 16 + headerLength, textEncoding);
        author = exth.string(100) ?? '';
        final title = exth.string(503);
        if (title != null && title.isNotEmpty) fullName = title;
        boundaryRecord = exth.intValue(116);
      }
      if (compression == 17480) {
        final huffOffset = _i32(record0, 112); // 0x70
        final huffCount = _i32(record0, 116); // 0x74
        if (huffOffset <= 0 ||
            huffCount < 2 ||
            huffOffset + huffCount > records.length) {
          throw const FormatException('MOBI 文件损坏或格式不受支持');
        }
        try {
          huffman = _HuffCdic([
            for (var i = 0; i < huffCount; i++) records[huffOffset + i],
          ]);
        } on FormatException {
          rethrow;
        } catch (_) {
          throw const FormatException('MOBI 文件损坏或格式不受支持');
        }
      }
    }
    if (compression != 1 && compression != 2 && compression != 17480) {
      throw const FormatException('MOBI 文件损坏或格式不受支持');
    }

    // Text records start after record 0 and run `textRecordCount` records.
    final trailerCount = _countTrailers(extraFlags);
    final multibyte = extraFlags & 1 != 0;
    final parts = BytesBuilder(copy: false);
    var rawBytes = 0;
    for (var i = 1; i <= textRecordCount; i++) {
      if (i >= records.length) {
        throw const FormatException('MOBI 文件损坏或格式不受支持');
      }
      final data = _trimTrailing(records[i], trailerCount, multibyte);
      rawBytes += data.length;
      if (rawBytes > _maxRawTextBytes) {
        throw const FormatException('MOBI 正文或资源超过大小限制');
      }
      parts.add(
        switch (compression) {
          1 => data,
          2 => _palmDoc(data),
          _ => Uint8List.fromList(huffman!.unpack(data)),
        },
      );
    }
    var html = _decode(parts.takeBytes(), textEncoding);

    // Resources live after the text block; recindex counts every resource
    // record in order, images and non-images alike (KindleUnpack semantics).
    final writer = BookEpubWriter(work, '');
    final resourceStart = textRecordCount + 1;
    final resourceEnd = boundaryRecord > 0
        ? boundaryRecord.clamp(resourceStart, records.length)
        : records.length;
    final resourceKeys = <String?>[];
    for (var i = resourceStart; i < resourceEnd; i++) {
      resourceKeys.add(_registerResource(records[i], writer));
    }

    html = _rewriteImages(html, resourceKeys, writer);
    html = _stripOuterWrapper(html);

    final stem = source.path
        .split(Platform.pathSeparator)
        .last
        .replaceFirst(RegExp(r'\.[^.]+$'), '');
    var title = fullName.trim().isNotEmpty ? fullName.trim() : stem;
    if (title.length > 2048) title = title.substring(0, 2048);
    writer
      ..title = title
      ..author = author;
    _buildChapters(html, writer);
    writer.write(output);
  }

  // ------------------------------------------------------- decompression

  static int _countTrailers(int flags) {
    var count = 0;
    while (flags > 1) {
      if (flags & 2 != 0) count++;
      flags >>= 1;
    }
    return count;
  }

  static Uint8List _trimTrailing(Uint8List data, int trailers, bool multibyte) {
    var end = data.length;
    for (var i = 0; i < trailers && end > 0; i++) {
      // Backwards-encoded variable-width integer in the last four bytes.
      var num = 0;
      for (var k = end >= 4 ? end - 4 : 0; k < end; k++) {
        final v = data[k];
        if (v & 0x80 != 0) num = 0;
        num = (num << 7) | (v & 0x7f);
      }
      if (num > end) num = end;
      end -= num;
    }
    if (multibyte && end > 0) {
      final num = (data[end - 1] & 3) + 1;
      end -= num > end ? end : num;
    }
    return data.length == end ? data : Uint8List.sublistView(data, 0, end);
  }

  static Uint8List _palmDoc(Uint8List input) {
    final bytes = <int>[];
    var p = 0;
    while (p < input.length) {
      final c = input[p];
      p++;
      if (c >= 1 && c <= 8) {
        for (var i = 0; i < c && p < input.length; i++) {
          bytes.add(input[p++]);
        }
      } else if (c < 128) {
        bytes.add(c);
      } else if (c >= 192) {
        bytes.add(0x20);
        bytes.add(c ^ 0x80);
      } else {
        if (p >= input.length) break;
        final pair = (c << 8) | input[p];
        p++;
        final distance = ((pair >> 3) & 0x7ff) + 1;
        final length = (pair & 7) + 3;
        final base = bytes.length - distance;
        for (var i = 0; i < length; i++) {
          bytes.add(bytes[base + i]);
        }
      }
    }
    return Uint8List.fromList(bytes);
  }

  static String _decode(Uint8List bytes, int textEncoding) {
    if (textEncoding == 65001) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    return String.fromCharCodes([
      for (final byte in bytes)
        byte < 0x80 || byte >= 0xa0 ? byte : (_cp1252[byte - 0x80] ?? byte),
    ]);
  }

  static const _cp1252 = <int?>[
    0x20ac, null, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021, //
    0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, null, 0x017d, null,
    null, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
    0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, null, 0x017e, 0x0178,
  ];

  // ----------------------------------------------------------- resources

  String? _registerResource(Uint8List data, BookEpubWriter writer) {
    final type = _imageType(data);
    if (type == null) return null;
    final key = 'rec-${writer.resourceCount}';
    try {
      writer.resource(key, type, data);
    } on FormatException {
      throw const FormatException('MOBI 正文或资源超过大小限制');
    }
    return key;
  }
  String? _imageType(Uint8List data) {
    if (data.length < 8) return null;
    if (data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff) return 'jpg';
    if (data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4e && data[3] == 0x47) {
      return 'png';
    }
    if (data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46) return 'gif';
    return null;
  }

  String _rewriteImages(
    String html,
    List<String?> resourceKeys,
    BookEpubWriter writer,
  ) {
    return html.replaceAllMapped(
      RegExp(
        r'<img\b[^>]*?recindex\s*=\s*"(\d+)"[^>]*?>',
        caseSensitive: false,
      ),
      (match) {
        final index = int.tryParse(match.group(1)!);
        if (index == null || index < 1 || index > resourceKeys.length) {
          return '';
        }
        final key = resourceKeys[index - 1];
        if (key == null) return '';
        return '<img src="resource:${writer.reference(key)}"/>';
      },
    );
  }

  // ------------------------------------------------------------ chapters

  String _stripOuterWrapper(String html) {
    final body = RegExp(
      r'<body\b[^>]*>(.*)</body>',
      dotAll: true,
      caseSensitive: false,
    ).firstMatch(html);
    if (body != null) return body.group(1)!;
    final htmlTag = RegExp(
      r'<html\b[^>]*>(.*)</html>',
      dotAll: true,
      caseSensitive: false,
    ).firstMatch(html);
    return htmlTag?.group(1) ?? html;
  }

  void _buildChapters(String html, BookEpubWriter writer) {
    final separator = RegExp(r'<mbp:pagebreak\s*/?>', caseSensitive: false);
    var parts = html.split(separator);
    if (parts.length == 1) {
      // No page breaks: fall back to major headings as chapter seams.
      parts = html.split(RegExp(r'(?=<h[1-3][\s>])', caseSensitive: false));
    }
    final usable = [
      for (final part in parts)
        if (part.trim().isNotEmpty) part.trim(),
    ];
    if (usable.isEmpty) {
      throw const FormatException('MOBI 文件损坏或格式不受支持');
    }
    // Bound the chapter count by folding extras into the last chapter.
    final fold = usable.length <= _maxChapters
        ? 1
        : (usable.length / _maxChapters).ceil();
    var index = 0;
    for (var start = 0; start < usable.length; start += fold) {
      index++;
      final end = (start + fold).clamp(start, usable.length);
      final fragment = usable.sublist(start, end).join('\n');
      final title = _fragmentTitle(fragment);
      writer
        ..heading(title.isEmpty ? '第 $index 章' : title)
        ..markup(fragment);
    }
  }
}

String _fragmentTitle(String fragment) {
  final match = RegExp(
    r'<h[1-6][^>]*>(.*?)</h[1-6]>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(fragment);
  if (match == null) return '';
  var title = match
      .group(1)!
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (title.length > 2048) title = title.substring(0, 2048);
  return title;
}

// ------------------------------------------------------------- PDB layer

class _PdbRecords {
  _PdbRecords(this.bytes) {
    if (bytes.length < 78) return;
    final count = _u16(bytes, 76);
    for (var i = 0; i < count; i++) {
      final entry = 78 + i * 8;
      if (entry + 4 > bytes.length) break;
      final start = _u32(bytes, entry);
      final end = i + 1 < count
          ? _u32(bytes, entry + 8)
          : bytes.length;
      if (start >= bytes.length || start >= end) {
        _records.add(Uint8List(0));
        continue;
      }
      _records.add(Uint8List.sublistView(bytes, start, end));
    }
  }

  final Uint8List bytes;
  final _records = <Uint8List>[];

  int get length => _records.length;

  Uint8List operator [](int index) =>
      index >= 0 && index < _records.length ? _records[index] : Uint8List(0);
}

int _u16(Uint8List data, int offset) => data[offset] << 8 | data[offset + 1];

int _u32(Uint8List data, int offset) => (data[offset] << 24 |
        data[offset + 1] << 16 |
        data[offset + 2] << 8 |
        data[offset + 3]) &
    0xffffffff;

int _i32(Uint8List data, int offset) =>
    data[offset] << 24 |
    data[offset + 1] << 16 |
    data[offset + 2] << 8 |
    data[offset + 3];

// -------------------------------------------------------------- EXTH

class _Exth {
  _Exth(this.data, int offset, int textEncoding) : _encoding = textEncoding {
    if (offset + 12 > data.length) return;
    if (data[offset] != 0x45 ||
        data[offset + 1] != 0x58 ||
        data[offset + 2] != 0x54 ||
        data[offset + 3] != 0x48) {
      return; // 'EXTH'
    }
    final length = _u32(data, offset + 4);
    final end = offset + length > data.length ? data.length : offset + length;
    var cursor = offset + 12;
    while (cursor + 8 <= end) {
      final type = _u32(data, cursor);
      final size = _u32(data, cursor + 4);
      if (size < 8 || cursor + size > end) break;
      _records[type] = Uint8List.sublistView(data, cursor + 8, cursor + size);
      cursor += size;
    }
  }

  final Uint8List data;
  final int _encoding;
  final _records = <int, Uint8List>{};

  String? string(int type) {
    final bytes = _records[type];
    if (bytes == null) return null;
    final value = BookMobiImport._decode(bytes, _encoding).trim();
    return value.isEmpty ? null : value;
  }

  int intValue(int type) {
    final bytes = _records[type];
    if (bytes == null || bytes.length < 4) return -1;
    return _u32(bytes, 0);
  }
}

// ------------------------------------------------------- HUFF/CDIC

class _HuffCdic {
  _HuffCdic(List<Uint8List> records) {
    final huff = records[0];
    if (huff.length < 24 ||
        huff[0] != 0x48 ||
        huff[1] != 0x55 ||
        huff[2] != 0x46 ||
        huff[3] != 0x46) {
      throw const FormatException('MOBI 文件损坏或格式不受支持');
    }
    final off1 = _u32(huff, 8);
    final off2 = _u32(huff, 12);
    if (off1 + 1024 > huff.length || off2 + 256 > huff.length) {
      throw const FormatException('MOBI 文件损坏或格式不受支持');
    }
    _dict1 = [
      for (var i = 0; i < 256; i++) _dict1Unpack(_u32(huff, off1 + i * 4)),
    ];
    final mincode = List<int>.filled(33, 0);
    final maxcode = List<int>.filled(33, 0);
    for (var codelen = 1; codelen <= 32; codelen++) {
      final minValue = _u32(huff, off2 + (codelen - 1) * 8);
      final maxValue = _u32(huff, off2 + (codelen - 1) * 8 + 4);
      mincode[codelen] = minValue << (32 - codelen);
      maxcode[codelen] = ((maxValue + 1) << (32 - codelen)) - 1;
    }
    _mincode = mincode;
    _maxcode = maxcode;

    for (final cdic in records.sublist(1)) {
      if (cdic.length < 20 ||
          cdic[0] != 0x43 ||
          cdic[1] != 0x44 ||
          cdic[2] != 0x49 ||
          cdic[3] != 0x43) {
        throw const FormatException('MOBI 文件损坏或格式不受支持');
      }
      final phrases = _u32(cdic, 8);
      final bits = _u32(cdic, 12);
      final remaining = phrases - _dictionary.length;
      final n = (1 << bits) < remaining ? (1 << bits) : remaining;
      for (var i = 0; i < n; i++) {
        final entry = _u16(cdic, 16 + i * 2);
        final length = entry & 0x7fff;
        if (18 + length > cdic.length) {
          throw const FormatException('MOBI 文件损坏或格式不受支持');
        }
        _dictionary.add((
          Uint8List.sublistView(cdic, 18, 18 + length),
          entry & 0x8000 != 0,
        ));
      }
    }
  }

  late List<(int, bool, int)> _dict1;
  late List<int> _mincode;
  late List<int> _maxcode;
  final _dictionary = <(Uint8List, bool)>[];

  static (int, bool, int) _dict1Unpack(int v) {
    final codelen = v & 0x1f;
    final term = v & 0x80 != 0;
    final maxcode = v >> 8;
    if (codelen == 0) {
      throw const FormatException('MOBI 文件损坏或格式不受支持');
    }
    if (codelen <= 8 && !term) {
      throw const FormatException('MOBI 文件损坏或格式不受支持');
    }
    return (codelen, term, ((maxcode + 1) << (32 - codelen)) - 1);
  }

  List<int> unpack(Uint8List data) {
    final out = <int>[];
    var bitsLeft = data.length * 8;
    final padded = BytesBuilder(copy: false);
    padded.add(data);
    padded.add(Uint8List(8));
    final bytes = padded.takeBytes();
    var pos = 0;
    var x = _u64(bytes, pos);
    var n = 32;
    while (true) {
      if (n <= 0) {
        pos += 4;
        if (pos + 8 > bytes.length) break;
        x = _u64(bytes, pos);
        n += 32;
      }
      final code = (x >> n) & 0xffffffff;

      var (codelen, term, maxcode) = _dict1[code >> 24];
      if (!term) {
        while (code < _mincode[codelen]) {
          codelen++;
          if (codelen > 32) {
            throw const FormatException('MOBI 文件损坏或格式不受支持');
          }
        }
        maxcode = _maxcode[codelen];
      }

      n -= codelen;
      bitsLeft -= codelen;
      if (bitsLeft < 0) break;

      final r = (maxcode - code) >> (32 - codelen);
      if (r < 0 || r >= _dictionary.length) {
        throw const FormatException('MOBI 文件损坏或格式不受支持');
      }
      var (slice, flag) = _dictionary[r];
      if (!flag) {
        _dictionary[r] = (slice, true);
        slice = Uint8List.fromList(unpack(slice));
        _dictionary[r] = (slice, true);
      }
      out.addAll(slice);
    }
    return out;
  }

  static int _u64(Uint8List data, int offset) =>
      data[offset] << 56 |
      data[offset + 1] << 48 |
      data[offset + 2] << 40 |
      data[offset + 3] << 32 |
      data[offset + 4] << 24 |
      data[offset + 5] << 16 |
      data[offset + 6] << 8 |
      data[offset + 7];
}
