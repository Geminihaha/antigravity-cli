#!/usr/bin/env python3
"""
Generalized VA39 patch for the agy linux_arm64 binary.
Based on hjotha's analysis in:
https://github.com/google-antigravity/antigravity-cli/issues/64
This scans instruction patterns instead of using fixed offsets, so it can work
across builds where the relevant TCMalloc code moved.
"""
import hashlib
import shutil
import struct
import sys
from pathlib import Path

src = Path(sys.argv[1] if len(sys.argv) > 1 else str(Path.home() / ".local/bin/agy"))
dst = Path(str(src) + ".va39")

if not src.exists():
    raise SystemExit(f"Input binary does not exist: {src}")

print(f"Input binary : {src}")
print(f"SHA256 in    : {hashlib.sha256(src.read_bytes()).hexdigest()}")
print()

shutil.copyfile(src, dst)
data = bytearray(dst.read_bytes())

def get(off):
    return struct.unpack_from("<I", data, off)[0]

def put(off, word):
    struct.pack_into("<I", data, off, word)

# 1. Find google_malloc section via ELF header parsing.
lo, hi = 0, len(data)

def find_section(name_target):
    if data[:4] != b"\x7fELF":
        return None, None
    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize = struct.unpack_from("<H", data, 58)[0]
    e_shnum = struct.unpack_from("<H", data, 60)[0]
    e_shstrndx = struct.unpack_from("<H", data, 62)[0]
    shstr_base = e_shoff + e_shstrndx * e_shentsize
    shstr_off = struct.unpack_from("<Q", data, shstr_base + 24)[0]
    for i in range(e_shnum):
        base = e_shoff + i * e_shentsize
        sh_name = struct.unpack_from("<I", data, base)[0]
        sh_offset = struct.unpack_from("<Q", data, base + 24)[0]
        sh_size = struct.unpack_from("<Q", data, base + 32)[0]
        nend = data.index(b"\x00", shstr_off + sh_name)
        section = data[shstr_off + sh_name : nend].decode("utf-8", errors="replace")
        if section == name_target:
            return sh_offset, sh_offset + sh_size
    return None, None

sec_lo, sec_hi = find_section("google_malloc")
if sec_lo is not None:
    lo, hi = sec_lo, sec_hi
    print(f"Found google_malloc section: file 0x{lo:x} - 0x{hi:x} ({(hi - lo) // 1024} KB)")
else:
    print("google_malloc section not found - scanning entire binary.")
    print("This is slower but may still work.")
print()

# 2. ubfx #42,#3 -> #35,#3 and lsl #42 -> #35.
# These move TCMalloc's tag extraction/insertion from bit 42 to bit 35.
ubfx_count = 0
lsl_count = 0
for off in range(lo, hi, 4):
    w = get(off)
    if (w & 0x7F800000) == 0x53000000:  # bitfield-move family
        immr = (w >> 16) & 0x3F
        imms = (w >> 10) & 0x3F
        if immr == 42 and imms == 44:  # ubfx Xn, Xm, #42, #3
            put(off, (w & ~((0x3F << 16) | (0x3F << 10))) | (35 << 16) | (37 << 10))
            ubfx_count += 1
        elif immr == 22 and imms == 21:  # lsl Xn, Xm, #42 encoded as lsr
            put(off, (w & ~((0x3F << 16) | (0x3F << 10))) | (29 << 16) | (28 << 10))
            lsl_count += 1
print(f"[1] ubfx patches : {ubfx_count}  (expect ~15)")
print(f"    lsl  patches : {lsl_count}   (expect ~2)")

# 3. Random address mask pairs.
# mov x10, #-0x6c00000001; movk x10, #0, lsl #48
# -> mov x10, #-1; lsr x10, x10, #29
# Gives x10 = 0x7ffffffff, a 39-bit address mask.
mask_count = 0
for off in range(lo, hi - 4, 4):
    if get(off) == 0x92D3800A and get(off + 4) == 0xF2E0000A:
        put(off, 0x9280000A)
        put(off + 4, 0xD35DFD4A)
        mask_count += 1
