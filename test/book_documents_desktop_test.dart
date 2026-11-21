import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/book_documents_desktop.dart';
import 'package:wenku8_flutter/legacy/gbk_codec.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.support);

  final String support;

  @override
  Future<String?> getApplicationSupportPath() async => support;
}

void main() {
  late Directory support;
  late Directory library;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    support = await Directory.systemTemp.createTemp('wenku8-support');
    library = await Directory.systemTemp.createTemp('wenku8-books');
    PathProviderPlatform.instance = _FakePathProvider(support.path);
  });

  tearDown(() async {
    await support.delete(recursive: true);
    await library.delete(recursive: true);
  });

  Future<void> seedLibrary() async {
    File('${library.path}/龙族.txt').writeAsBytesSync(
      Gbk.tryEncode('第一段 龙族正文\r\n第二段继续')!,
    );
    Directory('${library.path}/sub').createSync();
    File('${library.path}/sub/伪装学渣.epub').writeAsBytesSync([1, 2, 3]);
    File('${library.path}/.隐藏.txt').writeAsBytesSync([9]);
  }

  test('scan discovers supported books and dedupes unchanged ones', () async {
    await seedLibrary();
    SharedPreferences.setMockInitialValues({
      'book_scan_folders.path': library.path,
      'book_scan_folders.name': 'books',
    });
    final documents = DesktopBookDocuments();

    final info = await documents.scanFolderInfo();
    expect(info, isNotNull);
    expect(info!['readable'], isTrue);

    final snapshot = await documents.scanBooks();
    final books = (snapshot['books'] as List).cast<Map>();
    expect(books.length, 2, reason: 'hidden files stay out');
    expect(
      books.map((book) => book['name']).toSet(),
      {'龙族.txt', '伪装学渣.epub'},
    );

    final staged = await documents.stageScanBook(books.first['token'] as String);
    expect(staged['path'], isNotNull);

    await documents.markScanBook(books.first['token'] as String);
    await documents.finishBookScan();

    final again = await documents.scanBooks();
    final remaining = (again['books'] as List).cast<Map>();
    expect(remaining.length, 1, reason: 'marked book counts as unchanged');
    expect(again['unchanged'], 1);
  });

  test('format filters narrow the scan', () async {
    await seedLibrary();
    SharedPreferences.setMockInitialValues({
      'book_scan_folders.path': library.path,
    });
    final documents = DesktopBookDocuments();

    await documents.setScanFormats({'epub'});
    final snapshot = await documents.scanBooks();
    expect(
      (snapshot['books'] as List).map((book) => book['name']),
      ['伪装学渣.epub'],
    );
  });

  test('decodeText auto-detects GBK content', () async {
    await seedLibrary();
    final documents = DesktopBookDocuments();

    final text = await documents.decodeText('${library.path}/龙族.txt');
    expect(text, '第一段 龙族正文\r\n第二段继续');
  });

  test('decodeTextFile normalizes into the staging area', () async {
    await seedLibrary();
    final documents = DesktopBookDocuments();

    final path = await documents.decodeTextFile('${library.path}/龙族.txt');
    final file = File(path);
    expect(file.existsSync(), isTrue);
    final normalized = utf8.decode(file.readAsBytesSync());
    expect(normalized, '第一段 龙族正文\r\n第二段继续');
    // Staged copies live in the app staging area, so releaseBooks may clean
    // them without touching user files.
    expect(file.parent.path, contains('import-staging'));
  });

  test('prepareBook rejects unsupported desktop formats with clear errors',
      () async {
    await seedLibrary();
    final documents = DesktopBookDocuments();
    // FB2/HTML/Markdown/RTF still have no desktop converter.
    final fb2 = File('${library.path}/龙族.fb2')
      ..writeAsBytesSync([1, 2, 3, 4]);
    try {
      await documents.prepareBook('龙族.fb2', fb2.path);
      fail('expected a rejection');
    } on FormatException catch (failure) {
      expect(failure.message, contains('桌面版'));
    }
    // Kindle formats now convert; corrupt payloads surface the converter
    // error instead of a blanket "unsupported".
    final mobi = File('${library.path}/龙族.mobi')
      ..writeAsBytesSync([1, 2, 3, 4]);
    try {
      await documents.prepareBook('龙族.mobi', mobi.path);
      fail('expected a rejection');
    } on FormatException catch (failure) {
      expect(failure.message, contains('MOBI 文件损坏或格式不受支持'));
    }
  });
}
