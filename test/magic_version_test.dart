import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/legacy/magic_version.dart';

void main() {
  test('API runtime derives the signed version token', () {
    final token = MagicVersion.call('1.30');
    expect(token, startsWith('1.30-'));
    // <version>-<word pair>-<eight hex digits>.
    expect(
      RegExp(r'^1\.30-[a-z-]+-[0-9a-f]{8}$').hasMatch(token),
      isTrue,
      reason: 'unexpected token shape: $token',
    );
    // A different release string maps to a different token.
    expect(MagicVersion.call('1.29'), isNot(MagicVersion.call('1.30')));
  }, skip: Platform.environment['WENKU8_RUNTIME_PATH'] == null
      ? 'API runtime not injected (set WENKU8_RUNTIME_PATH)'
      : null);
}