print(f"[2] Random mask  : {mask_count}  (expect ~3)")

# 4. MmapAlignedLocked upper bound: 1 << 48 -> 1 << 39.
mmap_count = 0
for off in range(lo, hi, 4):
    if get(off) == 0xF2E00029:
        put(off, 0xD3596129)
        mmap_count += 1
print(f"[3] MmapAligned  : {mmap_count}  (expect ~1)")

# 5. Inlined tag constants and fast-path deallocation masks.
# Move tag placement from bit 42 to bit 35.
word_rewrites = {
    0xD2C20009: 0xD2C00409,  # normal P0 tag x9: 4 << 42 -> 4 << 35
    0xD2C2000A: 0xD2C0040A,  # normal P0 tag x10
    0xF2C20008: 0xF2DFF408,  # normal dealloc mask x8
    0xF2C20009: 0xF2DFF409,  # normal dealloc mask x9
    0xD2C10009: 0xD2C00209,  # cold tag x9: 2 << 42 -> 2 << 35
    0xD2C1000A: 0xD2C0020A,  # cold tag x10
    0xF2C38008: 0xF2DFF708,  # cold/tagged dealloc mask x8
    0xF2C38009: 0xF2DFF709,  # cold/tagged dealloc mask x9
    0x92560A6C: 0x925D0A6C,  # tag mask 0x1c0000000000 -> 0x3800000000 x12
    0x92560A6A: 0x925D0A6A,  # tag mask x10
    0xD2C3000D: 0xD2C0060D,  # normal P1 tag x13: 6 << 42 -> 6 << 35
    0xD2C3000C: 0xD2C0060C,  # normal P1 tag x12
    0xD2C08008: 0xD2C00108,  # kTagFree: 1 << 42 -> 1 << 35
}
counts = {old: 0 for old in word_rewrites}
for off in range(lo, hi, 4):
    w = get(off)
    if w in word_rewrites:
        put(off, word_rewrites[w])
        counts[w] += 1
print(f"[4] Tag constants: {sum(counts.values())} words rewritten")

# 6. Android/Termux syscall compatibility.
# Go's faccessat2 syscall can be killed by Android seccomp with SIGSYS. The
# old faccessat syscall is enough for os/exec.LookPath checks on Termux.
faccessat2_count = 0
for off in range(0, len(data) - 12, 4):
    if (
        get(off) == 0xAA1F03E5
        and get(off + 4) == 0xAA1F03E6
        and get(off + 8) == 0xD28036E0
        and (get(off + 12) & 0xFC000000) == 0x94000000
    ):
        put(off + 8, 0xD2800600)  # mov x0, #48; syscall.SYS_FACCESSAT
        faccessat2_count += 1
print(f"[5] faccessat2   : {faccessat2_count} syscall wrapper rewritten")

dst.write_bytes(data)
dst.chmod(0o755)
out_sha = hashlib.sha256(dst.read_bytes()).hexdigest()
print()
print(f"SHA256 out   : {out_sha}")
print(f"Output       : {dst}")
print()

total = ubfx_count + lsl_count + mask_count + mmap_count + sum(counts.values()) + faccessat2_count
if total == 0:
    print("WARNING: No patches applied - binary structure may have changed.")
    print("Do NOT use the output binary.")
elif ubfx_count == 0 or mask_count == 0:
    print("WARNING: Some expected patches were not found.")
    print("The patch may be incomplete - test carefully.")
else:
    print("Patch looks complete. Now test with:")
    print()
    print("  GLIBC=/data/data/com.termux/files/usr/glibc/lib")
    print("  $GLIBC/ld-linux-aarch64.so.1 --library-path $GLIBC \\")
    print(f"    {dst} --version")
