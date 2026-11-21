import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'book_epub_writer.dart';

/// Pure-Dart PDF importer mirroring the Android PDFBox pipeline: per-page
/// heading, text extraction, and image fallback for scanned pages, wrapped
/// into the same EPUB the in-app reader consumes.
///
/// Supports classic xref tables, xref streams, object streams, Flate streams,
/// WinAnsi/Standard encodings, Differences with common glyph names, and
/// ToUnicode CMaps (including CID/Identity-H CJK fonts). Encrypted PDFs and
/// JPEG2000 imagery are rejected with the Android messages.
class BookPdfImport {
  static const _maxPages = 10000;
  static const _maxImagePixels = 24000000;

  final Directory work;

  BookPdfImport(this.work);

  /// Converts [source] into an EPUB written to [output].
  void convert(File source, File output) {
    final bytes = source.readAsBytesSync();
    final header = _ascii(bytes.sublist(0, bytes.length.clamp(0, 1024)));
    if (!header.contains('%PDF-')) {
      throw const FormatException('PDF 文件损坏或格式不受支持');
    }

    final document = _PdfDocument(bytes);
    if (document.encryptRef != null) {
      throw const FormatException('不支持加密或禁止内容提取的 PDF');
    }

    final pages = document.pageTree();
    if (pages.isEmpty || pages.length > _maxPages) {
      throw const FormatException('PDF 页数无效或超过 $_maxPages 页');
    }

    final info = document.info();
    final writer = BookEpubWriter(work, '');
    writer.title = info.title;
    writer.author = info.author;

    for (var index = 0; index < pages.length; index++) {
      writer.heading('第 ${index + 1} 页');
      final page = pages[index];
      final fonts = _pageFonts(document, page);
      final text = _pageText(document, page, fonts).trim();
      if (text.isNotEmpty) {
        for (final line in text.split('\n')) {
          writer.text(line);
        }
      } else {
        final images = _pageImages(document, page);
        if (images.isEmpty) {
          throw const FormatException(
            '此 PDF 页面无文本且使用了暂不支持的图片编码，请转换为 EPUB 后导入',
          );
        }
        for (final (bytes_, ext) in images) {
          final key = 'page-$index-${writer.resourceCount}';
          writer.resource(key, ext, bytes_);
          writer.image(key, 'width:100%');
        }
        continue;
      }
      // Pages with text may still carry inline artwork.
      for (final (bytes_, ext) in _pageImages(document, page)) {
        final key = 'page-$index-${writer.resourceCount}';
        writer.resource(key, ext, bytes_);
        writer.image(key, 'width:100%');
      }
    }
    writer.write(output);
  }

  // ---------------------------------------------------------------- text

  Map<String, _PdfFont> _pageFonts(_PdfDocument document, _PdfDict page) {
    final resources = _resourcesOf(document, page);
    final fontsDict = resources?.dict('Font');
    final fonts = <String, _PdfFont>{};
    if (fontsDict == null) return fonts;
    fontsDict.entries.forEach((key, value) {
      if (value is! _PdfRef) return;
      final fontDict = document.deref(value);
      if (fontDict != null) fonts[key] = _PdfFont(document, fontDict);
    });
    return fonts;
  }

  String _pageText(
    _PdfDocument document,
    _PdfDict page,
    Map<String, _PdfFont> fonts,
  ) {
    final content = document.contentStream(page);
    if (content.isEmpty) return '';
    final lines = <String>[];
    final line = StringBuffer();
    var font = _PdfFont.none();
    void flush() {
      final value = line.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      if (value.isNotEmpty) lines.add(value);
      line.clear();
    }

    final tokens = _Tokenizer(content).all();
    var pending = <Object?>[];
    for (final token in tokens) {
      if (token is! _Keyword) {
        pending.add(token);
        continue;
      }
      switch (token.value) {
        case 'BT' || '[' || ']' || '<<' || '>>':
          pending.clear();
        case 'ET':
          flush();
          pending.clear();
        case 'Tf':
          final name = pending.whereType<_PdfName>().lastOrNull;
          font = name == null
              ? _PdfFont.none()
              : (fonts[name.value] ?? _PdfFont.none());
          pending.clear();
        case 'Td' || 'TD' || 'T*' || 'Tm':
          flush();
          pending.clear();
        case "'":
          flush();
          _showText(pending, font, line);
          pending.clear();
        case '"':
          flush();
          if (pending.isNotEmpty) _showText([pending.last], font, line);
          pending.clear();
        case 'Tj':
          _showText(pending, font, line);
          pending.clear();
        case 'TJ':
          final arrays = pending.whereType<List<Object?>>().toList();
          if (arrays.isNotEmpty) _showTj(arrays.last, font, line);
          pending.clear();
        default:
          pending.clear();
      }
      if (pending.length > 64) pending.clear();
    }
    flush();
    return lines.join('\n');
  }

  void _showText(List<Object?> operands, _PdfFont font, StringBuffer line) {
    for (final operand in operands) {
      if (operand is Uint8List) {
        line.write(font.decode(operand));
      }
    }
  }

  void _showTj(List<Object?> array, _PdfFont font, StringBuffer line) {
    for (final element in array) {
      if (element is Uint8List) {
        line.write(font.decode(element));
      } else if (element is num) {
        // A large negative kern means an explicit space in most layouts.
        if (element < -120) line.write(' ');
      }
    }
  }

  // -------------------------------------------------------------- images

  List<(Uint8List, String)> _pageImages(_PdfDocument document, _PdfDict page) {
    final resources = _resourcesOf(document, page);
    final xobjects = resources?.dict('XObject');
    final images = <(Uint8List, String)>[];
    if (xobjects == null) return images;
    xobjects.entries.values.whereType<_PdfRef>().forEach((ref) {
      final dict = document.deref(ref);
      if (dict == null || !dict.isImage) return;
      final filter = dict.filter;
      if (filter.contains('JPXDecode')) {
        throw const FormatException('此 PDF 使用 JPEG2000 图片，暂不支持；请转换为 EPUB 后导入');
      }
      final width = dict.number('Width') ?? dict.number('W') ?? 0;
      final height = dict.number('Height') ?? dict.number('H') ?? 0;
      if (width <= 0 || height <= 0) return;
      if (width * height > _maxImagePixels) {
        throw const FormatException('PDF 中的图片尺寸过大，请压缩原书后导入');
      }
      final raw = dict.streamBytes(document);
      if (raw.isEmpty) return;
      if (filter.contains('DCTDecode')) {
        images.add((raw, 'jpg'));
        return;
      }
      if (filter.contains('FlateDecode') || filter.isEmpty) {
        final png = _pngFromSamples(document, dict, width.round(), height.round(), raw);
        if (png != null) images.add((png, 'png'));
      }
    });
    return images;
  }

