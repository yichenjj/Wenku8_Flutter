import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_docx_import.dart';
import 'book_import_limits.dart';
import 'book_mobi_import.dart';
import 'book_pdf_import.dart';
import 'legacy/gbk_codec.dart';

/// Linux implementation of the book-documents contract. There is no SAF: a
/// picked file keeps its real path, scanning walks the chosen directory, and
/// cloud sync reads/writes a plain document with recovery snapshots.
class DesktopBookDocuments {
  static const _maxSync = 256 * 1024 * 1024;
  static const _maxArchive = maxLocalEpubBytes;
  static const _maxExpanded = 1024 * 1024 * 1024;
  static const _maxDecode = 40 * 1024 * 1024;
  static const _kindle = {'mobi', 'azw', 'azw3', 'prc'};
  static const _markup = {
    'fb2', 'docx', 'html', 'htm', 'xhtml', 'md', 'markdown', 'rtf', 'pdf',
  };
  static const _extensions = {..._kindle, ..._markup, 'txt', 'epub', 'zip'};
  static const _maxBooksPerArchive = 200;
  static const _maxArchiveEntries = 12000;
  static const _maxDocuments = 200000;
  static const _importedPrefix = 'book_scan_folders.';

  final _entries = <String, _FolderBookNode>{};
  final _pendingMarks = <String, String>{};
  Map<String, String>? _importedIndex;
  Directory? _staging;
  SharedPreferences? _preferences;

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  Future<Directory> get _support async =>
      (await getApplicationSupportDirectory()).create(recursive: true);

  Future<Directory> get _stagingRoot async {
    final staging = _staging;
    if (staging != null) return staging;
    return _staging = Directory(
      '${(await _support).path}/import-staging',
    )..createSync(recursive: true);
  }

  // ---------------------------------------------------------------- pickers

  static const _bookTypeGroup = XTypeGroup(
    label: '电子书与文档',
    extensions: [
      'txt', 'epub', 'zip', 'mobi', 'azw', 'azw3', 'prc', 'fb2', 'pdf',
      'docx', 'rtf', 'html', 'htm', 'xhtml', 'md', 'markdown',
    ],
  );
  static const _fontTypeGroup = XTypeGroup(
    label: '字体文件',
    extensions: ['ttf', 'otf', 'ttc', 'woff', 'woff2'],
  );

  Future<Map<String, dynamic>?> pickFont() async {
    final file = await openFile(acceptedTypeGroups: const [_fontTypeGroup]);
    if (file == null) return null;
    return {'name': file.name, 'path': file.path};
  }

  Future<({String name, String path})?> pickBook() async {
    final file = await openFile(acceptedTypeGroups: const [_bookTypeGroup]);
    if (file == null) return null;
    return (name: file.name, path: file.path);
  }

  Future<List<Map<String, dynamic>>> pickBooks() async {
    final files = await openFiles(acceptedTypeGroups: const [_bookTypeGroup]);
    return [
      for (final file in files) {'name': file.name, 'path': file.path},
    ];
  }

  // ---------------------------------------------------------------- scanning

  Future<String?> get _scanPath async =>
      (await _prefs).getString('${_importedPrefix}path');

  Future<Map<String, String>> _savedIndex() async {
    if (_importedIndex != null) return _importedIndex!;
    final raw = (await _prefs).getString('${_importedPrefix}imported') ?? '{}';
    try {
      return _importedIndex = Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return _importedIndex = {};
    }
  }

  Future<void> _persistIndex() async {
    final index = await _savedIndex();
    if (!(await (await _prefs).setString(
      '${_importedPrefix}imported',
      jsonEncode(index),
    ))) {
      throw const FormatException('扫描记录保存失败');
    }
  }

  Future<Map<String, dynamic>?> scanFolderInfo() async {
    final path = await _scanPath;
    if (path == null) return null;
    final preferences = await _prefs;
    return {
      'name': preferences.getString('${_importedPrefix}name') ?? '书籍文件夹',
      'automatic': preferences.getBool('${_importedPrefix}automatic') ?? false,
      'readable': Directory(path).existsSync(),
    };
  }

