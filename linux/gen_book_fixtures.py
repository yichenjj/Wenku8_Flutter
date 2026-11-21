#!/usr/bin/env python3
"""Generate the desktop-converter test fixtures under test/fixtures/.

The fixtures are produced with independent Python implementations (PalmDOC
compression, OCF/OPC packaging, raw PDF layout), so the Dart tests validate
the converters against something other than themselves.

Usage: python3 linux/gen_book_fixtures.py test/fixtures
"""

import os
import struct
import sys
import zipfile


# ------------------------------------------------------------------ MOBI

def palm_doc_compress(data: bytes) -> bytes:
    """Literal-only PalmDOC stream: runs and direct bytes, no pairs."""
    out = bytearray()
    run = bytearray()

    def flush_run():
        while run:
            chunk = run[:8]
            del run[:8]
            out.append(len(chunk))
            out.extend(chunk)

    for byte in data:
        if 0x09 <= byte <= 0x7f or byte == 0x00:
            flush_run()
            out.append(byte)
        else:
            # 0x01-0x08 are run markers, 0x80-0xbf are pair tokens, and
            # 0xc0-0xff mean "space + char" — all need the literal-run escape.
            run.append(byte)
    flush_run()
    return bytes(out)


def backwards_varint(value: int) -> bytes:
    return bytes(((value >> 21) & 0x7f, (value >> 14) & 0x7f,
                  (value >> 7) & 0x7f, value & 0x7f))


def build_mobi(path, html: bytes, *, compression=2, encryption=0,
               extra_flags=0, image: bytes = None, title='夹具书目',
               author='夹具作者', encoding=65001):
    records = []
    # Text records: 4096-byte chunks (recordSize field); extra data appended
    # per record when extra_flags says so.
    text_records = []
    for i in range(0, len(html), 4096):
        chunk = html[i:i + 4096]
        payload = palm_doc_compress(chunk) if compression == 2 else chunk
        if extra_flags & 1:
            # Multibyte overlap marker sits right after the payload; last
            # byte & 3 gives the overlap count minus one, so a zero marker
            # strips exactly itself.
            payload = payload + b'\x00'
        if extra_flags & 2:
            # One trailing entry at the very end: a two-byte payload plus its
            # own size, backwards-encoded in the final four bytes.
            payload = payload + b'\x01\x02' + backwards_varint(6)
        text_records.append(payload)
    records.extend(text_records)
    if image:
        records.append(image)

    count = len(text_records)
    record0 = bytearray()
    record0 += struct.pack('>HHIHHHH', compression, 0, len(html), count,
                           4096, encryption, 0)
    mobi = bytearray()
    mobi += b'MOBI'
    mobi += struct.pack('>IIIII', 0xe8, 2, encoding, 1, 6)
    mobi += b'\x00' * (0x50 - 0x28)          # indexes + reserved
    mobi += struct.pack('>I', count + 1)     # first non-book index 0x50
    full_name = title.encode('utf-8') if encoding == 65001 else title.encode('cp1252')
    name_offset = 16 + 0xe8 + 0  # right after the MOBI header; EXTH may follow
    exth = bytearray()
    if author:
        author_data = author.encode('utf-8' if encoding == 65001 else 'cp1252')
        exth += struct.pack('>II', 100, len(author_data) + 8) + author_data
        exth += struct.pack('>II', 503, len(full_name) + 8) + full_name
        exth_count = 2
    else:
        exth_count = 0
    if exth:
        exth_header = b'EXTH' + struct.pack('>II', len(bytes(exth)) + 12,
                                            exth_count)
        name_offset = 16 + 0xe8 + len(exth_header) + len(exth)
    mobi += struct.pack('>II', name_offset, len(full_name))  # 0x54/0x58
    mobi += struct.pack('>I', 0x409)                         # locale 0x5c
    mobi += struct.pack('>I', 0)                             # input locale
    mobi += struct.pack('>I', 0)                             # output locale
    mobi += struct.pack('>I', 6)                             # min version 0x68
    mobi += struct.pack('>I', count + 1 if image else 0xffffffff)  # 0x6c
    mobi += struct.pack('>I', 0) * 4                          # huff fields 0x70
    mobi += struct.pack('>I', 0x40 if exth else 0)            # EXTH flags 0x80
    mobi += b'\x00' * (0xe8 - (0x84 - 0x10))                  # pad to 0xe8 header
    record0 += bytes(mobi)
    if exth:
        record0 += exth_header + bytes(exth)
    record0 += struct.pack('>I', 0)                          # name pad
    record0 += full_name
    if extra_flags:
        # extra record data flags live at 16 + headerLength - 4.
        flags_offset = 16 + 0xe8 - 4
        record0[flags_offset:flags_offset + 4] = struct.pack('>I', extra_flags)
    records.insert(0, bytes(record0))

    _write_pdb(path, records, type=b'BOOK', creator=b'MOBI',
               title=title)


def build_prc(path, text: bytes):
    records = []
    count = (len(text) + 4095) // 4096
    record0 = struct.pack('>HHIHHHH', 1, 0, len(text), count, 4096, 0, 0)
    records.append(record0)
    for i in range(0, len(text), 4096):
        records.append(text[i:i + 4096])
    _write_pdb(path, records, type=b'TEXt', creator=b'REAd', title='plain prc')