  _PdfDict? _resourcesOf(_PdfDocument document, _PdfDict page) {
    var node = page;
    while (true) {
      final resources = node.dictOrRef('Resources', document);
      if (resources != null) return resources;
      final parent = node.dictOrRef('Parent', document);
      if (parent == null) return null;
      node = parent;
    }
  }
}

// ---------------------------------------------------------------- fonts

class _PdfFont {
  _PdfFont(this.document, this.dict)
      : _twoByte = dict?.name('Subtype') == 'Type0',
        _toUnicode = _CMap.parse(_PdfFont._cmapBytes(document, dict)),
        _encoding = _byteTable(document, dict);

  _PdfFont.none()
      : document = null,
        dict = null,
        _twoByte = false,
        _toUnicode = null,
        _encoding = _PdfFont._latin1Table();

  final _PdfDocument? document;
  final _PdfDict? dict;
  final bool _twoByte;
  final _CMap? _toUnicode;
  final List<String?> _encoding;

  static Uint8List? _cmapBytes(_PdfDocument? document, _PdfDict? dict) {
    if (document == null || dict == null) return null;
    final ref = dict.dictOrRef('ToUnicode', document);
    if (ref == null) return null;
    return ref.streamBytes(document);
  }

  static List<String?> _byteTable(_PdfDocument? document, _PdfDict? dict) {
    final table = List<String?>.filled(256, null);
    for (var i = 0x20; i < 0x7f; i++) {
      table[i] = String.fromCharCode(i);
    }
    if (dict == null) return table;
    if (dict.encodingName != 'StandardEncoding') {
      for (var i = 0x80; i < 0x100; i++) {
        table[i] = _winAnsiSpecial(i);
      }
    }
    if (document != null) {
      for (final (code, name) in dict.differences(document)) {
        table[code] = _glyphName(name);
      }
    }
    return table;
  }

  static String? _winAnsiSpecial(int byte) {
    const specials = <int, int>{
      0x80: 0x20ac, 0x82: 0x201a, 0x83: 0x0192, 0x84: 0x201e,
      0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02c6,
      0x89: 0x2030, 0x8a: 0x0160, 0x8b: 0x2039, 0x8c: 0x0152,
      0x8e: 0x017d, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201c,
      0x94: 0x201d, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
      0x98: 0x02dc, 0x99: 0x2122, 0x9a: 0x0161, 0x9b: 0x203a,
      0x9c: 0x0153, 0x9e: 0x017e, 0x9f: 0x0178,
    };
    final special = specials[byte];
    return special != null
        ? String.fromCharCode(special)
        : String.fromCharCode(byte);
  }

  String decode(Uint8List bytes) {
    final cmap = _toUnicode;
    if (cmap != null) {
      final width = _twoByte ? 2 : 1;
      final out = StringBuffer();
      for (var i = 0; i + width <= bytes.length; i += width) {
        final code = width == 2 ? bytes[i] << 8 | bytes[i + 1] : bytes[i];
        final mapped = cmap.lookup(code);
        if (mapped != null && mapped != 0xffff) out.writeCharCode(mapped);
      }
      return out.toString();
    }
    if (_twoByte) {
      // CID fonts without ToUnicode cannot be decoded; drop the run instead
      // of emitting mojibake.
      return '';
    }
    return [
      for (final byte in bytes)
        if ((byte >= 0x20 && byte < 0x7f) ||
            (byte >= 0x80 && _encoding[byte] != null))
          _encoding[byte] ?? '',
    ].join();
  }

  static String? _glyphName(String name) {
    final uni = RegExp(r'^u(?:ni)?([0-9A-Fa-f]{4,6})$').firstMatch(name);
    if (uni != null) {
      final value = int.parse(uni.group(1)!, radix: 16);
      if (value <= 0x10ffff) return String.fromCharCode(value);
    }
    return _glyphNames[name];
  }

  static const _glyphNames = <String, String>{
    'space': ' ', 'exclam': '!', 'quotedbl': '"', 'numbersign': '#',
    'dollar': r'$', 'percent': '%', 'ampersand': '&', 'quotesingle': "'",
    'parenleft': '(', 'parenright': ')', 'asterisk': '*', 'plus': '+',
    'comma': ',', 'hyphen': '-', 'period': '.', 'slash': '/',
    'colon': ':', 'semicolon': ';', 'less': '<', 'equal': '=',
    'greater': '>', 'question': '?', 'at': '@', 'bracketleft': '[',
    'backslash': r'\', 'bracketright': ']', 'asciicircum': '^',
    'underscore': '_', 'grave': '`', 'braceleft': '{', 'bar': '|',
    'braceright': '}', 'asciitilde': '~', 'quoteright': '\u2019',
    'quoteleft': '\u2018', 'quotedblleft': '\u201c',
    'quotedblright': '\u201d', 'endash': '\u2013', 'emdash': '\u2014',
    'ellipsis': '\u2026', 'bullet': '\u2022', 'exclamdown': '\u00a1',
    'questiondown': '\u00bf', 'cent': '\u00a2', 'sterling': '\u00a3',
    'yen': '\u00a5', 'copyright': '\u00a9', 'registered': '\u00ae',
    'degree': '\u00b0', 'plusminus': '\u00b1', 'multiply': '\u00d7',
    'divide': '\u00f7',
    // CJK punctuation and full-width forms used by Differences arrays.
    'uni3000': '\u3000', 'uniFF01': '\uff01', 'uniFF0C': '\uff0c',
    'uniFF1B': '\uff1b', 'uniFF1A': '\uff1a', 'uniFF1F': '\uff1f',
    'uni3001': '\u3001', 'uni3002': '\u3002',
  };

  static List<String?> _latin1Table() => List<String?>.generate(
      256, (i) => i >= 0x20 ? String.fromCharCode(i) : null);
}