  Future<Map<String, dynamic>?> selectScanFolder() async {
    final path = await getDirectoryPath(confirmButtonText: '选择书籍文件夹');
    if (path == null) return null;
    final preferences = await _prefs;
    final old = preferences.getString('${_importedPrefix}path');
    final directory = Directory(path);
    if (!directory.existsSync()) {
      throw const FormatException('请选择一个可读取的书籍文件夹');
    }
    if (!(await preferences.setString('${_importedPrefix}path', path))) {
      throw const FormatException('文件夹设置保存失败');
    }
    await preferences.setString(
      '${_importedPrefix}name',
      path.split(Platform.pathSeparator).where((part) => part.isNotEmpty).last,
    );
    await preferences.setBool('${_importedPrefix}all', false);
    if (old != null && old != path) {
      await preferences.remove('${_importedPrefix}imported');
      _importedIndex = null;
    }
    _entries.clear();
    return scanFolderInfo();
  }

  /// Desktops have no shared-storage grant; picking a folder is the way.
  Future<Map<String, dynamic>> selectAllScan() => throw const FormatException(
    '桌面版没有共享存储授权，请直接选择书籍文件夹',
  );

  Future<void> setScanAutomatic(bool value) async {
    if (!(await (await _prefs).setBool('${_importedPrefix}automatic', value))) {
      throw const FormatException('扫描设置保存失败');
    }
  }

  Future<void> disconnectScanFolder() async {
    final preferences = await _prefs;
    const keys = ['path', 'name', 'automatic', 'formats', 'imported', 'all'];
    for (final key in keys) {
      await preferences.remove('$_importedPrefix$key');
    }
    _importedIndex = null;
    _entries.clear();
  }

  Set<String> _defaultFormats() =>
      _extensions.map((extension) => bookFormatKey('book.$extension')).toSet();

  Future<Set<String>> scanFormats() async {
    final saved =
        (await _prefs).getStringList('${_importedPrefix}formats');
    if (saved == null || saved.isEmpty) return _defaultFormats();
    return saved.map(bookFormatKey).toSet();
  }

  Future<void> setScanFormats(Set<String> formats) async {
    final extensions = bookFormatExtensions(formats)
        .map((extension) => extension.toLowerCase())
        .toSet();
    if (extensions.isEmpty || !_extensions.containsAll(extensions)) {
      throw const FormatException('请至少选择一种支持的格式');
    }
    if (!(await (await _prefs).setStringList(
      '${_importedPrefix}formats',
      extensions.toList(),
    ))) {
      throw const FormatException('扫描格式保存失败');
    }
  }

  Set<String> _chosenFormats(Set<String> defaults) {
    final saved =
        _preferences?.getStringList('${_importedPrefix}formats');
    if (saved == null || saved.isEmpty) return defaults;
    return saved.toSet();
  }

  /// Breadth-first metadata walk; one unreadable subfolder keeps healthy books.
  Future<BookFolderIndexResult> _collect(
    String root,
    Set<String> extensions,
  ) async {
    final queue = <List<String>>[[
      root,
      '所选文件夹',
    ]];
    final visited = <String>{};
    final books = <_FolderBookNode>[];
    final warnings = <String>[];
    var count = 0;
    while (queue.isNotEmpty) {
      final [parent, label] = queue.removeAt(0);
      if (!visited.add(parent)) continue;
      List<FileSystemEntity> children;
      try {
        children = Directory(parent).listSync(followLinks: false);
      } catch (_) {
        if (parent == root) rethrow;
        warnings.add('$label：无法读取，请检查文件夹权限');
        continue;
      }
      final sorted = children.toList()
        ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      for (final child in sorted) {
        if (++count > _maxDocuments) {
          warnings.add('文件过多，请选择更小的书籍文件夹继续扫描');
          return BookFolderIndexResult(books, warnings);
        }
        final name = child.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.')) continue;
        if (child is Directory) {
          queue.add([child.path, name]);
        } else if (_supported(name) &&
            extensions.contains(name.split('.').last.toLowerCase()) &&
            visited.add(child.path)) {
          final stat = child.statSync();
          books.add(_FolderBookNode(
            path: child.path,
            name: name,
            size: stat.size,
            modified: stat.modified.millisecondsSinceEpoch,
          ));
        }
      }
    }
    return BookFolderIndexResult(books, warnings);
  }

