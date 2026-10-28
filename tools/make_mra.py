#!/usr/bin/env python3
"""Writes the core's .mra files (one per MAME set) from the ROM_START tables (tools/silvmil_rom.py), the image layout
(tools/silvmil_image.py) and the DSW definitions of the driver's INPUT_PORTS (MAME's silvmil.cpp: tools/paths.py MAME_SRC), and checks each one: the image
tools/mra_build.py assembles from the .mra and the merged romset must be byte-identical to silvmil_image.py's.

    make_mra.py [outdir]          default mra/
"""
import hashlib
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import silvmil_rom
import silvmil_image as IMG

GAMES = {
    # set: (title, year, manufacturer, INPUT_PORTS name, parent or None, file name, folder under the MRA root, rotation)
    'silvmil':   ('Silver Millennium', 1995, 'Para', 'silvmil', None, 'Silver Millennium', '', 'vertical (ccw)'),
    'puzzlove':  ('PuzzLove', 1994, 'Para', 'puzzlove', None, 'PuzzLove', '', 'horizontal'),
    'puzzlovek': ('PuzzLove (Korea)', 1994, 'Para', 'puzzlovek', 'puzzlove', 'PuzzLove (Korea)', '_alternatives/_PuzzLove', 'horizontal'),
}

# What the buttons do (button 1, button 2[, button 3]): pressing each in MAME 0.289 (tools/probe.py, docs/status.md).  MAME's INPUT_PORTS
# give both games a third button; neither reacts to it (held for two seconds in play, tapped at the player select): it is left out.
#   silvmil    A fires one shot per press (no auto-fire); B: a bomb, a burst of flame around the ship for over a second
#   puzzlove   A: the player jumps along the path (and picks up what is there); B: one of the stock items (the dots at the left)
#              for ten more seconds on the timer (a "TIME" sign over the player, 027 -> 037)
BUTTONS = {
    'silvmil':   ['Shot', 'Bomb'],
    'puzzlove':  ['Jump', 'Extra Time'],
    'puzzlovek': ['Jump', 'Extra Time'],
}


def crc_of(setname, fname):
    import zlib
    z = silvmil_rom.open_zip(silvmil_rom.SETS[setname][0])
    return '%08x' % (zlib.crc32(silvmil_rom.get_file(z, setname, fname)) & 0xffffffff)


# ---- the parts of one region: [(region offset, region length, kind, pieces)]
#   kind 'i': interleaved 16-bit, pieces = {lane: (file, file offset)} (lane 0 = even region byte), region length = 2 x file bytes
#   kind 'n': plain, pieces = (file, file offset)
def region_parts(entries):
    groups = {}
    plain = []
    for e in entries:
        fname, mode, offset, n = e[:4]
        conts = e[4] if len(e) > 4 else []
        for k, o in enumerate([offset] + conts):
            if mode == 'n':
                plain.append((o, n, 'n', (fname, k * n)))
            else:
                groups.setdefault((o & ~1, n), {})[o & 1] = (fname, k * n)
    out = [(s, 2 * n, 'i', lanes) for (s, n), lanes in groups.items()] + plain
    for s, ln, kind, p in out:
        if kind == 'i':
            assert set(p) == {0, 1}, (s, p)
    return sorted(out)


