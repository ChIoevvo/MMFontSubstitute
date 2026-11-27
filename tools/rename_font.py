#!/usr/bin/env python3
"""把字体 name 表重写成可控的名字（iOS 上 fontWithName / family 匹配更可靠）。

用法: python3 tools/rename_font.py 输入.ttf 输出.ttf [--ps MMFontSub] [--family 名字]
重写后会重新计算每个表的 checksum 和 head.checkSumAdjustment，
并用 fontTools 之外的最小实现校验结构。
"""
import struct, sys, os

def u32(b, o): return struct.unpack_from(">I", b, o)[0]
def u16(b, o): return struct.unpack_from(">H", b, o)[0]

def parse(data):
    tag = data[:4]
    if tag not in (b"\x00\x01\x00\x00", b"OTTO", b"true"):
        raise SystemExit("不是 sfnt 字体: %r" % tag)
    num = u16(data, 4)
    tables = {}
    for i in range(num):
        off = 12 + i * 16
        t = data[off:off+4].decode("latin1")
        chk, o, l = struct.unpack_from(">III", data, off + 4)
        tables[t] = data[o:o+l]
    return tables

def build_name_table(ps, family, full=None, version="Version 1.0", unique=None):
    full = full or family
    unique = unique or (ps + ";1.0;2026")
    entries = [
        (1, family),      # family
        (2, "Regular"),   # subfamily
        (3, unique),      # unique id
        (4, full),        # full name
        (5, version),     # version
        (6, ps),          # postscript name
        (16, family),     # typographic family
        (17, "Regular"),  # typographic subfamily
    ]
    strings = b""
    records = b""
    for nid, s in entries:
        raw = s.encode("utf-16-be")
        records += struct.pack(">HHHHHH", 3, 1, 0x409, nid, len(raw), len(strings))
        strings += raw
    count = len(entries)
    hdr = struct.pack(">HHH", 0, count, 6 + 12 * count)
    return hdr + records + strings

def checksum(b):
    if len(b) % 4:
        b = b + b"\0" * (4 - len(b) % 4)
    s = 0
    for i in range(0, len(b), 4):
        s = (s + struct.unpack_from(">I", b, i)[0]) & 0xFFFFFFFF
    return s

def build(tables):
    tables = dict(tables)
    # head 的 checkSumAdjustment 先清零
    head = bytearray(tables["head"])
    struct.pack_into(">I", head, 8, 0)
    tables["head"] = bytes(head)

    tags = sorted(tables.keys(), key=lambda x: x.encode("latin1"))
    num = len(tags)
    # searchRange / entrySelector / rangeShift
    es = 0
    while (1 << (es + 1)) <= num:
        es += 1
    sr = (1 << es) * 16
    rs = num * 16 - sr

    offset = 12 + num * 16
    records = b""
    body = b""
    for t in tags:
        data = tables[t]
        records += struct.pack(">4sIII", t.encode("latin1"), checksum(data), offset, len(data))
        body += data
        pad = (-len(data)) % 4
        body += b"\0" * pad
        offset += len(data) + pad

    out = bytearray(struct.pack(">IHHHH", 0x00010000, num, sr, es, rs) + records + body)
    # head.checkSumAdjustment
    head_off = None
    for i in range(num):
        o = 12 + i * 16
        if out[o:o+4] == b"head":
            head_off = u32(out, o + 8)
            break
    total = checksum(bytes(out))
    adj = (0xB1B0AFBA - total) & 0xFFFFFFFF
    struct.pack_into(">I", out, head_off + 8, adj)
    # head 表记录里的 checksum 需要用 adjustment=0 的值重算，前面已按 0 计算，保持不动
    return bytes(out)

def read_names(data):
    tables = parse(data)
    n = tables["name"]
    count = u16(n, 2)
    so = u16(n, 4)
    res = {}
    for i in range(count):
        pid, eid, lid, nid, ln, off = struct.unpack_from(">HHHHHH", n, 6 + i * 12)
        s = n[so + off: so + off + ln]
        try:
            txt = s.decode("utf-16-be") if pid == 3 else s.decode("latin1")
        except Exception:
            txt = repr(s)
        if nid not in res:
            res[nid] = txt
    return res

def main():
    src, dst = sys.argv[1], sys.argv[2]
    ps = "MMFontSub"
    family = "渡-果の棉花宝宝加粗改の"
    args = sys.argv[3:]
    for i, a in enumerate(args):
        if a == "--ps": ps = args[i+1]
        if a == "--family": family = args[i+1]
    data = open(src, "rb").read()
    tables = parse(data)
    tables["name"] = build_name_table(ps, family)
    out = build(tables)
    open(dst, "wb").write(out)
    print("写入 %s  %d bytes" % (dst, len(out)))
    print("name 表:", read_names(out))

if __name__ == "__main__":
    main()
