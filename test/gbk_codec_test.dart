import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/legacy/gbk_codec.dart';

void main() {
  test('encode matches CP936 reference bytes', () {
    // Cross-checked against the Python "gbk" codec.
    expect(Gbk.tryEncode('轻'), [0xc7, 0xe1]);
    expect(Gbk.tryEncode('小说文库'),
        [0xd0, 0xa1, 0xcb, 0xb5, 0xce, 0xc4, 0xbf, 0xe2]);
    expect(Gbk.tryEncode('ABC123'), [0x41, 0x42, 0x43, 0x31, 0x32, 0x33]);
  });

  test('decode round-trips two-byte sequences', () {
    expect(Gbk.decode([0xc7, 0xe1, 0x41]), '轻A');
    // An unpaired lead byte degrades instead of throwing.
    expect(Gbk.decode([0xc7]), '\uFFFD');
  });

  test('urlEncode follows the JVM URLEncoder shape', () {
    expect(Gbk.urlEncode('ab 中文'), 'ab+%D6%D0%CE%C4');
    expect(Gbk.urlEncode('a.b-c*d_e'), 'a.b-c*d_e');
    expect(Gbk.urlEncode('轻'), '%C7%E1');
  });

  test('canEncode rejects characters outside the encoding', () {
    expect(Gbk.canEncode('中文……·'), isTrue);
    expect(Gbk.tryEncode('……·'), [0xa1, 0xad, 0xa1, 0xad, 0xa1, 0xa4]);
    expect(Gbk.canEncode('😀'), isFalse);
    expect(Gbk.tryEncode('😀'), isNull);
  });
}
