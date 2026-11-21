import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:xml/xml_events.dart';

import 'book_epub_writer.dart';

/// Re-decodes the XML entity references the event stream leaves in place.
final _entityPattern = RegExp(r'&(amp|lt|gt|quot|apos|#x?[0-9a-fA-F]+);');

String _decodeEntities(String text) {
  if (!text.contains('&')) return text;
  return text.replaceAllMapped(_entityPattern, (match) {
    final body = match.group(1)!;
    if (body == 'amp') return '&';
    if (body == 'lt') return '<';
    if (body == 'gt') return '>';
    if (body == 'quot') return '"';
    if (body == 'apos') return "'";
    final value = body.startsWith('#x') || body.startsWith('#X')
        ? int.parse(body.substring(2), radix: 16)
        : int.parse(body.substring(1));
    return String.fromCharCode(value);
  });
}

/// Dart port of the Kotlin `BookMarkupImport` DOCX branch: streaming XML
/// events with the same bounds (entry count, per-entry size, expansion cap).
class BookDocxImport {
  static const _maxEntries = 12000;
  static const _maxEntryBytes = 40 * 1024 * 1024;
  static const _maxExpandedBytes = 1024 * 1024 * 1024;

  final Directory work;

  BookDocxImport(this.work);

  String _local(String name) => name.contains(':')
      ? name.substring(name.lastIndexOf(':') + 1)
      : name;

  String? _attr(List<XmlEventAttribute> attributes, List<String> names) {
    for (final attribute in attributes) {
      final local = _local(attribute.name);
      if (names.contains(local) || names.contains(attribute.name)) {
        return attribute.value;
      }
    }
    return null;
  }

  /// Converts [source] into an EPUB written to [output].
  void convert(File source, File output) {
    final writer = BookEpubWriter(work, '');
    final archive = ZipDecoder().decodeStream(
      InputFileStream(source.path, bufferSize: 1 << 16),
    );
    try {
      if (archive.length > _maxEntries) {
        throw const FormatException('DOCX 内文件过多');
      }
      var expanded = 0;
      for (final entry in archive.files) {
        final size = entry.size;
        if (size < 0 || size > _maxEntryBytes || expanded + size > _maxExpandedBytes) {
          throw const FormatException('DOCX 解压后超过大小限制');
        }
        expanded += size;
      }

      final relations = <String, String>{};
      final relsEntry = _entry(archive, 'word/_rels/document.xml.rels');
      if (relsEntry != null) {
        _parse(relsEntry.content, (start, text, end) {
          if (start != null &&
              _local(start.name) == 'Relationship' &&
              _attr(start.attributes, ['TargetMode']) != 'External') {
            final target = _attr(start.attributes, ['Target']);
            final id = _attr(start.attributes, ['Id']);
            if (target == null || id == null) return;
            final path = _resolve('word/document.xml', target);
            if (path != null) relations[id] = path;
          }
        });
      }

      final coreEntry = _entry(archive, 'docProps/core.xml');
      if (coreEntry != null) {
        var field = '';
        final value = StringBuffer();
        _parse(coreEntry.content, (start, text, end) {
          if (start != null) {
            final local = _local(start.name);
            if (local == 'title' || local == 'creator') {
              field = local;
              value.clear();
            }
          } else if (field.isNotEmpty && value.length < 2048 && text != null) {
            value.write(
              text.length > 2048 - value.length
                  ? text.substring(0, 2048 - value.length)
                  : text,
            );
          } else if (end != null && _local(end.name) == field) {
            if (field == 'title' && value.toString().trim().isNotEmpty) {
              writer.title = value.toString();
            }
            if (field == 'creator') {
              writer.author = value.toString();
            }
            field = '';
          }
        });
      }

      final documentEntry = _entry(archive, 'word/document.xml');
      if (documentEntry == null) {
        throw const FormatException('DOCX 缺少正文，或文件已加密');
      }
      var inText = false;
      var heading = false;
      var width = '';
      final paragraph = StringBuffer();
      void flush() {
        if (heading) {
          writer.heading(paragraph.toString());
        } else {
          writer.text(paragraph.toString());
        }
        paragraph.clear();
      }

      _parse(documentEntry.content, (start, text, end) {
        if (start != null) {
          switch (_local(start.name)) {
            case 'p':
              heading = false;
              width = '';
            case 'pStyle':
              final style = _attr(start.attributes, ['val']) ?? '';
              if (RegExp('heading|标题', caseSensitive: false).hasMatch(style)) {
                heading = true;
              }
            case 't':
              inText = true;
            case 'tab':
              paragraph.write(' ');
            case 'br':
              flush();
            case 'extent':
              final cx = int.tryParse(_attr(start.attributes, ['cx']) ?? '');
              if (cx != null) width = 'width:${cx / 9525.0}px';
            case 'blip':
              final id = _attr(start.attributes, ['embed']);
              final path = id == null ? null : relations[id];
              if (path != null) {
                final image = _entry(archive, path);
                if (image != null) {
                  flush();
                  writer.resource(
                    path,
                    path.split('.').last,
                    image.content,
                  );
                  writer.image(path, width);
                }
              }
          }
        } else if (text != null && inText) {
          paragraph.write(_decodeEntities(text));
          if (paragraph.length >= 4000 && !heading) flush();
        } else if (end != null) {
          final local = _local(end.name);
          if (local == 't') inText = false;
          if (local == 'p') flush();
        }
      });
      writer.write(output);
    } finally {
      archive.clear();
    }
  }

  ArchiveFile? _entry(Archive archive, String path) {
    for (final entry in archive.files) {
      if (entry.name == path) return entry;
    }
    return null;
  }

  String? _resolve(String base, String target) {
    // Same resolution contract as the Kotlin URI("https://local/$base") resolve.
    final baseParts = base.split('/')..removeLast();
    if (target.startsWith('/')) {
      return target.substring(1);
    }
    var parts = [...baseParts];
    for (final part in target.split('/')) {
      if (part == '' || part == '.') continue;
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
        continue;
      }
      parts.add(part);
    }
    return parts.isEmpty ? null : parts.join('/');
  }

  void _parse(
    List<int> bytes,
    void Function(XmlStartElementEvent?, String?, XmlEndElementEvent?) visitor,
  ) {
    final decoded = _decode(bytes);
    for (final event in parseEvents(decoded)) {
      switch (event) {
        case XmlStartElementEvent():
          visitor(event, null, null);
        case XmlTextEvent(:final value):
          visitor(null, value, null);
        case XmlEndElementEvent():
          visitor(null, null, event);
        default:
          break;
      }
    }
  }

  String _decode(List<int> bytes) {
    // BOM-aware UTF-8 decode; DOCX parts always declare UTF-8.
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      bytes = bytes.sublist(3);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}
