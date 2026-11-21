import 'dart:io';

import 'package:archive/archive_io.dart';

import 'book_import_limits.dart';

/// Dart port of the Android `BookEpubWriter`: bounded chapters, disk-backed
/// resources, and the exact EPUB 3 layout the in-app reader already parses
/// from the Android converter output.
class BookEpubWriter {
  BookEpubWriter(this.work, this.title) : _chapterTitle = title;

  final Directory work;
  String title;
  String author = '';
  String? cover;

  final _chapters = <(String, File)>[];
  final _references = <String, int>{};
  final _resources = <int, (String, File)>{};
  final _body = StringBuffer();
  String _chapterTitle;
  int _expanded = 0;

  static const _maxChapterBody = 200000;
  static const _maxResourceBytes = 8 * 1024 * 1024;
  static const _maxExpandedBytes = 1024 * 1024 * 1024;

  static String escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static bool _endsInHighSurrogate(String text, int end) {
    if (end <= 0 || end > text.length) return false;
    return (text.codeUnitAt(end - 1) & 0xfc00) == 0xd800;
  }

  void heading(String value) {
    flush();
    final trimmed = value.trim();
    _chapterTitle = trimmed.isEmpty
        ? title
        : (trimmed.length > 2048 ? trimmed.substring(0, 2048) : trimmed);
  }

  void text(String value) {
    if (value.trim().isEmpty) return;
    // A huge unstructured paragraph must not become one enormous Text layout.
    var at = 0;
    while (at < value.length) {
      var end = at + 4000;
      if (end >= value.length) {
        end = value.length;
      } else if (_endsInHighSurrogate(value, end)) {
        end--;
      }
      _append('<p>${escape(value.substring(at, end))}</p>');
      at = end;
    }
  }

  /// Raw converter markup (MOBI HTML fragments); the caller owns escaping.
  void markup(String html) {
    var at = 0;
    while (at < html.length) {
      var end = at + 4000;
      if (end >= html.length) {
        end = html.length;
      } else if (_endsInHighSurrogate(html, end)) {
        end--;
      }
      _append(html.substring(at, end));
      at = end;
    }
  }

  void _append(String value) {
    if (_body.length + value.length > _maxChapterBody) flush();
    _body.write(value);
  }

  int reference(String key) =>
      _references.putIfAbsent(key, () => _references.length);

  int get resourceCount => _references.length;

  String inlineResourceKey() => 'inline-${_references.length}';

  void image(String key, [String style = '']) {
    _append(
      '<img src="resource:${reference(key)}"'
      '${style.isEmpty ? '' : ' style="${escape(style)}"'}/>',
    );
  }

  void resource(String key, String type, List<int> bytes) {
    final ext = switch (type.toLowerCase().split(';').first) {
      'image/jpeg' || 'jpg' || 'jpeg' => 'jpg',
      'image/png' || 'png' => 'png',
      'image/gif' || 'gif' => 'gif',
      'image/webp' || 'webp' => 'webp',
      _ => null,
    };
    if (ext == null) return;
    final id = reference(key);
    if (_resources.containsKey(id)) return;
    final file = File('${work.path}/resource-$id.$ext');
    if (bytes.length > _maxResourceBytes ||
        _expanded + bytes.length > _maxExpandedBytes) {
      throw const FormatException('单张图片超过 8 MiB，或文档展开后超过 1 GiB');
    }
    file.writeAsBytesSync(bytes, flush: true);
    _expanded += bytes.length;
    _resources[id] = (ext, file);
  }

  void flush() {
    if (_body.isEmpty) return;
    if (_chapters.length >= 10000) {
      throw const FormatException('文档章节过多，请拆分后导入');
    }
    final file = File('${work.path}/chapter-${_chapters.length}.html');
    file.writeAsStringSync(_body.toString(), flush: true);
    _expanded += file.lengthSync();
    if (_expanded > _maxExpandedBytes) {
      throw const FormatException('文档展开后超过 1 GiB');
    }
    _chapters.add((_chapterTitle, file));
    _body.clear();
  }

  void write(File output) {
    flush();
    if (_chapters.isEmpty) {
      throw const FormatException('文档中没有可阅读的正文');
    }
    final workPath = '${work.path}/';
    final encoder = ZipFileEncoder();
    try {
      encoder.create(output.path);
      void entry(String path, String value) {
        final file = File('$workPath/$path.epub-entry')
          ..parent.createSync(recursive: true);
        file.writeAsStringSync(value, flush: true);
        encoder.addFileSync(file, path);
        file.deleteSync();
      }

      entry('mimetype', 'application/epub+zip');
      entry(
        'META-INF/container.xml',
        '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="content.opf" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>',
      );
      final coverId = cover == null ? null : _references[cover];
      final manifest = StringBuffer(
        _chapters.indexed
            .map((item) =>
                '<item id="c${item.$1}" href="c${item.$1}.xhtml" '
                'media-type="application/xhtml+xml"/>')
            .join(),
      );
      final sorted = _resources.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      for (final entry in sorted) {
        final (ext, _) = entry.value;
        manifest.write(
          '<item id="i${entry.key}" href="image-${entry.key}.$ext" '
          'media-type="image/${ext == 'jpg' ? 'jpeg' : ext}"'
          '${entry.key == coverId ? ' properties="cover-image"' : ''}/>',
        );
      }
      entry(
        'content.opf',
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>${escape(title)}</dc:title>'
        '<dc:creator>${escape(author)}</dc:creator></metadata>'
        '<manifest><item id="nav" href="nav.xhtml" '
        'media-type="application/xhtml+xml" properties="nav"/>$manifest'
        '</manifest><spine>'
        '${_chapters.indexed.map((item) => '<itemref idref="c${item.$1}"/>').join()}'
        '</spine></package>',
      );
      entry(
        'nav.xhtml',
        '<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops"><body>'
        '<nav epub:type="toc"><ol>${_chapters.indexed.map((item) => '<li><a href="c${item.$1}.xhtml">${escape(item.$2.$1)}</a></li>').join()}'
        '</ol></nav></body></html>',
      );
      final resourcePattern = RegExp(r'resource:(\d+)');
      for (final (index, chapter) in _chapters.indexed) {
        final html = chapter.$2.readAsStringSync().replaceAllMapped(
          resourcePattern,
          (match) => _resources[int.parse(match.group(1)!)] == null
              ? ''
              : 'image-${match.group(1)}.${_resources[int.parse(match.group(1)!)]!.$1}',
        );
        entry(
          'c$index.xhtml',
          '<html xmlns="http://www.w3.org/1999/xhtml"><body>$html</body></html>',
        );
      }
      for (final entry in sorted) {
        final (ext, file) = entry.value;
        encoder.addFileSync(file, 'image-${entry.key}.$ext');
      }
      encoder.closeSync();
    } catch (_) {
      try {
        encoder.closeSync();
      } catch (_) {}
      if (output.existsSync()) output.deleteSync();
      rethrow;
    }
    if (output.lengthSync() > maxLocalEpubBytes) {
      output.deleteSync();
      throw const FormatException('转换后的文档超过 512 MiB');
    }
  }
}