def _write_pdb(path, records, *, type, creator, title):
    header = bytearray()
    header += title.encode('utf-8')[:31].ljust(32, b'\x00')
    header += struct.pack('>HH', 0, 0)
    header += struct.pack('>III', 0, 0, 0)
    header += struct.pack('>I', 0)      # mod number
    header += struct.pack('>II', 0, 0)  # app/sort info
    header += type + creator
    header += struct.pack('>II', 0, 0)  # unique id seed, next record list
    header += struct.pack('>H', len(records))
    offsets = []
    cursor = 78 + len(records) * 8 + 2
    for record in records:
        offsets.append(cursor)
        cursor += len(record)
    for offset in offsets:
        header += struct.pack('>II', offset, 0)  # offset + attribute/id
    header += b'\x00\x00'
    with open(path, 'wb') as handle:
        handle.write(bytes(header))
        for record in records:
            handle.write(record)


# ------------------------------------------------------------------ DOCX

PNG_1PX = bytes.fromhex(
    '89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489'
    '0000000d4944415478da63f8cfc0f01f0005040201ff9c19b50000000049454e44ae426082')


def build_docx(path):
    document = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>第一章&amp;起程</w:t></w:r></w:p>
<w:p><w:r><w:t>风把窗帘吹成一面旗。</w:t></w:r><w:r><w:br/></w:r><w:r><w:t>第二行文字。</w:t></w:r></w:p>
<w:p><w:r><w:t>含图片：</w:t></w:r><w:r><w:drawing><wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:blip r:embed="rId7"/></a:graphic></wp:inline></w:drawing></w:r></w:p>
</w:body></w:document>'''
    rels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId7" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>
</Relationships>'''
    core = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:title>桌面夹具手册</dc:title><dc:creator>夹具编写组</dc:creator>
</cp:coreProperties>'''
    with zipfile.ZipFile(path, 'w') as zip:
        zip.writestr('word/document.xml', document)
        zip.writestr('word/_rels/document.xml.rels', rels)
        zip.writestr('docProps/core.xml', core)
        zip.writestr('word/media/image1.png', PNG_1PX)


# ------------------------------------------------------------------- PDF

def build_pdf(path):
    objects = {}
    objects[1] = b'<< /Type /Catalog /Pages 2 0 R >>'
    objects[2] = (b'<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>')
    objects[3] = (b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
                  b'/Contents 5 0 R /Resources << /Font << /F1 6 0 R >> >> >>')
    objects[4] = (b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
                  b'/Contents 9 0 R /Resources << /XObject << /Im0 8 0 R >> >> >>')
    content = (b'BT\n/F1 24 Tf\n72 700 Td\n'
               b'(Hello from the desktop fixture!) Tj\n'
               b'0 -28 Td\n(Second \\(escaped\\) line.) Tj\nET\n')
    objects[5] = (b'<< /Length ' + str(len(content)).encode() + b' >>\nstream\n' +
                  content + b'endstream')
    objects[6] = (b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
                  b'/Encoding /WinAnsiEncoding >>')
    # Page 2: no text at all, one JPEG page image (magic-prefixed fake JPEG).
    jpeg = (b'\xff\xd8\xff\xe0' + b'\x00' * 16 + b'\xff\xd9')
    objects[8] = (b'<< /Type /XObject /Subtype /Image /Width 32 /Height 32 '
                  b'/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode '
                  b'/Length ' + str(len(jpeg)).encode() + b' >>\nstream\n' + jpeg +
                  b'\nendstream')
    objects[9] = b'<< >>\nstream\nendstream'
    objects[7] = (b'<< /Title (\xfe\xff\x00H\x00i\x00 \x4f\x60\x59\x7d) '
                  b'/Author (Fixture Author) >>')

    out = bytearray(b'%PDF-1.4\n')
    offsets = {}
    for number in sorted(objects):
        offsets[number] = len(out)
        out += f'{number} 0 obj\n'.encode() + objects[number] + b'\nendobj\n'
    xref_at = len(out)
    count = max(objects) + 1
    out += f'xref\n0 {count}\n'.encode()
    out += b'0000000000 65535 f \n'
    for number in range(1, count):
        out += f'{offsets.get(number, 0):010d} 00000 n \n'.encode()
    out += (f'trailer\n<< /Size {count} /Root 1 0 R /Info 7 0 R >>\n'
            f'startxref\n{xref_at}\n%%EOF\n').encode()
    with open(path, 'wb') as handle:
        handle.write(bytes(out))


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else 'test/fixtures'
    os.makedirs(target, exist_ok=True)
    html = ('<html><head></head><body>'
            '<h1>第一章 启程</h1><p>风把窗帘吹成一面旗，走廊尽头亮着灯。</p>'
            '<mbp:pagebreak/>'
            '<h1>第二章 山道</h1><p>石阶湿滑，雾从林间漫上来。</p>'
            '<img recindex="00001">'
            '</body></html>').encode('utf-8')
    build_mobi(os.path.join(target, 'sample.mobi'), html,
               image=PNG_1PX)
    build_mobi(os.path.join(target, 'sample-trailing.mobi'), html,
               image=PNG_1PX, extra_flags=0x03)
    build_mobi(os.path.join(target, 'sample-drm.mobi'), html, encryption=1)
    build_mobi(os.path.join(target, 'sample-huff.mobi'), html, compression=17480)
    latin_html = '<html><body><h1>Chapter One</h1><p>Caf\xe9 na\xefve.</p></body></html>'.encode('cp1252')
    build_mobi(os.path.join(target, 'sample-cp1252.mobi'), latin_html,
               encoding=1252, title='Latin Fixture', author='Author Name')
    build_prc(os.path.join(target, 'sample.prc'),
              '纯文本文库记录，无压缩 PalmDOC。'.encode('utf-8'))
    build_docx(os.path.join(target, 'sample.docx'))
    build_pdf(os.path.join(target, 'sample.pdf'))
    print('fixtures written to', target)


if __name__ == '__main__':
    main()
