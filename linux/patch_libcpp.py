import struct, sys

src, dst = sys.argv[1], sys.argv[2]
data = bytearray(open(src, 'rb').read())

e_phoff = struct.unpack_from('<Q', data, 0x20)[0]
e_phentsize = struct.unpack_from('<H', data, 0x36)[0]
e_phnum = struct.unpack_from('<H', data, 0x38)[0]

loads, dyn_off, dyn_sz = [], None, None
for i in range(e_phnum):
    off = e_phoff + i * e_phentsize
    p_type = struct.unpack_from('<I', data, off)[0]
    p_offset = struct.unpack_from('<Q', data, off + 8)[0]
    p_vaddr = struct.unpack_from('<Q', data, off + 16)[0]
    p_filesz = struct.unpack_from('<Q', data, off + 32)[0]
    if p_type == 1: loads.append((p_vaddr, p_offset, p_filesz))
    if p_type == 2:
        dyn_off = p_offset
        dyn_sz = p_filesz
assert dyn_off is not None

def v2f(v):
    for va, fo, sz in loads:
        if va <= v < va + sz: return fo + (v - va)
    raise ValueError(f'vaddr {v:#x} not mapped')

def rd(off): return struct.unpack_from('<Q', data, off)[0]
def wr(off, val): struct.pack_into('<Q', data, off, val)

strtab = None
entries = []
i = 0
while i < dyn_sz:
    tag, val = rd(dyn_off + i), rd(dyn_off + i + 8)
    if tag == 0: break
    entries.append((dyn_off + i, tag, val))
    if tag == 5: strtab = val
    i += 16
assert strtab is not None
strtab_f = v2f(strtab)

needle = b'liblog.so\x00'
log_f = data.find(needle, strtab_f)
assert log_f > 0, 'liblog.so string not found in dynstr'
data[log_f:log_f + len(needle)] = b'libc.so.6\x00'

DT_DEBUG = 21
patched = {'needed': 0, 'ver': 0}
for off, tag, val in entries:
    if tag == 1:
        wr(off + 8, log_f - strtab_f)  # DT_NEEDED val = offset INTO dynstr
        patched['needed'] += 1
    elif tag in (0x6ffffffe, 0x6fffffff, 0x6ffffff0):
        wr(off, DT_DEBUG)
        patched['ver'] += 1

open(dst, 'wb').write(data)
print('patched:', patched)
