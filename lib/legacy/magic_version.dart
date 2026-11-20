import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Bridge to the v1.30 API runtime (`libcpp.so`, extracted from the original
/// app). The relay signs every request with a time-bucketed version token that
/// only this runtime can derive, so the Linux client loads the same library the
/// Android build injects, patched to bind against glibc (tools/patch_libcpp.py).
///
/// The runtime expects a JNI environment; a minimal fake environment covers the
/// string functions the entry point uses. Everything runs synchronously on the
/// calling isolate's thread, which is what a JNI call expects.
abstract final class MagicVersion {
  static bool _ready = false;
  static Pointer<Pointer<Void>>? _envCell;
  static Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)?
      _entry;
  static Pointer<Uint8>? _input;
  static String? _captured;

  /// Whether the injected runtime exists in this build; false on source-only
  /// builds, which keep the demo catalogue.
  static bool get available {
    final executable = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      Platform.environment['WENKU8_RUNTIME_PATH'],
      '$executable/lib/libcpp_patched.so',
      'libcpp_patched.so',
      'lib/libcpp_patched.so',
    ];
    return candidates.nonNulls.any((path) => File(path).existsSync());
  }

  static void _ensureLoaded() {
    if (_ready) return;
    final executable = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      Platform.environment['WENKU8_RUNTIME_PATH'],
      '$executable/lib/libcpp_patched.so',
      'libcpp_patched.so',
      'lib/libcpp_patched.so',
    ].nonNulls;
    final path = candidates.firstWhere(
      (candidate) => File(candidate).existsSync(),
      orElse: () => throw StateError('API runtime libcpp_patched.so 未随应用打包'),
    );
    final lib = DynamicLibrary.open(path);

    final table = calloc<Pointer<Void>>(256);
    Pointer<Void> entry(Pointer<NativeFunction> pointer) =>
        Pointer<Void>.fromAddress(pointer.address);
    // JNI function table indices follow jni.h's declared order.
    table[6] = entry(Pointer.fromFunction<NativeFindClass>(_findClass));
    table[14] = entry(Pointer.fromFunction<NativeThrowNew>(_throwNew, 0));
    table[15] = entry(Pointer.fromFunction<NativeThrowNew>(_throwNew, 0));
    table[167] = entry(Pointer.fromFunction<NativeNewStringUtf>(_newStringUtf));
    table[169] = entry(Pointer.fromFunction<NativeGetStringChars>(_getStringChars));
    table[170] = entry(
        Pointer.fromFunction<NativeReleaseStringChars>(_releaseStringChars));

    // JNIEnv* points at a cell holding the function-table pointer.
    final envCell = calloc<Pointer<Void>>();
    envCell.value = Pointer<Void>.fromAddress(table.address);

    _envCell = envCell;
    _entry = lib
        .lookup<
            NativeFunction<
                Pointer<Void> Function(Pointer<Void>, Pointer<Void>,
                    Pointer<Void>)>>(
            'Java_org_mewx_wenku8_api_TokenManager_getMagicVersionCpp')
        .asFunction();
    _ready = true;
  }

  /// Returns the runtime's signed version token for [version].
  static String call(String version) {
    _ensureLoaded();
    final units = utf8.encode(version);
    final input = calloc<Uint8>(units.length + 1);
    try {
      input.asTypedList(units.length + 1).setAll(0, [...units, 0]);
      _input = input;
      _captured = null;
      _entry!(_envCell!.cast(), nullptr, input.cast());
      final value = _captured;
      if (value == null) throw StateError('API runtime 未返回版本签名');
      return value;
    } finally {
      _input = null;
      calloc.free(input);
    }
  }

  static Pointer<Uint8> _getStringChars(
    Pointer<Void> env,
    Pointer<Void> string,
    Pointer<Uint8> isCopy,
  ) {
    return _input ?? Pointer<Uint8>.fromAddress(0);
  }

  static void _releaseStringChars(
    Pointer<Void> env,
    Pointer<Void> string,
    Pointer<Uint8> chars,
  ) {}

  static Pointer<Void> _newStringUtf(Pointer<Void> env, Pointer<Uint8> bytes) {
    if (bytes != nullptr) {
      final text = <int>[];
      for (var i = 0; bytes[i] != 0; i++) {
        text.add(bytes[i]);
      }
      _captured = utf8.decode(text);
    }
    return Pointer<Void>.fromAddress(0x1234);
  }

  static Pointer<Void> _findClass(Pointer<Void> env, Pointer<Uint8> name) =>
      Pointer<Void>.fromAddress(0x5678);

  static int _throwNew(
    Pointer<Void> env,
    Pointer<Void> clazz,
    Pointer<Uint8> message,
  ) {
    // Java exceptions would surface on Android as LEGACY_API_ERROR; the same
    // wrapping happens around RelayClient on Linux.
    return 0;
  }
}

typedef NativeFindClass = Pointer<Void> Function(
    Pointer<Void>, Pointer<Uint8>);
typedef NativeThrowNew = Int32 Function(
    Pointer<Void>, Pointer<Void>, Pointer<Uint8>);
typedef NativeNewStringUtf = Pointer<Void> Function(
    Pointer<Void>, Pointer<Uint8>);
typedef NativeGetStringChars = Pointer<Uint8> Function(
    Pointer<Void>, Pointer<Void>, Pointer<Uint8>);
typedef NativeReleaseStringChars = Void Function(
    Pointer<Void>, Pointer<Void>, Pointer<Uint8>);