  Future<Map<String, dynamic>> scanBooks() async {
    await finishBookScan();
    final root = await _scanPath;
    if (root == null) throw const FormatException('请先选择书籍文件夹');
    if (!Directory(root).existsSync()) {
      throw const FormatException('文件夹访问权限已失效，请重新选择文件夹');
    }
    _entries.clear();
    final formats = _chosenFormats(_extensions);
    final index = await _collect(root, formats);
    final imported = await _savedIndex();
    var unchanged = 0;
    final books = <Map<String, dynamic>>[];
    for (final book in index.books) {
      if (imported[_sourceKey(book.path)] == book.revision) {
        unchanged++;
        continue;
      }
      final token = _token();
      _entries[token] = book;
      final parent = book.path.substring(0, book.path.length - book.name.length);
      final folder = parent
          .split(Platform.pathSeparator)
          .where((part) => part.isNotEmpty)
          .last;
      books.add({
        'token': token,
        'name': book.name,
        'size': book.size,
        'folder': folder.length > 240 ? folder.substring(folder.length - 240) : folder,
      });
    }
    return {
      'books': books,
      'unchanged': unchanged,
      'total': index.books.length,
      'warnings': index.warnings,
    };
  }

  Future<Map<String, dynamic>> stageScanBook(String token) async {
    final node = _entries[token];
    if (node == null) {
      throw const FormatException('扫描结果已过期，请重新扫描');
    }
    final limit = _limitFor(node.name);
    if (node.size > limit) throw const FormatException('书籍文件过大');
    // Real filesystem paths stay readable, so no staging copy is needed.
    return {'name': node.name, 'path': node.path};
  }

  Future<void> markScanBook(String token) async {
    final node = _entries[token];
    if (node == null) {
      throw const FormatException('扫描结果已过期，下次扫描会再次检查');
    }
    (await _savedIndex())[_sourceKey(node.path)] = node.revision;
    _pendingMarks[node.path] = node.revision;
    if (_pendingMarks.length >= 16) await finishBookScan();
  }

  Future<void> finishBookScan() async {
    if (_pendingMarks.isEmpty) return;
    await _persistIndex();
    _pendingMarks.clear();
  }

  String _sourceKey(String path) => 'folder:$path';

  // --------------------------------------------------------------- preparing

  Future<List<Map<String, dynamic>>> prepareBook(
    String name,
    String path,
  ) async {
    if (!_supported(name)) {
      throw const FormatException('请选择支持的电子书或文档格式');
    }
    final source = File(path);
    if (!source.existsSync() || source.lengthSync() == 0) {
      throw const FormatException('文件为空，请重新下载原书');
    }
    final limit = _limitFor(name);
    if (source.lengthSync() > limit) {
      throw FormatException(
        '单个 ${name.split('.').last.toUpperCase()} 不能超过 ${limit ~/ (1024 * 1024)} MiB',
      );
    }
    final kind = name.split('.').last.toLowerCase();
    if (kind == 'zip') return _unpack(name, source);
    if (_kindle.contains(kind)) {
      return _convert(name, source, (work, output) {
        BookMobiImport(work).convert(source, output);
      });
    }
    if (kind == 'docx') {
      return _convert(name, source, (work, output) {
        BookDocxImport(work).convert(source, output);
      });
    }
    if (kind == 'pdf') {
      return _convert(name, source, (work, output) {
        BookPdfImport(work).convert(source, output);
      });
    }
    if (_markup.contains(kind)) {
      throw const FormatException('该文档格式暂不支持桌面版，请使用 TXT / EPUB / ZIP');
    }
    return [
      {'name': name, 'path': path},
    ];
  }