def split(part, at):
    """Splits a region part at region offset `at` (inside it) into two."""
    s, ln, kind, p = part
    d = at - s
    if kind == 'i':
        a = (s, d, 'i', {lane: (f, o) for lane, (f, o) in p.items()})
        b = (at, ln - d, 'i', {lane: (f, o + d // 2) for lane, (f, o) in p.items()})
    else:
        f, o = p
        a = (s, d, 'n', (f, o))
        b = (at, ln - d, 'n', (f, o + d))
    return a, b


def emit(setname, part, swap_lanes, comment=None):
    s, ln, kind, p = part
    lines = []
    if comment:
        lines.append('        <!-- %s -->' % comment)
    if kind == 'n':
        f, o = p
        lines.append('        <part name="%s" crc="%s" offset="0x%x" length="0x%x"/>' % (f, crc_of(setname, f), o, ln))
    else:
        lines.append('        <interleave output="16">')
        for lane in (0, 1):
            f, o = p[lane]
            first = (lane == 1) if swap_lanes else (lane == 0)      # this file supplies the first byte of each image word
            lines.append('            <part name="%s" crc="%s" offset="0x%x" length="0x%x" map="%s"/>' % (
                f, crc_of(setname, f), o, ln // 2, '01' if first else '10'))
        lines.append('        </interleave>')
    return lines


def rom_lines(setname):
    zname, regions = silvmil_rom.SETS[setname]
    reg = {r: (size, entries) for r, size, entries in regions}
    items = []                     # (image offset, length, [xml lines])

    def place(region, base, half_split, swap, label):
        size, entries = reg[region]
        parts = region_parts(entries)
        if half_split:
            h = size // 2
            out = []
            for pt in parts:
                if pt[0] < h < pt[0] + pt[1]:
                    out += list(split(pt, h))
                else:
                    out.append(pt)
            parts = out
        first = True
        for pt in parts:
            s, ln = pt[0], pt[1]
            if half_split:
                img_off = base + (s if s < size // 2 else IMG.HALF[base] + s - size // 2)
            else:
                img_off = base + s
            items.append((img_off, ln, emit(setname, pt, swap, label if first else None)))
            first = False

    place('maincpu', IMG.O_MAIN, False, True, 'maincpu: the 68000 program, each word low byte first')
    place('tiles', IMG.O_TILE, True, False, 'tiles: first half at 0x100000, second half at 0x300000')
    place('sprites', IMG.O_SPR, True, False, 'sprites: first half at 0x500000, second half at 0x600000')
    place('oki', IMG.O_OKI, False, False, 'oki: the M6295 samples')
    # audiocpu: the first 64 KB only
    size, entries = reg['audiocpu']
    items.append((IMG.O_Z80, 0x10000, emit(setname, (0, 0x10000, 'n', (entries[0][0], 0)), False, 'audiocpu: the Z80 program (64 KB)')))
    cfg = IMG.build(setname)[IMG.O_CFG:IMG.O_CFG + 8]
    items.append((IMG.O_CFG, 8, ['        <!-- configuration: PuzzLove sprite format, 32768 tiles, sound clocks, vertical, button 3 -->',
                                 '        <part>%s</part>' % ' '.join('%02X' % b for b in cfg)]))
    items.sort()
    lines, pos = [], 0
    for off, ln, xml in items:
        if off > pos:
            gap = off - pos
            # zeros in runs of 64 bytes (MiSTer's loader handles a literal part once per repeat: 3 MB of single bytes are 3 million calls)
            if gap % 64 == 0:
                lines.append('        <part repeat="0x%x">%s</part>' % (gap // 64, ' '.join(['00'] * 64)))
            else:
                lines.append('        <part repeat="0x%x">00</part>' % gap)
        assert off >= pos, (setname, hex(off), hex(pos))
        lines += xml
        pos = off + ln
    assert pos == IMG.IMG_SIZE, hex(pos)
    return lines


# ---- DIP switches from the driver's INPUT_PORTS
def def_str(s):
    s = s.strip()
    m = re.match(r'DEF_STR\s*\(\s*(\w+)\s*\)', s)
    if m:
        v = m.group(1)
        if re.match(r'^\d+C_\d+C$', v):
            return v.replace('_', '/')
        return v.replace('_', ' ')
    m = re.match(r'"(.*)"$', s)
    return m.group(1) if m else s


def dsw_dips(ports_name):
    src = open(paths.MAME_SRC, encoding='utf-8').read()
    blk = re.search(r'INPUT_PORTS_START\(\s*%s\s*\)(.*?)INPUT_PORTS_END' % ports_name, src, re.S).group(1)
    inc = re.search(r'PORT_INCLUDE\(\s*(\w+)\s*\)', blk)
    if inc and 'PORT_MODIFY("DSW")' in blk:
        # the included ports, then the modified switches in place of the ones they overlap
        dips = dsw_dips(inc.group(1))
        for d in parse_dips(blk[blk.index('PORT_MODIFY("DSW")'):]):
            dips = [x for x in dips if not (x[0] & d[0])] + [d]
        return sorted(dips, key=lambda x: x[0] & -x[0])
    return parse_dips(blk[blk.index('PORT_START("DSW")'):])


def parse_dips(dsw):
    dips = []                     # [mask, default, name, {value: label}]
    for line in dsw.splitlines():
        line = re.sub(r'/\*.*?\*/', '', line.split('//')[0]).strip()       # the driver's comments: // and /* */
        m = re.match(r'PORT_DIPNAME\(\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(.*?)\s*\)\s*(PORT_DIPLOCATION.*)?$', line)
        if m:
            dips.append([int(m.group(1), 16), int(m.group(2), 16), def_str(m.group(3)), {}])
            continue
        m = re.match(r'PORT_DIPSETTING\(\s*(0x[0-9a-fA-F]+)\s*,\s*(.*?)\s*\)$', line)
        if m:
            dips[-1][3][int(m.group(1), 16)] = def_str(m.group(2))
            continue
        m = re.match(r'PORT_(DIPUNUSED|DIPUNKNOWN)_DIPLOC\(\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*"(.*?)"\s*\)', line)
        if m:
            mask, dflt = int(m.group(2), 16), int(m.group(3), 16)
            dips.append([mask, dflt, '%s (%s)' % ('Unused' if m.group(1) == 'DIPUNUSED' else 'Unknown', m.group(4)), {mask: 'Off', 0: 'On'}])
            continue
        m = re.match(r'PORT_SERVICE_DIPLOC\(\s*(0x[0-9a-fA-F]+)\s*,\s*IP_ACTIVE_LOW\s*,\s*"(.*?)"\s*\)', line)
        if m:
            mask = int(m.group(1), 16)
            dips.append([mask, mask, 'Service Mode', {mask: 'Off', 0: 'On'}])
            continue
    return dips


def dip_bits(bits):
    """A <dip>'s bits: one bit, or the range "first,last" (MiSTer's form; not a list of every bit)."""
    assert bits == list(range(bits[0], bits[-1] + 1)), bits  # a field is contiguous bits
    return str(bits[0]) if len(bits) == 1 else '%d,%d' % (bits[0], bits[-1])


def switches_lines(ports_name):
    dips = dsw_dips(ports_name)
    default = 0xFFFF
    lines = []
    for mask, dflt, name, settings in dips:
        bits = [b for b in range(16) if mask >> b & 1]
        default = (default & ~mask) | dflt
        ids = []
        for v in range(1 << len(bits)):
            val = sum(((v >> i) & 1) << b for i, b in enumerate(bits))
            ids.append(settings.get(val, 'Unknown (%d)' % v).replace(',', ' '))
        lines.append('        <dip bits="%s" name="%s" ids="%s"/>' % (dip_bits(bits), name.replace('"', ''), ','.join(ids)))
    head = '    <switches default="%02X,%02X" base="16">' % (default & 0xFF, default >> 8)
    return [head] + lines + ['    </switches>'], default


def mra_text(setname):
    title, year, maker, ports, parent, fname, folder, rotation = GAMES[setname]
    zname = silvmil_rom.SETS[setname][0]
    zipattr = '%s.zip|%s.zip' % (setname, parent) if parent else '%s.zip' % setname
    sw, default = switches_lines(ports)
    md5 = 'None'                          # main() replaces it with the md5 MiSTer computes (mra_build.mister_md5)
    out = ['<misterromdescription>',
           '    <rotation>%s</rotation>' % rotation,
           '    <name>%s</name>' % title,
           '    <setname>%s</setname>' % setname]
    if parent:
        out.append('    <parent>%s</parent>' % parent)
    out += ['    <mameversion>0289</mameversion>',
            '    <year>%d</year>' % year,
            '    <manufacturer>%s</manufacturer>' % maker,
            '    <players>2</players>',
            '    <joystick>8</joystick>',                 # silvmil.cpp has no PORT_4WAY
            '    <rbf>silvmil</rbf>',
            '    <platform>Para</platform>',
            '',
            '    <!--',
            '      Image for the Silvmil core (rtl/sm_mem.sv, tools/silvmil_image.py):',
            '',
            '        0x000000  68000 program (1 MB, each word low byte first)',
            '        0x100000  tile ROM: first half at 0x100000, second half at 0x300000',
            '        0x500000  sprite ROM: first half at 0x500000, second half at 0x600000',
            '        0x700000  OKI M6295 samples (256 KB)',
            '        0x740000  Z80 program (64 KB)',
            '        0x750000  configuration (8 bytes)',
            '',
            '      Made by tools/make_mra.py from MAME 0.289 (src/mame/f32/silvmil.cpp); expects the MAME 0.289 merged romset or',
            '      the split sets: parts are found by name and CRC.',
            '',
            '      DIP switches (ioctl index 254): byte 0 is SW1 (bits 7:0 of MAME\'s DSW port), byte 1 is SW2 (bits 15:8); a 1 is "off".',
            '      MAME\'s default is %04X.' % default,
            '    -->']
    out += sw
    # address=: fast load -- a recent Main_MiSTer copies the assembled image into the DDR3 at that byte address and sends an empty
    # download instead of the bytes (rtl/sm_fastload.sv reads it back); an older one ignores the attribute
    out += ['', '    <rom index="0" zip="%s" md5="%s" address="0x32000000">' % (zipattr, md5)]
    out += rom_lines(setname)
    # the core's joystick bits 4..8 (Silvmil.sv): button 1, button 2, button 3, start, coin. A set without button 3 names it "-":
    # MiSTer skips it when mapping, and its default list (pad buttons A, B, X, Start, Select) leaves it out (Main_MiSTer
    # joymapping.cpp: map_joystick() skips "-" and takes the next default name for the next button)
    names = BUTTONS[setname]
    assert (len(names) == 3) == bool(IMG.CFG[setname][3]), setname
    three = len(names) == 3
    buttons = '    <buttons names="%s" default="%s"/>' % (','.join(names[:2] + [names[2] if three else '-', 'Start', 'Coin']),
                                                       'A,B,X,Start,Select' if three else 'A,B,Start,Select')
    out += ['    </rom>', '', buttons, '</misterromdescription>', '']
    return '\n'.join(out), default


def main(argv):
    import mra_build
    outdir = argv[1] if len(argv) > 1 else os.path.join(paths.REPO, 'mra')
    bad = 0
    for s in ['silvmil', 'puzzlove', 'puzzlovek']:
        text, default = mra_text(s)
        title, _, _, _, parent, fname, folder, _ = GAMES[s]
        d = os.path.join(outdir, folder) if folder else outdir
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, fname + '.mra')
        open(path, 'w', encoding='utf-8', newline='\n').write(text)
        zips = '|'.join(os.path.join(paths.ROMS, n + '.zip') for n in ([s, parent] if parent else [s]) if os.path.exists(os.path.join(paths.ROMS, n + '.zip')))
        # the md5 MiSTer computes: each part's data as read, in order (Main_MiSTer support/arcade/mra_loader.cpp) -- with interleaved
        # parts that is not the image's md5, and MiSTer does not send a ROM whose md5 does not match
        md5 = mra_build.mister_md5(path, zips)
        text = text.replace('md5="None"', 'md5="%s"' % md5, 1)
        open(path, 'w', encoding='utf-8', newline='\n').write(text)
        # check: the image the .mra builds from the merged romset == silvmil_image.py's, and the .mra's md5 is MiSTer's
        img, md5_check = mra_build.build(path, zips)
        ok = img == IMG.build(s) and md5_check == md5
        bad += 0 if ok else 1
        print('%-9s %-48s %s, MiSTer md5 %s, DSW default %04X' % (s, os.path.relpath(path, outdir),
              'image identical' if ok else 'IMAGE DIFFERS', md5, default))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
