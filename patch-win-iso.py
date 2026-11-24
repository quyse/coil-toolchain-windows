import os
import struct
import subprocess
import sys

ISO, OUT = sys.argv[1], sys.argv[2]
BS = 2048


def pread(f, offset, size):
    f.seek(offset)
    data = f.read(size)
    assert len(data) == size, f"Short read at {offset}"
    return data


def read_lba(f, lba):
    return pread(f, lba * BS, BS)


def decode_dstring(raw):
    if not raw:
        return ""
    if raw[0] == 8:
        return raw[1:].decode("latin-1")
    if raw[0] == 16:
        return raw[1:].decode("utf-16-be")
    raise ValueError(f"Unsupported UDF CS0 compression ID: {raw[0]}")


def parse_fe_extents(fe, part_start):
    tag_id = struct.unpack_from("<H", fe, 0)[0]
    flags = struct.unpack_from("<H", fe, 34)[0]
    info_len = struct.unpack_from("<Q", fe, 56)[0]
    if tag_id == 261:  # File Entry (UDF 1.02)
        l_ea, l_ad = struct.unpack_from("<II", fe, 168)
        ad_off = 176 + l_ea
    elif tag_id == 266:  # Extended File Entry (UDF 2.00+)
        l_ea, l_ad = struct.unpack_from("<II", fe, 208)
        ad_off = 216 + l_ea
    else:
        raise ValueError(f"Unexpected UDF File Entry tag: {tag_id}")

    ad_type = flags & 7
    ad_bytes = fe[ad_off : ad_off + l_ad]
    if ad_type == 3:
        return info_len, None, ad_bytes

    step = 8 if ad_type == 0 else 16 if ad_type == 1 else None
    if step is None:
        raise ValueError(f"Unsupported UDF AD type: {ad_type}")

    extents = []
    for i in range(0, len(ad_bytes), step):
        raw_len, loc = struct.unpack_from("<II", ad_bytes, i)
        ext_len = raw_len & 0x3FFFFFFF
        if ext_len:
            extents.append((part_start + loc, ext_len))
    return info_len, extents, None


def read_fe_data(f, fe, part_start):
    info_len, extents, inline = parse_fe_extents(fe, part_start)
    if inline is not None:
        return inline[:info_len]
    buf = bytearray()
    for lba, ext_len in extents:
        buf.extend(pread(f, lba * BS, ext_len))
    return bytes(buf[:info_len])


def find_udf_file(f, parts):
    avdp = read_lba(f, 256)
    assert struct.unpack_from("<H", avdp, 0)[0] == 2, "Missing UDF AVDP at LBA 256"
    mvds_len, mvds_loc = struct.unpack_from("<II", avdp, 16)

    part_start = fsd_block = None
    for i in range(mvds_len // BS):
        sec = read_lba(f, mvds_loc + i)
        tag = struct.unpack_from("<H", sec, 0)[0]
        if tag == 5:
            part_start = struct.unpack_from("<I", sec, 188)[0]
        elif tag == 6:
            fsd_block = struct.unpack_from("<I", sec, 252)[0]
        elif tag == 8:
            break
    assert part_start is not None and fsd_block is not None, "Incomplete UDF MVDS"

    fsd = read_lba(f, part_start + fsd_block)
    assert struct.unpack_from("<H", fsd, 0)[0] == 256, "Missing UDF File Set Descriptor"
    cur_block = struct.unpack_from("<I", fsd, 404)[0]

    for name in parts:
        fe = read_lba(f, part_start + cur_block)
        dir_data = read_fe_data(f, fe, part_start)
        pos = 0
        next_block = None
        while pos < len(dir_data):
            assert struct.unpack_from("<H", dir_data, pos)[0] == 257, "Expected UDF FID"
            chars, l_fi = struct.unpack_from("<BB", dir_data, pos + 18)
            icb_block = struct.unpack_from("<I", dir_data, pos + 24)[0]
            l_iu = struct.unpack_from("<H", dir_data, pos + 36)[0]
            ident = dir_data[pos + 38 + l_iu : pos + 38 + l_iu + l_fi]
            pos += ((38 + l_iu + l_fi + 3) // 4) * 4
            if (chars & 0x0C) == 0 and decode_dstring(ident).lower() == name.lower():
                next_block = icb_block
                break
        if next_block is None:
            raise FileNotFoundError(f"UDF path component not found: {name}")
        cur_block = next_block

    fe = read_lba(f, part_start + cur_block)
    info_len, extents, inline = parse_fe_extents(fe, part_start)
    assert inline is None and len(extents) == 1, f"Expected contiguous file, got {extents}"
    return extents[0][0], info_len


def find_el_torito_efi_entry_offset(f):
    brvd = read_lba(f, 17)
    assert brvd[0:7] == b"\x00CD001\x01" and brvd[7:30] == b"EL TORITO SPECIFICATION"
    cat_lba = struct.unpack_from("<I", brvd, 71)[0]
    cat = read_lba(f, cat_lba)
    assert cat[0] == 0x01 and cat[30:32] == b"\x55\xAA", "Invalid El Torito Validation Entry"

    if cat[1] == 0xEF:  # UEFI-only ISO
        return cat_lba * BS + 32

    off = 64
    while off + 64 <= BS:
        hdr = cat[off]
        if hdr not in (0x90, 0x91):
            break
        platform = cat[off + 1]
        count = struct.unpack_from("<H", cat, off + 2)[0]
        if platform == 0xEF and count >= 1:
            assert cat[off + 32] == 0x88 and cat[off + 33] == 0x00, "Unexpected EFI entry flags"
            return cat_lba * BS + off + 32
        off += 32
        for _ in range(count):
            off += 32
            while off < BS and cat[off] == 0x44:
                off += 32
        if hdr == 0x91:
            break
    raise RuntimeError("No UEFI (0xEF) section found in El Torito Boot Catalog")


with open(ISO, "rb") as f:
    noprompt_lba, noprompt_size = find_udf_file(
        f, ["efi", "microsoft", "boot", "efisys_noprompt.bin"]
    )
    entry_off = find_el_torito_efi_entry_offset(f)

sec_count = (noprompt_size + 511) // 512
assert sec_count <= 0xFFFF, f"Boot image too large for 16-bit sector count: {noprompt_size}"

subprocess.run(
    ["qemu-img", "create", "-f", "qcow2", "-b", os.path.abspath(ISO), "-F", "raw", OUT],
    check=True,
)

patch = struct.pack("<HI", sec_count, noprompt_lba)
cmds = []
for i, byte in enumerate(patch):
    cmds += ["-c", f"write -P 0x{byte:02x} {entry_off + 6 + i} 1"]
subprocess.run(["qemu-io", *cmds, OUT], check=True)

print(
    f"Patched El Torito EFI entry at 0x{entry_off:x} -> "
    f"LBA {noprompt_lba} ({sec_count} x 512B sectors, {noprompt_size} bytes)"
)
