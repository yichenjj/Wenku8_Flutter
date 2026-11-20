import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'book_documents_desktop.dart';
import 'book_import_limits.dart';

/// The desktop build has no SAF bridge; every contract routes to the
/// filesystem implementation instead of the platform channel.
bool get _desktopDocuments =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

class BookDocumentSelection {
  const BookDocumentSelection({required this.name, this.path, this.error})
    : assert((path == null) != (error == null));
  final String name;
  final String? path, error;
}

class BookScanFolder {
  const BookScanFolder({
    required this.name,
    required this.automatic,
    required this.readable,
    this.allStorage = false,
  });
  factory BookScanFolder.fromMap(Map<dynamic, dynamic> value) => BookScanFolder(
    name: value['name'] as String,
    automatic: value['automatic'] == true,
    readable: value['readable'] == true,
    allStorage: value['all'] == true,
  );
  final String name;
  final bool automatic, readable;
  final bool allStorage;
}

typedef BookScanEntry = ({String token, String name});

class BookScanSnapshot {
  const BookScanSnapshot({
    required this.books,
    this.total = 0,
    this.unchanged = 0,
    this.warnings = const [],
    this.details = const {},
  });
  final List<BookScanEntry> books;
  final int total, unchanged;
  final List<String> warnings;
  final Map<String, ({int? size, String folder})> details;
}

class BookDocuments {
  static const channel = MethodChannel('org.mewx.wenku8/book_documents');
  static final DesktopBookDocuments _desktop = DesktopBookDocuments();

  Future<BookDocumentSelection?> pickFont() async {
    if (_desktopDocuments) {
      final value = await _desktop.pickFont();
      return value == null
          ? null
          : BookDocumentSelection(
              name: value['name'] as String,
              path: value['path'] as String,
            );
    }
    final value = await channel.invokeMapMethod<String, dynamic>('pickFont');
    return value == null
        ? null
        : BookDocumentSelection(
            name: value['name'] as String,
            path: value['path'] as String,
          );
  }

  Future<BookScanFolder?> scanFolderInfo() async {
    if (_desktopDocuments) {
      final value = await _desktop.scanFolderInfo();
      return value == null ? null : BookScanFolder.fromMap(value);
    }
    final value = await channel.invokeMapMethod<String, dynamic>(
      'scanFolderInfo',
    );
    return value == null ? null : BookScanFolder.fromMap(value);
  }

  Future<BookScanFolder?> selectScanFolder() async {
    if (_desktopDocuments) {
      final value = await _desktop.selectScanFolder();
      return value == null ? null : BookScanFolder.fromMap(value);
    }
    final value = await channel.invokeMapMethod<String, dynamic>(
      'selectScanFolder',
    );
    return value == null ? null : BookScanFolder.fromMap(value);
  }

  Future<void> setScanAutomatic(bool value) async {
    if (_desktopDocuments) return _desktop.setScanAutomatic(value);
    return channel.invokeMethod<void>('setScanAutomatic', {'value': value});
  }

  Future<BookScanFolder?> selectAllScan() async {
    if (_desktopDocuments) {
      final value = await _desktop.selectAllScan();
      return value == null ? null : BookScanFolder.fromMap(value);
    }
    final value = await channel.invokeMapMethod<String, dynamic>(
      'selectAllScan',
    );
    return value == null ? null : BookScanFolder.fromMap(value);
  }

  Future<void> disconnectScanFolder() async {
    if (_desktopDocuments) return _desktop.disconnectScanFolder();
    return channel.invokeMethod<void>('disconnectScanFolder');
  }

  Future<Set<String>> scanFormats() async {
    if (_desktopDocuments) return _desktop.scanFormats();
    final extensions = await channel.invokeListMethod<String>('scanFormats');
    return extensions == null
        ? bookFormatLabels.keys.toSet()
        : extensions.map((e) => bookFormatKey('book.$e')).toSet();
  }

  Future<void> setScanFormats(Set<String> formats) async {
    if (_desktopDocuments) return _desktop.setScanFormats(formats);
    return channel.invokeMethod<void>('setScanFormats', {
      'extensions': bookFormatExtensions(formats).toList(),
    });
  }

  Future<BookScanSnapshot> scanBooks() async {
    if (_desktopDocuments) {
      final value = await _desktop.scanBooks();
      return BookScanSnapshot(
        books: [
          for (final book in value['books'] as List)
            (token: book['token'] as String, name: book['name'] as String),
        ],
        total: value['total'] as int,
        unchanged: value['unchanged'] as int,
        warnings: (value['warnings'] as List).cast<String>(),
        details: {
          for (final book in value['books'] as List)
            book['token'] as String: (
              size: book['size'] as int?,
              folder: book['folder'] as String? ?? '',
            ),
        },
      );
    }
    final value = (await channel.invokeMapMethod<String, dynamic>(
      'scanBooks',
    ))!;
    return BookScanSnapshot(
      books: [
        for (final book in value['books'] as List)
          (token: book['token'] as String, name: book['name'] as String),
      ],
      total: value['total'] as int,
      unchanged: value['unchanged'] as int,
      warnings: (value['warnings'] as List).cast<String>(),
      details: {
        for (final book in value['books'] as List)
          book['token'] as String: (
            size: book['size'] as int?,
            folder: book['folder'] as String? ?? '',
          ),
      },
    );
  }