  /// Runs a format converter into the staging area, mirroring the Android
  /// `convert()` contract: the result keeps its original stem with an .epub
  /// extension, and failures clean up both the work directory and the output.
  Future<List<Map<String, dynamic>>> _convert(
    String name,
    File source,
    void Function(Directory work, File output) run,
  ) async {
    final staging = await _stagingRoot;
    final work = Directory(
      '${staging.path}/convert-${_token()}',
    )..createSync(recursive: true);
    final output = await _stagedFile();
    try {
      run(work, output);
      if (!output.existsSync() || output.lengthSync() == 0) {
        throw const FormatException('文件为空，请重新下载原书');
      }
      return [
        {
          'name':
              '${name.substring(0, name.lastIndexOf('.'))}.epub',
          'path': output.path,
        },
      ];
    } on FormatException {
      _cleanupConversion(work, output);
      rethrow;
    } catch (_) {
      _cleanupConversion(work, output);
      throw const FormatException('无法读取该文件，请检查文件是否损坏');
    } finally {
      try {
        work.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  void _cleanupConversion(Directory work, File output) {
    if (output.existsSync()) output.deleteSync();
  }

  Future<List<Map<String, dynamic>>> _unpack(
    String name,
    File source,
  ) async {
    final prepared = <Map<String, dynamic>>[];
    Archive? archive;
    try {
      final bytes = source.readAsBytesSync();
      archive = ZipDecoder().decodeBytes(bytes, verify: false);
      final entries = archive.files.toList();
      if (entries.length > _maxArchiveEntries) {
        throw const FormatException('压缩包文件过多');
      }
      var declared = 0;
      for (final entry in entries) {
        if (entry.name.startsWith('/') ||
            entry.name.contains('\\') ||
            entry.name.split('/').contains('..')) {
          throw const FormatException('压缩包包含无效路径');
        }
        declared += entry.size;
        if (declared > _maxExpanded) {
          throw const FormatException('压缩包解压后超过 1 GiB');
        }
      }
      final books = entries
          .where(
            (entry) => entry.isFile &&
                !entry.name.split('/').any(
                      (part) => part.startsWith('.') || part == '__MACOSX',
                    ) &&
                _supported(entry.name) &&
                !entry.name.toLowerCase().endsWith('.zip'),
          )
          .toList();
      if (books.isEmpty) {
        throw const FormatException('压缩包内没有支持的书籍或文档');
      }
      if (books.length > _maxBooksPerArchive) {
        throw const FormatException('一个压缩包最多导入 200 本书');
      }
      var expanded = 0;
      for (final entry in books) {
        final entryName = entry.name.split('/').last;
        try {
          final limit = _limitFor(entryName);
          if (entry.size <= 0 || entry.size > limit) {
            throw const FormatException('书籍为空或超过大小限制');
          }
          expanded += entry.size;
          if (expanded > _maxExpanded) {
            throw const FormatException('书籍解压后超过大小限制');
          }
          final target = await _stagedFile();
          await target.writeAsBytes(entry.content as List<int>, flush: true);
          prepared.add({'name': entryName, 'path': target.path});
        } catch (error) {
          prepared.add({
            'name': entryName,
            'error': error is FormatException
                ? error.message
                : '无法读取压缩包中的书籍，请检查文件与剩余空间',
          });
        }
      }
      return prepared;
    } on FormatException {
      for (final item in prepared) {
        final path = item['path'] as String?;
        if (path != null) File(path).deleteSync();
      }
      rethrow;
    } catch (_) {
      for (final item in prepared) {
        final path = item['path'] as String?;
        if (path != null) File(path).deleteSync();
      }
      throw const FormatException('ZIP 已损坏、已加密或使用了不支持的压缩方式');
    } finally {
      archive?.clear();
    }
  }

  Future<File> _stagedFile() async {
    final staging = await _stagingRoot;
    final token = _token();
    return File('${staging.path}/import-$token.source');
  }

  static bool _supported(String name) =>
      RegExp(
        r'\.(txt|epub|mobi|azw|azw3|prc|fb2|pdf|docx|rtf|html?|xhtml|md|markdown|zip)$',
        caseSensitive: false,
      ).hasMatch(name);

  static int _limitFor(String name) => switch (name.split('.').last.toLowerCase()) {
        'zip' => _maxArchive,
        'epub' || 'pdf' || 'docx' => maxLocalEpubBytes,
        'mobi' || 'azw' || 'azw3' || 'prc' => 256 * 1024 * 1024,
        'html' || 'htm' || 'xhtml' || 'md' || 'markdown' => 32 * 1024 * 1024,
        _ => maxLocalTextBytes,
      };

  /// Android releases SAF staging copies only; originals never match the
  /// staging pattern and stay untouched on every platform.
  Future<void> releaseBooks(Iterable<String?> paths) async {
    final staging = (await _stagingRoot).path;
    for (final path in paths.nonNulls.toSet()) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final parent = file.parent.path;
      final name = file.path.split(Platform.pathSeparator).last;
      if (parent == staging && name.startsWith('import-')) {
        file.deleteSync();
      }
    }
  }

  // ------------------------------------------------------------ text decode

  Future<String> decodeText(String path, {String encoding = 'auto'}) async {
    final source = File(path);
    if (!source.existsSync()) throw const FormatException('文件不存在或已被移动');
    final bytes = source.readAsBytesSync();
    if (bytes.length > _maxDecode) {
      throw const FormatException('单本 TXT 不能超过 40 MiB');
    }
    return _decodeBytes(bytes, encoding).replaceFirst('\uFEFF', '');
  }

  Future<String> decodeTextFile(
    String path, {
    String encoding = 'auto',
  }) async {
    final source = File(path);
    if (!source.existsSync()) throw const FormatException('文件不存在或已被移动');
    final bytes = source.readAsBytesSync();
    if (bytes.length > maxLocalTextBytes) {
      throw const FormatException('单本 TXT 需要在 128 MiB 以内');
    }
    final target = await _stagedFile();
    try {
      final normalized = encoding == 'auto'
          ? _decodeBytes(bytes, 'auto')
          : _decodeForced(bytes, encoding);
      await target.writeAsString(normalized, flush: true);
      return target.path;
    } on FormatException catch (failure) {
      if (failure.message == '文本编码无法识别') rethrow;
      if (encoding != 'auto') rethrow;
      // Auto detection fell back already; the text stays undecodable.
      throw const FormatException('文本编码无法识别，请在书库设置选择正确的 TXT 编码后重试');
    } catch (_) {
      throw const FormatException('文本编码无法识别，请在书库设置选择正确的 TXT 编码后重试');
    }
  }

  static String _decodeBytes(List<int> bytes, String requested) {
    if (requested != 'auto') return _decodeForced(bytes, requested);
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: false);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return Gbk.decode(bytes);
    }
  }