class _CMap {
  _CMap._(this._single, this._ranges);

  final Map<int, int> _single;
  final List<(int, int, int)> _ranges;

  static _CMap? parse(Uint8List? bytes) {
    if (bytes == null) return null;
    final text = latin1.decode(bytes, allowInvalid: true);
    final single = <int, int>{};
    final ranges = <(int, int, int)>[];
    var mode = '';
    for (final raw in text.split(RegExp(r'[\r\n]+'))) {
      final line = raw.trim();
      if (line.startsWith('beginbfchar')) {
        mode = 'char';
      } else if (line.startsWith('beginbfrange')) {
        mode = 'range';
      } else if (line.startsWith('endbfchar') ||
          line.startsWith('endbfrange')) {
        mode = '';
      } else if (mode == 'char' && line.startsWith('<')) {
        final match = RegExp(r'^<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>')
            .firstMatch(line);
        if (match != null) {
          single[int.parse(match.group(1)!, radix: 16)] =
              int.parse(match.group(2)!, radix: 16);
        }
      } else if (mode == 'range' && line.startsWith('<')) {
        final triple = RegExp(
          r'^<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>',
        ).firstMatch(line);
        final listForm = RegExp(
          r'^<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*\[(.*)\]$',
          dotAll: true,
        ).firstMatch(line);
        if (triple != null) {
          ranges.add((
            int.parse(triple.group(1)!, radix: 16),
            int.parse(triple.group(2)!, radix: 16),
            int.parse(triple.group(3)!, radix: 16),
          ));
        } else if (listForm != null) {
          final start = int.parse(listForm.group(1)!, radix: 16);
          final targets = RegExp(r'<([0-9A-Fa-f]+)>')
              .allMatches(listForm.group(3)!)
              .map((m) => int.parse(m.group(1)!, radix: 16))
              .toList();
          for (var i = 0; i < targets.length; i++) {
            single[start + i] = targets[i];
          }
        }
      }
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    if (single.isEmpty && ranges.isEmpty) return null;
    return _CMap._(single, ranges);
  }

  int? lookup(int code) {
    final direct = _single[code];
    if (direct != null) return direct;
    var low = 0;
    var high = _ranges.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final (start, end, target) = _ranges[mid];
      if (code < start) {
        high = mid - 1;
      } else if (code > end) {
        low = mid + 1;
      } else {
        return target + (code - start);
      }
    }
    return null;
  }
}

// ---------------------------------------------------------- PNG encoder

/// Minimal truecolor PNG writer for FlateDecode image samples.
Uint8List? _pngFromSamples(
  _PdfDocument document,
  _PdfDict dict,
  int width,
  int height,
  Uint8List compressed,
) {
  Uint8List samples;
  try {
    samples = Uint8List.fromList(ZLibDecoder().convert(compressed));
  } catch (_) {
    return null;
  }
  final components = _componentsOf(document, dict);
  final bits = dict.number('BitsPerComponent') ?? 8;
  if (bits != 8 || components == null || components < 1 || components > 4) {
    return null;
  }
  final palette = _paletteOf(document, dict);
  final params = dict.decodeParms();
  final stride = width * components;
  if (samples.length < height * stride) return null;

  final decoded = _undoPredictor(samples, width, height, components, params);
  if (decoded == null) return null;

  final rgb = Uint8List(width * height * 3);
  for (var pixel = 0; pixel < width * height; pixel++) {
    final base = pixel * components;
    final out = pixel * 3;
    switch (components) {
      case 1:
        final value = palette != null && palette.length > decoded[base] * 3 + 2
            ? palette[decoded[base] * 3]
            : decoded[base];
        rgb[out] = rgb[out + 1] = rgb[out + 2] = value;
      case 3:
        if (palette != null && palette.length > decoded[base] * 3 + 2) {
          final index = decoded[base];
          rgb[out] = palette[index * 3];
          rgb[out + 1] = palette[index * 3 + 1];
          rgb[out + 2] = palette[index * 3 + 2];
        } else {
          rgb[out] = decoded[base];
          rgb[out + 1] = decoded[base + 1];
          rgb[out + 2] = decoded[base + 2];
        }
      case 4:
        final c = decoded[base];
        final m = decoded[base + 1];
        final y = decoded[base + 2];
        final k = decoded[base + 3];
        rgb[out] = 255 - (c + k).clamp(0, 255);
        rgb[out + 1] = 255 - (m + k).clamp(0, 255);
        rgb[out + 2] = 255 - (y + k).clamp(0, 255);
    }
  }
  return _pngEncode(width, height, rgb);
}

int? _componentsOf(_PdfDocument document, _PdfDict dict) {
  final space = dict.entries['ColorSpace'];
  if (space is _PdfName) {
    return switch (space.value) {
      'DeviceGray' || 'G' => 1,
      'DeviceRGB' || 'RGB' => 3,
      'DeviceCMYK' || 'CMYK' => 4,
      _ => null,
    };
  }
  if (space is List<Object?>) {
    final head = space.firstOrNull;
    if (head is _PdfName && head.value == 'ICCBased' && space.length > 1) {
      final ref = space[1];
      if (ref is _PdfRef) {
        final n = document.deref(ref)?.number('N');
        if (n != null) return n.round();
      }
    }
    if (head is _PdfName && head.value == 'Indexed') return 1;
  }
  return null;
}

Uint8List? _paletteOf(_PdfDocument document, _PdfDict dict) {
  final space = dict.entries['ColorSpace'];
  if (space is! List<Object?> || space.isEmpty) return null;
  final head = space.firstOrNull;
  if (head is! _PdfName || head.value != 'Indexed' || space.length < 3) {
    return null;
  }
  final lookup = space[2];
  if (lookup is Uint8List) return lookup;
  if (lookup is _PdfRef) {
    final stream = document.deref(lookup);
    if (stream != null) return stream.streamBytes(document);
  }
  return null;
}

