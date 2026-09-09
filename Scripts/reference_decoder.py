"""The validated Python reference decoder for Tajima DST.

The Swift parser is diffed against this over the fixture corpus; that comparison is the
parser's acceptance test. Keep the two in lockstep.
"""


def decode(path):
    d = open(path, "rb").read()
    body = d[512:]
    x = y = 0
    out = []
    for i in range(0, len(body) - 2, 3):
        b0, b1, b2 = body[i], body[i + 1], body[i + 2]
        if b2 == 0xF3:
            break
        dx = dy = 0
        if b0 & 0x01: dx += 1
        if b0 & 0x02: dx -= 1
        if b0 & 0x04: dx += 9
        if b0 & 0x08: dx -= 9
        if b0 & 0x80: dy += 1
        if b0 & 0x40: dy -= 1
        if b0 & 0x20: dy += 9
        if b0 & 0x10: dy -= 9
        if b1 & 0x01: dx += 3
        if b1 & 0x02: dx -= 3
        if b1 & 0x04: dx += 27
        if b1 & 0x08: dx -= 27
        if b1 & 0x80: dy += 3
        if b1 & 0x40: dy -= 3
        if b1 & 0x20: dy += 27
        if b1 & 0x10: dy -= 27
        if b2 & 0x04: dx += 81
        if b2 & 0x08: dx -= 81
        if b2 & 0x20: dy += 81
        if b2 & 0x10: dy -= 81
        x += dx
        y -= dy                       # the Y trap: subtract, do not add
        out.append((x, y, b2 & 0xC3))
    return out


def canonical(records):
    """The exact string both implementations hash, so equality is byte-for-byte."""
    return "".join(f"{x},{y},{c}\n" for x, y, c in records)