  static String _decodeForced(List<int> bytes, String requested) {
    switch (requested) {
      case 'UTF-8':
      case 'utf-8':
        return utf8.decode(bytes);
      case 'UTF-16LE':
      case 'utf-16le':
        return _decodeUtf16(_withoutBom(bytes, [0xff, 0xfe]), littleEndian: true);
      case 'UTF-16BE':
      case 'utf-16be':
        return _decodeUtf16(_withoutBom(bytes, [0xfe, 0xff]), littleEndian: false);
      case 'GB18030':
      case 'gb18030':
        return Gbk.decode(bytes);
      default:
        throw const FormatException('不支持的文本编码');
    }
  }

  static List<int> _withoutBom(List<int> bytes, List<int> bom) =>
      bytes.length >= 2 && bytes[0] == bom[0] && bytes[1] == bom[1]
          ? bytes.sublist(2)
          : bytes;

  static String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    final units = StringBuffer();
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final high = littleEndian ? bytes[i] : bytes[i + 1];
      final low = littleEndian ? bytes[i + 1] : bytes[i];
      units.writeCharCode(high << 8 | low);
    }
    return units.toString();
  }

  // ------------------------------------------------------------- cloud sync

  static const _syncFileExtension = 'wenku8sync';
  static const _syncKeys = ['path', 'created'];

  Future<Map<String, dynamic>?> connect({required bool create}) async {
    String path;
    String name;
    if (create) {
      final location = await getSaveLocation(
        suggestedName: '文库同步.$_syncFileExtension',
        acceptedTypeGroups: const [
          XTypeGroup(label: '文库同步文档', extensions: [_syncFileExtension]),
        ],
      );
      if (location == null) return null;
      path = location.path;
      name = path.split(Platform.pathSeparator).last;
      final file = File(path);
      if (!file.existsSync()) file.createSync(recursive: true);
    } else {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: '文库同步文档', extensions: [_syncFileExtension]),
        ],
      );
      if (file == null) return null;
      path = file.path;
      name = file.name;
    }
    final preferences = await _prefs;
    await preferences.setString('book_sync_documents.path', path);
    await preferences.setBool('book_sync_documents.created', create);
    return {
      'name': name,
      'authority': 'local',
      'provider': '本地文件',
      'created': create,
    };
  }

  Future<Map<String, dynamic>?> info() async {
    final path = (await _prefs).getString('book_sync_documents.path');
    if (path == null) return null;
    return {
      'name': path.split(Platform.pathSeparator).last,
      'authority': 'local',
      'provider': '本地文件',
      'created': (await _prefs).getBool('book_sync_documents.created') ?? false,
    };
  }

  Future<File> get _syncTarget async {
    final path = (await _prefs).getString('book_sync_documents.path');
    if (path == null) throw const FormatException('请先连接云同步文件');
    return File(path);
  }

  Future<void> _copyInto(File source, File target, int limit) async {
    final bytes = source.readAsBytesSync();
    if (bytes.length > limit) throw const FormatException('同步文件过大');
    await target.writeAsBytes(bytes, flush: true);
  }

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<Map<String, dynamic>> readSync() async {
    final target = await _syncTarget;
    final support = await _support;
    final snapshot = File('${support.path}/cloud-before.$_syncFileExtension');
    await _copyInto(target, snapshot, _maxSync);
    return {
      'path': snapshot.path,
      'size': snapshot.lengthSync(),
      'outputPath': '${support.path}/cloud-next.$_syncFileExtension',
    };
  }

  Future<void> writeSync(String path, String expectedPath) async {
    final target = await _syncTarget;
    if (!target.parent.existsSync()) {
      throw const FormatException('所选云文档不支持写入，请换一个文件');
    }
    final next = File(path);
    final before = File(expectedPath);
    if (next.existsSync() &&
        (next.lengthSync() <= 0 || next.lengthSync() > _maxSync)) {
      throw const FormatException('同步文件过大');
    }
    final support = await _support;
    final fresh = File('${support.path}/cloud-check.$_syncFileExtension');
    await _copyInto(target, fresh, _maxSync);
    if (!_equal(before.readAsBytesSync(), fresh.readAsBytesSync())) {
      throw const FormatException('云端文件已发生变化，请重新同步');
    }
    // Retain both recoverable snapshots before a provider write.
    final recovery = Directory('${support.path}/sync-recovery')
      ..createSync(recursive: true);
    await before.copy('${recovery.path}/cloud-before.$_syncFileExtension');
    await next.copy('${recovery.path}/cloud-next.$_syncFileExtension');
    try {
      await next.copy(target.path);
    } catch (_) {
      throw const FormatException('无法写入云端文件，恢复副本已保留');
    }
    final after = File('${support.path}/cloud-after.$_syncFileExtension');
    await _copyInto(target, after, _maxSync);
    if (!_equal(next.readAsBytesSync(), after.readAsBytesSync())) {
      throw const FormatException('云端写入未完整确认，恢复副本已保留');
    }
    await (await _prefs).setBool('book_sync_documents.created', false);
  }

  Future<void> disconnectSync() async {
    final preferences = await _prefs;
    for (final key in _syncKeys) {
      await preferences.remove('book_sync_documents.$key');
    }
    await preferences.remove('book_sync_documents.path');
  }

  Future<String?> recoverSync(String which) async {
    if (which != 'before' && which != 'next') {
      throw ArgumentError('invalid recovery snapshot');
    }
    final support = await _support;
    final recovery = File('${support.path}/sync-recovery/cloud-$which.$_syncFileExtension');
    if (!recovery.existsSync()) return null;
    final copy = File('${support.path}/recovery.$_syncFileExtension');
    await recovery.copy(copy.path);
    return copy.path;
  }

  static String _token() {
    final random = Random.secure();
    final bytes = Uint8List(16)..setAll(0, [
      for (var i = 0; i < 16; i++) random.nextInt(256),
    ]);
    return md5.convert(bytes).toString();
  }
}

class _FolderBookNode {
  const _FolderBookNode({
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
  });

  final String path, name;
  final int size, modified;

  String get revision => '$size:$modified';
}

class BookFolderIndexResult {
  const BookFolderIndexResult(this.books, this.warnings);

  final List<_FolderBookNode> books;
  final List<String> warnings;
}