  Future<BookDocumentSelection> stageScanBook(String token) async {
    final value = _desktopDocuments
        ? await _desktop.stageScanBook(token)
        : (await channel.invokeMapMethod<String, dynamic>(
              'stageScanBook',
              {'token': token},
            ))!;
    return BookDocumentSelection(
      name: value['name'] as String,
      path: value['path'] as String,
    );
  }

  Future<void> markScanBook(String token) async {
    if (_desktopDocuments) return _desktop.markScanBook(token);
    return channel.invokeMethod<void>('markScanBook', {'token': token});
  }

  Future<void> finishBookScan() async {
    if (_desktopDocuments) return _desktop.finishBookScan();
    return channel.invokeMethod<void>('finishBookScan');
  }

  Future<({String name, String path})?> pickBook() async {
    if (_desktopDocuments) return _desktop.pickBook();
    final value = await channel.invokeMapMethod<String, dynamic>('pickBook');
    return value == null
        ? null
        : (name: value['name'] as String, path: value['path'] as String);
  }

  Future<List<BookDocumentSelection>> pickBooks() async {
    if (_desktopDocuments) {
      return [
        for (final value in await _desktop.pickBooks())
          BookDocumentSelection(
            name: value['name'] as String,
            path: value['path'] as String?,
            error: value['error'] as String?,
          ),
      ];
    }
    final values = await channel.invokeListMethod<dynamic>('pickBooks');
    return [
      for (final value in values ?? const [])
        BookDocumentSelection(
          name: value['name'] as String,
          path: value['path'] as String?,
          error: value['error'] as String?,
        ),
    ];
  }

  Future<void> releaseBooks(Iterable<BookDocumentSelection> books) async {
    if (_desktopDocuments) {
      return _desktop.releaseBooks(books.map((book) => book.path));
    }
    return channel.invokeMethod<void>('releaseBooks', {
      'paths': books
          .map((book) => book.path)
          .whereType<String>()
          .toSet()
          .toList(),
    });
  }

  /// Existing TXT/EPUB callers keep their original, platform-independent path.
  /// MOBI is reconstructed as EPUB and ZIP yields a batch of staged originals.
  Future<List<BookDocumentSelection>> prepareBook(
    BookDocumentSelection book,
  ) async {
    if (book.path == null ||
        RegExp(r'\.(txt|epub)$', caseSensitive: false).hasMatch(book.name)) {
      return [book];
    }
    if (_desktopDocuments) {
      try {
        return [
          for (final value in await _desktop.prepareBook(book.name, book.path!))
            BookDocumentSelection(
              name: value['name'] as String,
              path: value['path'] as String?,
              error: value['error'] as String?,
            ),
        ];
      } on FormatException catch (failure) {
        return [
          BookDocumentSelection(
            name: book.name,
            error: failure.message,
          ),
        ];
      }
    }
    try {
      final values = await channel.invokeListMethod<dynamic>('prepareBook', {
        'name': book.name,
        'path': book.path,
      });
      return [
        for (final value in values ?? const [])
          BookDocumentSelection(
            name: value['name'] as String,
            path: value['path'] as String?,
            error: value['error'] as String?,
          ),
      ];
    } on PlatformException catch (failure) {
      return [
        BookDocumentSelection(
          name: book.name,
          error: failure.message ?? '无法解析这本书',
        ),
      ];
    }
  }

  Future<String> decodeText(String path, {String encoding = 'auto'}) async {
    if (_desktopDocuments) return _desktop.decodeText(path, encoding: encoding);
    return (await channel.invokeMethod<String>('decodeText', {
      'path': path,
      'encoding': encoding,
    }))!;
  }

  Future<String> decodeTextFile(
    String path, {
    String encoding = 'auto',
  }) async {
    if (_desktopDocuments) {
      return _desktop.decodeTextFile(path, encoding: encoding);
    }
    return (await channel.invokeMethod<String>('decodeTextFile', {
      'path': path,
      'encoding': encoding,
    }))!;
  }

  Future<Map<String, dynamic>?> connect({required bool create}) async {
    if (_desktopDocuments) return _desktop.connect(create: create);
    return channel.invokeMapMethod<String, dynamic>(
      create ? 'createSync' : 'openSync',
    );
  }

  Future<Map<String, dynamic>?> info() async {
    if (_desktopDocuments) return _desktop.info();
    return channel.invokeMapMethod<String, dynamic>('syncInfo');
  }

  Future<({File before, File output})> read() async {
    final value = _desktopDocuments
        ? await _desktop.readSync()
        : await channel.invokeMapMethod<String, dynamic>('readSync');
    if (value == null) throw const FormatException('无法读取云同步文件');
    return (before: File(value['path']), output: File(value['outputPath']));
  }

  Future<void> write(File before, File next) async {
    if (_desktopDocuments) {
      return _desktop.writeSync(next.path, before.path);
    }
    return channel.invokeMethod<void>(
      'writeSync',
      {'path': next.path, 'expectedPath': before.path},
    );
  }

  Future<void> disconnect() async {
    if (_desktopDocuments) return _desktop.disconnectSync();
    return channel.invokeMethod<void>('disconnectSync');
  }

  Future<File?> recovery(String which) async {
    final path = _desktopDocuments
        ? await _desktop.recoverSync(which)
        : await channel.invokeMethod<String>('recoverSync', {'which': which});
    return path == null ? null : File(path);
  }
}
