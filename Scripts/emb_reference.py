"""Reference reader for Wilcom .EMB files: the Python mirror of StitchKit's CFBReader/EMBReader.

    python3 Scripts/emb_reference.py dump file.EMB

prints the same canonical text as `stitchdump emb file.EMB`, so the two can be diffed over any
corpus (the Swift side on a Mac, this side anywhere). `Scripts/test_emb_reference.py` checks
this reader against an independent one.

Written to the same structure as the Swift code on purpose: a hand-rolled CFB walk, no olefile.
It reads only the directory, the design-info stream and the two preview streams. It never reads
the `DesignDocument` stream (which is encrypted) and has no code that could.
"""
import hashlib
import struct
import sys
import zlib

SIGNATURE = bytes([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
MAX_REGULAR = 0xFFFFFFFA
NO_STREAM = 0xFFFFFFFF
DDD = "\x05WilcomDesignInformationDDD"
UNITS_PER_MM = 180.0
SEQ_RECORD = 796


class CFBError(Exception):
    pass


def u16(b, o):
    if o < 0 or o + 2 > len(b):
        raise CFBError("read past end")
    return b[o] | b[o + 1] << 8


def u32(b, o):
    if o < 0 or o + 4 > len(b):
        raise CFBError("read past end")
    return struct.unpack_from("<I", b, o)[0]


class CFBFile:
    def __init__(self, data):
        b = bytes(data)
        if len(b) < 512 or b[:8] != SIGNATURE:
            raise CFBError("not a compound file")
        self.b = b
        major = u16(b, 0x1A)
        if major not in (3, 4) or u16(b, 0x1C) != 0xFFFE:
            raise CFBError("unsupported")
        shift, mini_shift = u16(b, 0x1E), u16(b, 0x20)
        if shift not in (9, 12) or (major == 3) != (shift == 9) or mini_shift != 6:
            raise CFBError("bad sector size")
        self.ss = 1 << shift
        self.mss = 1 << mini_shift
        fat_count = u32(b, 0x2C)
        first_dir = u32(b, 0x30)
        self.cutoff = u32(b, 0x38)
        first_minifat, minifat_count = u32(b, 0x3C), u32(b, 0x40)
        difat, difat_count = u32(b, 0x44), u32(b, 0x48)
        limit = len(b) // self.ss + 1
        if max(fat_count, minifat_count, difat_count) > limit:
            raise CFBError("sector counts")

        fat_sectors = [s for s in (u32(b, 0x4C + 4 * i) for i in range(109)) if s < MAX_REGULAR]
        seen = 0
        while difat < MAX_REGULAR and seen < difat_count:
            base = self._off(difat)
            fat_sectors += [s for s in (u32(b, base + 4 * i) for i in range(self.ss // 4 - 1)) if s < MAX_REGULAR]
            difat = u32(b, base + self.ss - 4)
            seen += 1
        self.fat = []
        for s in fat_sectors:
            base = self._off(s)
            self.fat += [u32(b, base + 4 * i) for i in range(self.ss // 4)]

        d = self._chain(first_dir)
        if len(d) < 128:
            raise CFBError("empty directory")
        raws = []
        for i in range(len(d) // 128):
            o = i * 128
            nbytes = min(u16(d, o + 64), 64)
            units = max(0, nbytes // 2 - 1)
            name = d[o:o + 2 * units].decode("utf-16-le", "replace")
            size = u32(d, o + 120) | ((u32(d, o + 124) << 32) if major == 4 else 0)
            raws.append(dict(name=name, type=d[o + 66], left=u32(d, o + 68), right=u32(d, o + 72),
                             child=u32(d, o + 76), start=u32(d, o + 116), size=size))
        if raws[0]["type"] != 5:
            raise CFBError("no root")

        self.streams = {}
        visited = set()

        # Same explicit-stack walk as the Swift reader (same visiting order, first path wins).
        pending = [(raws[0]["child"], "")]
        while pending:
            i, prefix = pending.pop()
            if i == NO_STREAM or i >= len(raws) or i in visited:
                continue
            visited.add(i)
            r = raws[i]
            pending.append((r["right"], prefix))
            pending.append((r["left"], prefix))
            path = r["name"] if not prefix else prefix + "/" + r["name"]
            if r["type"] == 2:
                self.streams.setdefault(path, (r["start"], r["size"]))
            elif r["type"] == 1:
                pending.append((r["child"], path))

        self.minifat, self.mini = [], b""
        if minifat_count > 0 and first_minifat < MAX_REGULAR:
            table = self._chain(first_minifat)
            self.minifat = [u32(table, 4 * i) for i in range(len(table) // 4)]
            container = self._chain(raws[0]["start"])
            self.mini = container[:raws[0]["size"]]

    def _off(self, sector):
        o = (sector + 1) * self.ss
        if o + self.ss > len(self.b):
            raise CFBError("sector outside file")
        return o

    def _chain(self, start, limit=None):
        out, s, hops = bytearray(), start, 0
        while s < MAX_REGULAR:
            hops += 1
            if hops > len(self.fat) + 1 or s >= len(self.fat):
                raise CFBError("chain")
            o = self._off(s)
            out += self.b[o:o + self.ss]
            if limit is not None and len(out) >= limit:
                break
            s = self.fat[s]
        return bytes(out)

    def stream(self, name):
        if name not in self.streams:
            raise CFBError("stream not found: " + name)
        start, size = self.streams[name]
        if size > 256 << 20:
            raise CFBError("stream size")
        if size == 0:
            return b""
        if size < self.cutoff:
            out, s, hops = bytearray(), start, 0
            while s < MAX_REGULAR and len(out) < size:
                hops += 1
                if hops > len(self.minifat) + 1 or s >= len(self.minifat):
                    raise CFBError("mini chain")
                o = s * self.mss
                if o + self.mss > len(self.mini):
                    raise CFBError("mini range")
                out += self.mini[o:o + self.mss]
                s = self.minifat[s]
            if len(out) < size:
                raise CFBError("short mini stream")
            return bytes(out[:size])
        out = self._chain(start, limit=size)
        if len(out) < size:
            raise CFBError("short stream")
        return out[:size]


def cstr(b):
    return b.split(b"\0")[0].decode("cp1252")


def property_set(d):
    """{lowercased name: value}, plus {'#<id>': value} for fields the name dictionary lacks."""
    section = u32(d, 44)
    count = u32(d, section + 4)
    offsets = {u32(d, section + 8 + 8 * i): u32(d, section + 12 + 8 * i) for i in range(count)}
    names = {}
    if 0 in offsets:
        q = section + offsets[0] + 4
        for _ in range(u32(d, section + offsets[0])):
            pid, ln = u32(d, q), u32(d, q + 4)
            q += 8
            names[pid] = cstr(d[q:q + ln]).lower()
            q += ln
    out = {}
    for pid, po in offsets.items():
        if pid in (0, 1):
            continue
        a = section + po
        t = u32(d, a)
        if t == 0x03:
            v = struct.unpack_from("<i", d, a + 4)[0]
        elif t == 0x02:
            v = struct.unpack_from("<h", d, a + 4)[0]
        elif t == 0x05:
            v = struct.unpack_from("<d", d, a + 4)[0]
        elif t in (0x1E, 0x41):
            ln = u32(d, a + 4)
            raw = bytes(d[a + 8:a + 8 + ln])
            v = raw if t == 0x41 else cstr(raw)
        else:
            continue
        out[names.get(pid, "#%d" % pid)] = v
        out["#%d" % pid] = v
    return out


def preview(cfb, name):
    raw = cfb.stream(name)
    n = u32(raw, 0)
    z = zlib.decompress(raw[4:])
    if n != len(z):
        raise CFBError("preview length")
    return z


def read_file(path):
    with open(path, "rb") as f:
        return f.read()


def parse(path):
    cfb = CFBFile(read_file(path))
    props = property_set(cfb.stream(DDD))

    def num(name, pid):
        v = props.get(name, props.get("#%d" % pid))
        return v if isinstance(v, (int, float)) else None

    def txt(name, pid):
        v = props.get(name, props.get("#%d" % pid))
        return v if isinstance(v, str) and v else None

    threads = []
    seq = props.get("sequence list", props.get("#18"))
    if isinstance(seq, bytes):
        for i in range(len(seq) // SEQ_RECORD):
            r = i * SEQ_RECORD
            stop, slot, code = struct.unpack_from("<III", seq, r)
            ref = struct.unpack_from("<I", seq, r + 792)[0]
            threads.append(dict(stop=stop, slot=slot, code=code, name=cstr(seq[r + 20:r + 276]),
                                chart=cstr(seq[r + 276:r + 532]),
                                hex="#%02x%02x%02x" % (ref & 255, (ref >> 8) & 255, (ref >> 16) & 255)))
    previews = {}
    for key, stream in (("bmp", "DESIGN_ICON"), ("jpeg", "TRUEVIEW_ICON")):
        try:
            previews[key] = preview(cfb, stream)
        except Exception:
            previews[key] = None
    return props, num, txt, threads, previews


def dump(path):
    props, num, txt, threads, previews = parse(path)

    def i(name, pid):
        v = num(name, pid)
        return int(round(v)) if v is not None else 0

    def mm(name, pid):
        v = num(name, pid)
        return "%.1f" % (v / UNITS_PER_MM) if v is not None else "-"

    def sha(b):
        return "-" if b is None else "%d %s" % (len(b), hashlib.sha256(b).hexdigest())

    lines = [
        "stitches %d" % i("number of stitches", 6),
        "trims %d" % i("number of trims", 5),
        "colors %d" % i("number of colours", 3),
        "stops %d" % i("number of stops", 4),
        "colorchanges %d" % i("number of colour changes", 27),
        "objects %d" % i("number of objects", 7),
        "width_mm %.3f" % ((num("design width", 17) or 0) / UNITS_PER_MM),
        "height_mm %.3f" % ((num("design height", 16) or 0) / UNITS_PER_MM),
        "thread_mm " + mm("thread length", 8),
        "bobbin_mm " + mm("bobbin length", 9),
        "machine " + (txt("embroidery machine name", 19) or "-"),
        "source " + (txt("source", 43) or "-"),
        "colorway " + (txt("colorway", 33) or "-"),
        "bmp " + sha(previews["bmp"]),
        "jpeg " + sha(previews["jpeg"]),
    ]
    for t in threads:
        lines.append("thread %d %d %d %s %s|%s" % (t["stop"], t["slot"], t["code"], t["hex"], t["name"], t["chart"]))
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "dump":
        sys.stdout.write(dump(sys.argv[2]))
    else:
        print(__doc__)