Uint8List? _undoPredictor(
  Uint8List data,
  int width,
  int height,
  int components,
  _PdfDict? params,
) {
  final predictor = params?.number('Predictor') ?? 1;
  final colors = params?.number('Colors')?.round() ?? components;
  final bpc = params?.number('BitsPerComponent')?.round() ?? 8;
  if (bpc != 8) return null;
  if (predictor <= 1) return data;
  final bpp = colors;
  final stride = width * components;
  if (predictor == 2) {
    final out = Uint8List(data.length);
    for (var row = 0; row < height; row++) {
      final base = row * stride;
      for (var i = 0; i < stride; i++) {
        final left = i >= colors ? out[base + i - colors] : 0;
        out[base + i] = (data[base + i] + left) & 0xff;
      }
    }
    return out;
  }
  if (predictor < 10 || predictor > 15) return null;
  if (data.length < height * (stride + 1)) return null;
  final out = Uint8List(height * stride);
  for (var row = 0; row < height; row++) {
    final filter = data[row * (stride + 1)];
    final source = row * (stride + 1) + 1;
    final base = row * stride;
    for (var i = 0; i < stride; i++) {
      final raw = data[source + i];
      final left = i >= bpp ? out[base + i - bpp] : 0;
      final up = row > 0 ? out[base + i - stride] : 0;
      final upperLeft = row > 0 && i >= bpp ? out[base + i - stride - bpp] : 0;
      int value;
      switch (filter) {
        case 0:
          value = raw;
        case 1:
          value = raw + left;
        case 2:
          value = raw + up;
        case 3:
          value = raw + ((left + up) >> 1);
        case 4:
          final p = left + up - upperLeft;
          final pa = (p - left).abs();
          final pb = (p - up).abs();
          final pc = (p - upperLeft).abs();
          value = raw +
              (pa <= pb && pa <= pc
                  ? left
                  : pb <= pc
                      ? up
                      : upperLeft);
        default:
          return null;
      }
      out[base + i] = value & 0xff;
    }
  }
  return out;
}

