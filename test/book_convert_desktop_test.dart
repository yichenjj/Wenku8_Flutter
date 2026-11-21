import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/book_docx_import.dart';
import 'package:wenku8_flutter/book_mobi_import.dart';
import 'package:wenku8_flutter/book_pdf_import.dart';

/// The fixtures come from linux/gen_book_fixtures.py — independent Python
/// implementations of PalmDOC compression, OPC packaging and raw PDF layout.
void main() {
  late Directory work;

  setUpAll(() async {
    work = await Directory.systemTemp.createTemp('wenku8-convert');
  });

  tearDownAll(() async {
    if (work.existsSync()) work.deleteSync(recursive: true);
  });

  String fixture(String name) => 'test/fixtures/$name';

  Map<String, List<int>> epubEntries(File epub) {
    final archive = ZipDecoder().decodeBytes(epub.readAsBytesSync());
    return {
      for (final entry in archive.files)
        if (entry.isFile) entry.name: entry.content,
    };
  }

  group('MOBI converter', () {
    test('converts a PalmDOC MOBI 6 book with images and page breaks', () {
      final output = File('${work.path}/mobi-basic.epub');
      BookMobiImport(work).convert(File(fixture('sample.mobi')), output);
      final entries = epubEntries(output);
      final opf = utf8.decode(entries['content.opf']!);
      expect(opf, contains('<dc:title>夹具书目</dc:title>'));
      expect(opf, contains('<dc:creator>夹具作者</dc:creator>'));
      final body = [
        ...entries.keys.where((k) => RegExp(r'^c\d+\.xhtml$').hasMatch(k))
            .map((k) => utf8.decode(entries[k]!)),
      ].join();
      expect(body, contains('第一章 启程'));
      expect(body, contains('风把窗帘吹成一面旗，走廊尽头亮着灯。'));
      expect(body, contains('第二章 山道'));
      // recindex resolves to the packed image record (rewritten at write()).
      expect(body, contains('<img src="image-0.png"/>'));
      expect(body, isNot(contains('recindex')));
      final png = entries.entries.firstWhere((e) => e.key.startsWith('image-'));
      expect(png.value.first, 0x89);
      expect(png.key.endsWith('.png'), isTrue);
    });

    test('trims trailing entries and multibyte overlap per record', () {
      final output = File('${work.path}/mobi-trailing.epub');
      BookMobiImport(work).convert(File(fixture('sample-trailing.mobi')), output);
      final entries = epubEntries(output);
      final body = [
        ...entries.keys.where((k) => RegExp(r'^c\d+\.xhtml$').hasMatch(k))
            .map((k) => utf8.decode(entries[k]!)),
      ].join();
      expect(body, contains('风把窗帘吹成一面旗'));
      expect(body, isNot(contains('\uFFFD')));
    });

    test('decodes CP1252 books', () {
      final output = File('${work.path}/mobi-latin.epub');
      BookMobiImport(work).convert(File(fixture('sample-cp1252.mobi')), output);
      final entries = epubEntries(output);
      final body = [
        ...entries.keys.where((k) => RegExp(r'^c\d+\.xhtml$').hasMatch(k))
            .map((k) => utf8.decode(entries[k]!)),
      ].join();
      expect(body, contains('Café naïve.'));
    });

    test('rejects DRM with the Android message', () {
      final drm = File('${work.path}/mobi-drm.epub');
      expect(
        () => BookMobiImport(work).convert(File(fixture('sample-drm.mobi')), drm),
        throwsA(const FormatException('不支持受 DRM 保护的 Kindle 电子书')),
      );
      expect(drm.existsSync(), isFalse);
    });

    test('rejects HUFF/CDIC compression as unsupported', () {
      final huff = File('${work.path}/mobi-huff.epub');
      // The fixture lacks real HUFF tables; either the structure check or the
      // table check must fail with the corrupt/unsupported message.
      expect(
        () => BookMobiImport(work).convert(File(fixture('sample-huff.mobi')), huff),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('DOCX converter', () {
    test('converts headings, entities, breaks and embedded images', () {
      final output = File('${work.path}/docx.epub');
      BookDocxImport(work).convert(File(fixture('sample.docx')), output);
      final entries = epubEntries(output);
      final opf = utf8.decode(entries['content.opf']!);
      expect(opf, contains('<dc:title>桌面夹具手册</dc:title>'));
      expect(opf, contains('<dc:creator>夹具编写组</dc:creator>'));
      final body = [
        ...entries.keys.where((k) => RegExp(r'^c\d+\.xhtml$').hasMatch(k))
            .map((k) => utf8.decode(entries[k]!)),
      ].join();
      // Heading titles land in nav.xhtml; the entity stays decoded.
      final nav = utf8.decode(entries['nav.xhtml']!);
      expect(nav, contains('第一章&amp;起程'));
      expect(body, contains('风把窗帘吹成一面旗。'));
      expect(body, contains('第二行文字。'));
      expect(body, contains('<img src="image-0.png"/>'));
      final png = entries.entries.firstWhere((e) => e.key.startsWith('image-'));
      expect(png.value.first, 0x89);
    });
  });

  group('PDF importer', () {
    test('extracts WinAnsi text and falls back to page images', () {
      final output = File('${work.path}/pdf.epub');
      BookPdfImport(work).convert(File(fixture('sample.pdf')), output);
      final entries = epubEntries(output);
      final opf = utf8.decode(entries['content.opf']!);
      expect(opf, contains('<dc:title>Hi 你好</dc:title>'));
      expect(opf, contains('<dc:creator>Fixture Author</dc:creator>'));
      final body = [
        ...entries.keys.where((k) => RegExp(r'^c\d+\.xhtml$').hasMatch(k))
            .map((k) => utf8.decode(entries[k]!)),
      ].join();
      final nav = utf8.decode(entries['nav.xhtml']!);
      expect(nav, contains('第 1 页'));
      expect(nav, contains('第 2 页'));
      expect(body, contains('Hello from the desktop fixture!'));
      expect(body, contains('Second (escaped) line.'));
      // The textless second page became a JPEG page image.
      expect(body, contains('image-'));
      expect(body, contains('.jpg'));
    });
  });
}