Uint8List _pngEncode(int width, int height, Uint8List rgb) {
  List<int> chunk(String type, List<int> body) {
    final out = BytesBuilder();
    out.add(_u32be(body.length));
    out.add(ascii.encode(type));
    out.add(body);
    out.add(_u32be(_crc32([...ascii.encode(type), ...body])));
    return out.takeBytes();
  }

  final ihdr = BytesBuilder();
  ihdr.add(_u32be(width));
  ihdr.add(_u32be(height));
  ihdr.add([8, 2, 0, 0, 0]);

  final raw = BytesBuilder();
  for (var row = 0; row < height; row++) {
    raw.addByte(0);
    raw.add(rgb.sublist(row * width * 3, (row + 1) * width * 3));
  }
  final compressed = ZLibEncoder().convert(raw.takeBytes());

  final out = BytesBuilder();
  out.add([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  out.add(chunk('IHDR', ihdr.takeBytes()));
  out.add(chunk('IDAT', compressed));
  out.add(chunk('IEND', const []));
  return out.takeBytes();
}

Uint8List _u32be(int value) => Uint8List.fromList([
      value >> 24 & 0xff,
      value >> 16 & 0xff,
      value >> 8 & 0xff,
      value & 0xff,
    ]);

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >> 8);
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

// --------------------------------------------------------- token model

class _PdfRef {
  const _PdfRef(this.number, this.generation);
  final int number;
  final int generation;
}

class _PdfName {
  const _PdfName(this.value);
  final String value;
}

/// Keywords: structure delimiters and operators.
class _Keyword {
  const _Keyword(this.value);
  final String value;
}

class _PdfInfo {
  String title = '';
  String author = '';
}

class _PdfDict {
  _PdfDict(this.entries, this.stream);

  final Map<String, Object?> entries;
  Uint8List? stream;

  /// The stream's transfer encodings, taken from the Filter entry.
  List<String> get filter {
    final value = entries['Filter'];
    if (value is _PdfName) return [value.value];
    if (value is List<Object?>) {
      return [
        for (final item in value)
          if (item is _PdfName) item.value,
      ];
    }
    return const [];
  }

  int? get streamLength {
    final value = entries['Length'];
    return value is num ? value.round() : null;
  }

  bool get isImage => name('Subtype') == 'Image';

  String? name(String key) {
    final value = entries[key];
    return value is _PdfName ? value.value : null;
  }

  num? number(String key) {
    final value = entries[key];
    return value is num ? value : null;
  }

  String get encodingName => name('Encoding') ?? 'StandardEncoding';

  List<(int, String)> differences(_PdfDocument document) {
    final value = entries['Encoding'];
    _PdfDict? dict;
    if (value is _PdfDict) {
      dict = value;
    } else if (value is _PdfRef) {
      dict = document.deref(value);
    }
    if (dict == null) return const [];
    final array = dict.entries['Differences'];
    if (array is! List<Object?>) return const [];
    var code = 0;
    final result = <(int, String)>[];
    for (final item in array) {
      if (item is num) {
        code = item.round();
      } else if (item is _PdfName) {
        result.add((code, item.value));
        code++;
      }
    }
    return result;
  }

  _PdfDict? dict(String key) {
    final value = entries[key];
    return value is _PdfDict ? value : null;
  }

  _PdfDict? dictOrRef(String key, _PdfDocument document) {
    final value = entries[key];
    if (value is _PdfDict) return value;
    if (value is _PdfRef) return document.deref(value);
    return null;
  }

  Uint8List streamBytes(_PdfDocument document) {
    final raw = stream;
    if (raw == null) return Uint8List(0);
    var data = raw;
    for (final f in filter) {
      if (f == 'FlateDecode') {
        try {
          data = Uint8List.fromList(ZLibDecoder().convert(data));
        } catch (_) {
          return Uint8List(0);
        }
      } else {
        // DCTDecode and friends stop here: only the outermost conversion
        // matters for extraction.
        break;
      }
    }
    return data;
  }

  _PdfDict? decodeParms() {
    final value = entries['DecodeParms'];
    if (value is _PdfDict) return value;
    if (value is List<Object?>) {
      for (final item in value) {
        if (item is _PdfDict) return item;
      }
    }
    return null;
  }
}

// ---------------------------------------------------------- document

/// Object lookup: value map keyed by object number. Entries hold either the
/// object body bytes (object streams) or the file offset of "N G obj".
class _PdfDocument {
  _PdfDocument(this.bytes) {
    _indexObjects();
    _parseXref();
  }

  final Uint8List bytes;
  final _locations = <int, Object>{};
  final _cache = <int, _PdfDict?>{};
  _PdfRef? _rootRef;
  _PdfRef? _infoRef;
  _PdfRef? _encryptRef;

  _PdfRef? get encryptRef => _encryptRef;

  // ------------------------------------------------------------ indexing

  void _indexObjects() {
    // Brute-force header scan for "N G obj" as a fallback index.
    const marker = [0x6f, 0x62, 0x6a]; // obj
    var search = 0;
    while (true) {
      final at = _find(bytes, marker, search);
      if (at < 0) break;
      search = at + 3;
      var cursor = at - 1;
      while (cursor >= 0 && _isWhitespace(bytes[cursor])) {
        cursor--;
      }
      final gen = _reverseNumber(bytes, cursor);
      if (gen == null) continue;
      cursor = gen.$2;
      while (cursor >= 0 && _isWhitespace(bytes[cursor])) {
        cursor--;
      }
      final number = _reverseNumber(bytes, cursor);
      if (number == null) continue;
      _locations.putIfAbsent(number.$1, () => at + 3);
    }
  }

  (int, int)? _reverseNumber(Uint8List data, int end) {
    var value = 0;
    var factor = 1;
    var cursor = end;
    var any = false;
    while (cursor >= 0 && bytes[cursor] >= 0x30 && bytes[cursor] <= 0x39) {
      value += (bytes[cursor] - 0x30) * factor;
      factor *= 10;
      any = true;
      cursor--;
    }
    return any ? (value, cursor) : null;
  }

  static int _find(Uint8List data, List<int> needle, int from) {
    outer:
    for (var i = from; i + needle.length <= data.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (data[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  static bool _isWhitespace(int byte) =>
      byte == 0 ||
      byte == 9 ||
      byte == 10 ||
      byte == 12 ||
      byte == 13 ||
      byte == 32;

  void _parseXref() {
    final tailText = _ascii(
      bytes.sublist(bytes.length > 4096 ? bytes.length - 4096 : 0),
    );
    final startMatch =
        RegExp(r'startxref\s+(\d+)').allMatches(tailText).lastOrNull;
    if (startMatch != null) {
      _walkXref(int.parse(startMatch.group(1)!), 0);
    }
    _readKeywordTrailers();
    if (_rootRef == null) {
      // Fallback: scan indexed objects for the catalog.
      for (final entry in _locations.entries) {
        final dict = _readAt(entry.value);
        if (dict?.name('Type') == 'Catalog') {
          _rootRef = _PdfRef(entry.key, 0);
          break;
        }
      }
    }
    if (_encryptRef == null) {
      for (final entry in _locations.entries) {
        final dict = _readAt(entry.value);
        if (dict?.name('Type') == 'Encrypt') {
          _encryptRef = _PdfRef(entry.key, 0);
          break;
        }
      }
    }
  }

  void _walkXref(int offset, int depth) {
    if (offset <= 0 || offset >= bytes.length || depth > 32) return;
    final window = _ascii(
      Uint8List.sublistView(bytes, offset, (offset + 8).clamp(0, bytes.length)),
    );
    if (window.startsWith('xref')) {
      _walkClassicXref(offset, depth);
      return;
    }
    final dict = _readAt(offset);
    if (dict == null) return;
    final encrypt = dict.entries['Encrypt'];
    if (encrypt is _PdfRef) _encryptRef ??= encrypt;
    final info = dict.entries['Info'];
    if (info is _PdfRef) _infoRef ??= info;
    final root = dict.entries['Root'];
    if (root is _PdfRef) _rootRef ??= root;

    final compressed = dict.stream;
    if (dict.entries.containsKey('W') && compressed != null) {
      _applyXrefStream(dict, compressed);
    }
    final prev = dict.number('Prev');
    if (prev != null) {
      _walkXref(prev.round(), depth + 1);
      return;
    }
    // Classic 'xref' table: the keyword trailer chain ends here, but older
    // files may still have an earlier xref table with Prev-like /XRefStm.
    final xrefStm = dict.entries['XRefStm'];
    if (xrefStm is num) {
      _walkXref(xrefStm.round(), depth + 1);
    }
  }

  /// Classic free-format xref table: sections of "start count" plus 20-byte
  /// entries, then a trailer dictionary.
  void _walkClassicXref(int offset, int depth) {
    var cursor = offset + 4; // past 'xref'
    final text = _ascii(bytes);
    while (true) {
      while (cursor < bytes.length && _isWhitespace(bytes[cursor])) {
        cursor++;
      }
      final lineEnd = text.indexOf('\n', cursor);
      if (lineEnd < 0) return;
      final line = text.substring(cursor, lineEnd).trim();
      final section = RegExp(r'^(\d+)\s+(\d+)$').firstMatch(line);
      if (section == null) break;
      final start = int.parse(section.group(1)!);
      final count = int.parse(section.group(2)!);
      cursor = lineEnd + 1;
      for (var i = 0; i < count; i++) {
        if (cursor + 20 > text.length) return;
        final entry = text.substring(cursor, cursor + 20);
        cursor += 20;
        if (!entry.endsWith('n')) continue;
        final objectOffset = int.tryParse(entry.substring(0, 10).trim());
        if (objectOffset != null && objectOffset > 0) {
          _locations.putIfAbsent(start + i, () => objectOffset);
        }
      }
    }
    final dictAt = text.indexOf('trailer', cursor);
    if (dictAt >= 0) {
      final trailer = _PdfReader(
        Uint8List.sublistView(bytes, dictAt + 7),
      )._peekDict();
      if (trailer != null) {
        final encrypt = trailer.entries['Encrypt'];
        if (encrypt is _PdfRef) _encryptRef ??= encrypt;
        final info = trailer.entries['Info'];
        if (info is _PdfRef) _infoRef ??= info;
        final root = trailer.entries['Root'];
        if (root is _PdfRef) _rootRef ??= root;
      }
    }
    final trailer = RegExp(r'/Prev\s+(\d+)').allMatches(
      text.substring(cursor, (cursor + 2048).clamp(0, text.length)),
    );
    for (final match in trailer) {
      _walkXref(int.parse(match.group(1)!), depth + 1);
    }
  }

  void _applyXrefStream(_PdfDict dict, Uint8List compressed) {
    Uint8List data;
    try {
      data = Uint8List.fromList(ZLibDecoder().convert(compressed));
    } catch (_) {
      return;
    }
    final widths = dict.entries['W'];
    if (widths is! List<Object?>) return;
    final w = [
      for (final item in widths)
        if (item is num) item.round(),
    ];
    if (w.length != 3) return;
    final entrySize = w[0] + w[1] + w[2];
    final index = dict.entries['Index'];
    final sections = <(int, int)>[];
    if (index is List<Object?>) {
      for (var i = 0; i + 1 < index.length; i += 2) {
        if (index[i] is num && index[i + 1] is num) {
          sections.add((
            (index[i] as num).round(),
            (index[i + 1] as num).round(),
          ));
        }
      }
    } else {
      sections.add((0, dict.number('Size')?.round() ?? 0));
    }
    int field(int offset, int width) {
      var value = 0;
      for (var i = 0; i < width; i++) {
        if (offset + i < data.length) value = value << 8 | data[offset + i];
      }
      return value;
    }

    var cursor = 0;
    for (final (start, count) in sections) {
      for (var i = 0; i < count; i++) {
        if (cursor + entrySize > data.length) return;
        final type = w[0] == 0 ? 1 : field(cursor, w[0]);
        final a = w[1] == 0 ? 0 : field(cursor + w[0], w[1]);
        final b = w[2] == 0 ? 0 : field(cursor + w[0] + w[1], w[2]);
        cursor += entrySize;
        if (a <= 0) continue;
        if (type == 1) {
          _locations.putIfAbsent(start + i, () => a);
        } else if (type == 2) {
          _locations[start + i] = _ObjStmEntry(a, b);
        }
      }
    }
  }

  void _readKeywordTrailers() {
    final text = _ascii(bytes);
    var search = 0;
    while (true) {
      final at = text.indexOf('trailer', search);
      if (at < 0) break;
      search = at + 7;
      final dict = _PdfReader(
        Uint8List.sublistView(bytes, (at + 7).clamp(0, bytes.length)),
      )._peekDict();
      if (dict == null) continue;
      final encrypt = dict.entries['Encrypt'];
      if (encrypt is _PdfRef) _encryptRef ??= encrypt;
      final info = dict.entries['Info'];
      if (info is _PdfRef) _infoRef ??= info;
      final root = dict.entries['Root'];
      if (root is _PdfRef) _rootRef ??= root;
    }
  }

  // ------------------------------------------------------------- reading

  Uint8List? _bodyBytes(Object location) {
    if (location is Uint8List) return location;
    if (location is _ObjStmEntry) return null;
    final offset = location as int;
    final end = _find(bytes, [0x65, 0x6e, 0x64, 0x6f, 0x62, 0x6a], offset); // endobj
    return Uint8List.sublistView(
      bytes,
      offset,
      (end < 0 ? bytes.length : end).clamp(offset, bytes.length),
    );
  }

  _PdfDict? _readAt(Object location) {
    final body = _bodyBytes(location);
    if (body == null) return null;
    return _PdfReader(body).parseObject();
  }

  /// Loads an object stream's inner bodies and registers them as direct
  /// object bodies, so later lookups skip the stream layer.
  Map<int, Uint8List>? _objectStreamBodies(int streamNumber) {
    final location = _locations[streamNumber];
    if (location == null || location is _ObjStmEntry) return null;
    final dict = _readAt(location);
    if (dict == null || dict.name('Type') != 'ObjStm') return null;
    final count = dict.number('N')?.round() ?? 0;
    final first = dict.number('First')?.round() ?? 0;
    final data = dict.streamBytes(this);
    if (data.isEmpty || count == 0) return null;
    final tokens = _Tokenizer(data).all();
    final pairs = <(int, int)>[];
    for (var i = 0; i + 1 < tokens.length && pairs.length < count; i += 2) {
      if (tokens[i] is num && tokens[i + 1] is num) {
        pairs.add(((tokens[i] as num).round(), (tokens[i + 1] as num).round()));
      }
    }
    final bodies = <int, Uint8List>{};
    for (var i = 0; i < pairs.length; i++) {
      final (objectNumber, offset) = pairs[i];
      final start = first + offset;
      final end = i + 1 < pairs.length
          ? (first + pairs[i + 1].$2).clamp(start, data.length)
          : data.length;
      if (start >= data.length || end <= start) continue;
      bodies[objectNumber] = Uint8List.sublistView(data, start, end);
      _locations.putIfAbsent(
        objectNumber,
        () => Uint8List.sublistView(data, start, end),
      );
    }
    return bodies;
  }

  _PdfDict? deref(_PdfRef ref) {
    if (_cache.containsKey(ref.number)) return _cache[ref.number];
    _PdfDict? result;
    final location = _locations[ref.number];
    if (location is _ObjStmEntry) {
      final bodies = _objectStreamBodies(location.streamNumber);
      final body = bodies?[location.index];
      result = body == null ? null : _PdfReader(body).parseObject();
    } else if (location != null) {
      result = _readAt(location);
    } else {
      result = _scanForObject(ref.number);
    }
    return _cache[ref.number] = result;
  }

  _PdfDict? _scanForObject(int number) {
    final text = _ascii(bytes);
    final header = '$number 0 obj';
    var search = 0;
    while (true) {
      final at = text.indexOf(header, search);
      if (at < 0) break;
      search = at + header.length;
      final end = _find(
        bytes,
        [0x65, 0x6e, 0x64, 0x6f, 0x62, 0x6a],
        at + header.length,
      );
      final body = Uint8List.sublistView(
        bytes,
        at + header.length,
        (end < 0 ? bytes.length : end).clamp(at + header.length, bytes.length),
      );
      final dict = _PdfReader(body).parseObject();
      if (dict != null) {
        _locations.putIfAbsent(number, () => body);
        return dict;
      }
    }
    return null;
  }

  List<_PdfDict> pageTree() {
    final catalog = _rootRef != null ? deref(_rootRef!) : null;
    final pagesValue = catalog?.entries['Pages'];
    final pagesDict = pagesValue is _PdfRef
        ? deref(pagesValue)
        : (pagesValue is _PdfDict ? pagesValue : null);
    if (pagesDict == null) {
      final pages = <_PdfDict>[];
      for (final entry in _locations.entries) {
        final dict = _readAt(entry.value);
        if (dict?.name('Type') == 'Page') pages.add(dict!);
      }
      return pages;
    }
    final result = <_PdfDict>[];
    void walk(_PdfDict node) {
      if (result.length > 40000) return;
      if (node.name('Type') == 'Page') {
        result.add(node);
        return;
      }
      final kids = node.entries['Kids'];
      if (kids is! List<Object?>) return;
      for (final kid in kids) {
        if (kid is _PdfRef) {
          final child = deref(kid);
          if (child != null) walk(child);
        } else if (kid is _PdfDict) {
          walk(kid);
        }
      }
    }

    walk(pagesDict);
    return result;
  }

  _PdfInfo info() {
    final result = _PdfInfo();
    final infoDict = _infoRef == null ? null : deref(_infoRef!);
    if (infoDict == null) return result;
    String decode(Object? value) {
      if (value is! Uint8List || value.isEmpty) return '';
      if (value[0] == 0xfe && value[1] == 0xff) {
        final buffer = StringBuffer();
        for (var i = 2; i + 1 < value.length; i += 2) {
          buffer.writeCharCode(value[i] << 8 | value[i + 1]);
        }
        return buffer.toString().trim();
      }
      return latin1.decode(value, allowInvalid: true).trim();
    }

    result.title = decode(infoDict.entries['Title']);
    result.author = decode(infoDict.entries['Author']);
    return result;
  }

  Uint8List contentStream(_PdfDict page) {
    final out = BytesBuilder(copy: false);
    void collect(Object? item) {
      if (item is _PdfRef) {
        final dict = deref(item);
        if (dict != null && dict.stream != null) {
          out.add(dict.streamBytes(this));
        }
      } else if (item is _PdfDict && item.stream != null) {
        out.add(item.streamBytes(this));
      } else if (item is List<Object?>) {
        for (final inner in item) {
          collect(inner);
        }
      }
    }

    collect(page.entries['Contents']);
    out.addByte(10);
    return out.takeBytes();
  }
}

class _ObjStmEntry {
  const _ObjStmEntry(this.streamNumber, this.index);
  final int streamNumber;
  final int index;
}

// ------------------------------------------------------------ pdf reader

/// Parses PDF values and object bodies (dict + optional stream).
class _PdfReader {
  _PdfReader(this.data) : _tokenizer = _Tokenizer(data);

  final Uint8List data;
  final _Tokenizer _tokenizer;
  final List<Object?> _pushback = [];

  static int _find(Uint8List data, List<int> needle, int from) =>
      _findIn(data, needle, from);

  static int _findIn(Uint8List data, List<int> needle, int from) {
    outer:
    for (var i = from; i + needle.length <= data.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (data[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  Object? _next() {
    if (_pushback.isNotEmpty) return _pushback.removeLast();
    return _tokenizer.next();
  }

  void _push(Object? token) {
    if (token != null) _pushback.add(token);
  }

  /// Parses the first top-level dictionary in an object body.
  _PdfDict? parseObject() {
    while (true) {
      final token = _next();
      if (token == null) return null;
      if (token is _Keyword && token.value == '<<') {
        final dict = _readDict();
        if (dict == null) return null;
        final following = _next();
        if (following is _Keyword && following.value == 'stream') {
          dict.stream = _captureStream(dict);
        }
        return dict;
      }
    }
  }

  Uint8List? _captureStream(_PdfDict dict) {
    final length = dict.streamLength;
    final remaining = _tokenizer.remaining();
    var skip = 0;
    if (remaining.isNotEmpty && remaining[0] == 13) skip++;
    if (remaining.length > skip && remaining[skip] == 10) skip++;
    if (length != null && length > 0 && skip + length <= remaining.length) {
      return Uint8List.sublistView(
        remaining,
        skip,
        skip + length,
      );
    }
    final end = _find(remaining, [0x65, 0x6e, 0x64, 0x73, 0x74, 0x72], 0); // endstr
    if (end <= skip) return null;
    var body = remaining.sublist(skip, end);
    // Trim trailing EOL before endstream.
    while (body.isNotEmpty &&
        (body.last == 10 || body.last == 13 || body.last == 32)) {
      body = body.sublist(0, body.length - 1);
    }
    return body;
  }

  _PdfDict? _readDict() {
    final entries = <String, Object?>{};
    while (true) {
      final token = _next();
      if (token == null) return _PdfDict(entries, null);
      if (token is _Keyword && token.value == '>>') {
        return _PdfDict(entries, null);
      }
      if (token is _PdfName) {
        entries[token.value] = _readValue();
      }
    }
  }

  /// Reads a dictionary that starts at the current position.
  _PdfDict? _peekDict() {
    final token = _next();
    if (token is! _Keyword || token.value != '<<') return null;
    return _readDict();
  }

  Object? _readValue() {
    final token = _next();
    if (token == null) return null;
    if (token is _Keyword) {
      switch (token.value) {
        case '<<':
          return _readDict();
        case '[':
          final list = <Object?>[];
          while (true) {
            final inner = _next();
            if (inner == null) return list;
            if (inner is _Keyword && inner.value == ']') return list;
            // Route through _readValue so num-num-R becomes a reference and
            // nested dictionaries/arrays parse recursively.
            _push(inner);
            list.add(_readValue());
          }
        case 'true':
          return true;
        case 'false':
          return false;
        case 'null':
          return null;
        case 'R':
          return null;
        default:
          return null;
      }
    }
    if (token is num) {
      // Reference lookahead: num num R.
      final second = _next();
      final third = _next();
      if (second is num && third is _Keyword && third.value == 'R') {
        return _PdfRef(token.round(), second.round());
      }
      _push(third);
      _push(second);
      return token;
    }
    return token;
  }
}

// ---------------------------------------------------------- tokenizer

class _Tokenizer {
  _Tokenizer(this.data);

  final Uint8List data;
  int _pos = 0;

  static int _find(Uint8List data, List<int> needle, int from) {
    outer:
    for (var i = from; i + needle.length <= data.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (data[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  bool get atEnd => _pos >= data.length;

  Uint8List remaining() => Uint8List.sublistView(data, _pos.clamp(0, data.length));

  List<Object?> all() {
    final tokens = <Object?>[];
    while (true) {
      final token = next();
      if (token == null) return tokens;
      tokens.add(token);
    }
  }

  static bool _isWhitespace(int byte) =>
      byte == 0 ||
      byte == 9 ||
      byte == 10 ||
      byte == 12 ||
      byte == 13 ||
      byte == 32;

  static bool _isDelimiter(int byte) =>
      byte == 0x28 ||
      byte == 0x29 ||
      byte == 0x3c ||
      byte == 0x3e ||
      byte == 0x5b ||
      byte == 0x5d ||
      byte == 0x7b ||
      byte == 0x7d ||
      byte == 0x2f ||
      byte == 0x25;

  void _skipWhitespace() {
    while (_pos < data.length &&
        (_isWhitespace(data[_pos]) || data[_pos] == 0x25)) {
      if (data[_pos] == 0x25) {
        while (_pos < data.length && data[_pos] != 10 && data[_pos] != 13) {
          _pos++;
        }
      } else {
        _pos++;
      }
    }
  }

  Object? next() {
    _skipWhitespace();
    if (_pos >= data.length) return null;
    final byte = data[_pos];
    switch (byte) {
      case 0x28:
        return _literalString();
      case 0x3c:
        if (_pos + 1 < data.length && data[_pos + 1] == 0x3c) {
          _pos += 2;
          return const _Keyword('<<');
        }
        return _hexString();
      case 0x3e:
        if (_pos + 1 < data.length && data[_pos + 1] == 0x3e) {
          _pos += 2;
          return const _Keyword('>>');
        }
        _pos++;
        return const _Keyword('>');
      case 0x5b:
        _pos++;
        return const _Keyword('[');
      case 0x5d:
        _pos++;
        return const _Keyword(']');
      case 0x2f:
        return _name();
      default:
        return _word();
    }
  }

  /// Skips an inline image (BI ... ID ... EI); binary data must never
  /// reach the token stream as pseudo-operators.

  Uint8List _literalString() {
    _pos++;
    final out = BytesBuilder();
    var depth = 1;
    while (_pos < data.length) {
      final byte = data[_pos];
      _pos++;
      if (byte == 0x5c) {
        if (_pos >= data.length) break;
        final esc = data[_pos];
        _pos++;
        switch (esc) {
          case 0x6e:
            out.addByte(10);
          case 0x72:
            out.addByte(13);
          case 0x74:
            out.addByte(9);
          case 0x62:
            out.addByte(8);
          case 0x66:
            out.addByte(12);
          case 0x28 || 0x29 || 0x5c:
            out.addByte(esc);
          default:
            if (esc >= 0x30 && esc <= 0x37) {
              var value = esc - 0x30;
              var digits = 1;
              while (digits < 3 &&
                  _pos < data.length &&
                  data[_pos] >= 0x30 &&
                  data[_pos] <= 0x37) {
                value = value * 8 + (data[_pos] - 0x30);
                _pos++;
                digits++;
              }
              out.addByte(value & 0xff);
            } else if (esc == 10 || esc == 13) {
              if (esc == 13 && _pos < data.length && data[_pos] == 10) {
                _pos++;
              }
            } else {
              out.addByte(esc);
            }
        }
        continue;
      }
      if (byte == 0x28) {
        depth++;
      } else if (byte == 0x29) {
        depth--;
        if (depth == 0) return out.takeBytes();
      }
      out.addByte(byte);
    }
    return out.takeBytes();
  }

  Uint8List _hexString() {
    _pos++;
    final out = BytesBuilder();
    var high = -1;
    while (_pos < data.length) {
      final byte = data[_pos];
      _pos++;
      if (byte == 0x3e) break;
      final nibble = _hexValue(byte);
      if (nibble == null) continue;
      if (high < 0) {
        high = nibble;
      } else {
        out.addByte(high << 4 | nibble);
        high = -1;
      }
    }
    if (high >= 0) out.addByte(high << 4);
    return out.takeBytes();
  }

  int? _hexValue(int byte) {
    if (byte >= 0x30 && byte <= 0x39) return byte - 0x30;
    if (byte >= 0x61 && byte <= 0x66) return byte - 0x61 + 10;
    if (byte >= 0x41 && byte <= 0x46) return byte - 0x41 + 10;
    return null;
  }

  _PdfName _name() {
    _pos++;
    final out = StringBuffer();
    while (_pos < data.length) {
      final byte = data[_pos];
      if (_isWhitespace(byte) || _isDelimiter(byte)) break;
      if (byte == 0x23 && _pos + 2 < data.length) {
        final high = _hexValue(data[_pos + 1]);
        final low = _hexValue(data[_pos + 2]);
        if (high != null && low != null) {
          out.writeCharCode(high << 4 | low);
          _pos += 3;
          continue;
        }
      }
      out.writeCharCode(byte);
      _pos++;
    }
    return _PdfName(out.toString());
  }

  Object? _word() {
    final start = _pos;
    while (_pos < data.length) {
      final byte = data[_pos];
      if (_isWhitespace(byte) || _isDelimiter(byte)) break;
      _pos++;
    }
    final word = _ascii(data.sublist(start, _pos));
    if (word == 'BI') {
      _skipInlineImage();
      return const _Keyword('BI');
    }
    if (word.isEmpty) {
      _pos++;
      return null;
    }
    final number = num.tryParse(word);
    return number ?? _Keyword(word);
  }

  void _skipInlineImage() {
    // Consume the key/value pairs until ID, then the binary payload to EI.
    while (_pos < data.length) {
      final token = next();
      if (token is _Keyword && token.value == 'ID') break;
      if (token == null) return;
    }
    // The image data begins after one whitespace byte.
    var search = _pos;
    while (search < data.length &&
        (data[search] == 10 || data[search] == 13 || data[search] == 32)) {
      search++;
    }
    while (true) {
      final at = _find(data, [0x45, 0x49], search); // EI
      if (at < 0) {
        _pos = data.length;
        return;
      }
      final before = at > 0 ? data[at - 1] : 32;
      final after = at + 2 < data.length ? data[at + 2] : 32;
      if (_isWhitespace(before) && _isWhitespace(after)) {
        _pos = at + 2;
        return;
      }
      search = at + 2;
    }
  }
}

String _ascii(List<int> bytes) => String.fromCharCodes(bytes);
