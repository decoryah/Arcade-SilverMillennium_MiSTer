#!/usr/bin/env python3
"""Builds the ROM regions of the silvmil.cpp sets from the MAME zips, exactly as ROM_START in src/mame/f32/silvmil.cpp
(MAME 0.289) loads them, and checks them against MAME's own regions (tools/lua/dump_regions.lua).

    silvmil_rom.py check [set ...]      compare with work/regions/<set>/<region>.bin (all three sets by default)
    silvmil_rom.py build <set> <dir>    write <region>.bin for the set

Merged sets: puzzlovek lives in the parent's zip (puzzlove); the files only they have are in a <set>/ folder there.
Load modes: 'b' = ROM_LOAD16_BYTE (every second byte), 'n' = ROM_LOAD (plain).  A tuple (name, mode, offset, size[, continues])
with continues = [offset, ...]: ROM_CONTINUE chunks of `size` bytes taken from the same file in turn.
"""
import os
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths

# set -> (zip, [(region, size, [entries])])
def _tiles_1m(a, b):
    return [(a, 'b', 0x00000, 0x20000, [0x80000, 0x40000, 0xc0000]),
            (b, 'b', 0x00001, 0x20000, [0x80001, 0x40001, 0xc0001])]


_SPR_PL = lambda a, b, c, d: [(a, 'b', 0x000000, 0x80000), (b, 'b', 0x000001, 0x80000),
                              (c, 'b', 0x100000, 0x80000), (d, 'b', 0x100001, 0x80000)]


def _t4(name, lo):
    """silvmil's tile ROMs: four 0x20000-byte chunks of a 0x80000-byte file (ROM_LOAD16_BYTE + three ROM_CONTINUE)."""
    return (name, 'b', lo, 0x20000, [lo + 0x200000, lo + 0x040000, lo + 0x240000])


SETS = {
    'silvmil': ('silvmil', [
        ('maincpu', 0x100000, [('d-13_u3.bin', 'b', 0x00000, 0x40000), ('d-14_u2.bin', 'b', 0x00001, 0x40000)]),
        ('audiocpu', 0x10000, [('d-11_uz02.bin', 'n', 0, 0x10000)]),
        ('oki', 0x40000, [('d-12_uz1.bin', 'n', 0, 0x40000)]),
        ('tiles', 0x400000, [_t4('d-16_u41.bin', 0x000000), _t4('d-15_u42.bin', 0x000001),
                             _t4('d-20_pat01.bin', 0x080001), _t4('d-17_pat11.bin', 0x080000),
                             _t4('d-17_pat02.bin', 0x100001), _t4('d-18_pat12.bin', 0x100000),
                             _t4('d-18_pat03.bin', 0x180001), _t4('d-19_pat13.bin', 0x180000)]),
        ('sprites', 0x200000, _SPR_PL('d-17_u53.bin', 'd-18_u54.bin', 'd-19_u55.bin', 'd-20_u56.bin')),
    ]),
    'puzzlove': ('puzzlove', [
        ('maincpu', 0x100000, [('3.u3', 'b', 0x00000, 0x40000), ('4.u2', 'b', 0x00001, 0x40000)]),
        ('audiocpu', 0x20000, [('1.uz02', 'n', 0, 0x20000)]),
        ('oki', 0x40000, [('2.uz11', 'n', 0, 0x40000)]),
        ('tiles', 0x100000, _tiles_1m('10.u41', '9.u42')),
        ('sprites', 0x200000, _SPR_PL('5.u53', '6.u54', '7.u55', '8.u56')),
    ]),
    'puzzlovek': ('puzzlove', [
        ('maincpu', 0x100000, [('3.u3', 'b', 0x00000, 0x40000), ('4.u2', 'b', 0x00001, 0x40000)]),
        ('audiocpu', 0x20000, [('1.uz02', 'n', 0, 0x20000)]),
        ('oki', 0x40000, [('2.uz11', 'n', 0, 0x40000)]),
        ('tiles', 0x100000, _tiles_1m('10.u41', '9.u42')),
        ('sprites', 0x200000, _SPR_PL('5.u53', '6.u54', '7.u55', '8.u56')),
    ]),
}

# the files a clone has of its own, in <clone>/ inside the parent's zip (merged set); everything else is the parent's
CLONE_DIR = {'puzzlovek': 'puzzlovek'}
CLONE_OWN = {
    'puzzlovek': {'3.u3', '4.u2', '10.u41', '9.u42', '5.u53', '6.u54', '7.u55', '8.u56'},
}


def open_zip(zname):
    return zipfile.ZipFile(os.path.join(paths.ROMS, zname + '.zip'))


def get_file(z, setname, name):
    """The bytes of a ROM file of `setname` inside its (merged) zip."""
    names = set(z.namelist())
    if setname in CLONE_OWN and name in CLONE_OWN[setname]:
        return z.read(CLONE_DIR[setname] + '/' + name)
    if name in names:
        return z.read(name)
    raise KeyError('%s: %s not in the zip' % (setname, name))


def place(region, mode, offset, data):
    if mode == 'n':
        region[offset:offset + len(data)] = data
    else:                                              # ROM_LOAD16_BYTE: every second byte
        region[offset:offset + 2 * len(data):2] = data


def build(setname):
    zname, regions = SETS[setname]
    z = open_zip(zname)
    out = {}
    for rname, size, entries in regions:
        reg = bytearray(size)
        for e in entries:
            fname, mode, offset, n = e[:4]
            conts = e[4] if len(e) > 4 else []
            data = get_file(z, setname, fname)
            total = n * (1 + len(conts))
            if len(data) != total:
                raise ValueError('%s/%s: file is %d bytes, ROM_START wants %d' % (setname, fname, len(data), total))
            place(reg, mode, offset, data[:n])
            for k, off in enumerate(conts):
                place(reg, mode, off, data[n * (k + 1):n * (k + 2)])
        out[rname] = bytes(reg)
    return out


def check(names):
    bad = 0
    for s in names:
        mine = build(s)
        for rname, img in sorted(mine.items()):
            p = os.path.join(paths.WORK, 'regions', s, rname + '.bin')
            if not os.path.exists(p):
                print('%-9s %-9s no MAME dump (%s)' % (s, rname, p))
                bad += 1
                continue
            ref = open(p, 'rb').read()
            if ref == img:
                print('%-9s %-9s identical (%d bytes)' % (s, rname, len(img)))
            else:
                first = next((i for i in range(min(len(ref), len(img))) if ref[i] != img[i]), None)
                print('%-9s %-9s DIFFERENT: size %d vs MAME %d, first difference at %s' % (s, rname, len(img), len(ref), first))
                bad += 1
    return bad


def main(argv):
    if len(argv) >= 2 and argv[1] == 'check':
        return 1 if check(argv[2:] or sorted(SETS)) else 0
    if len(argv) == 4 and argv[1] == 'build' and argv[2] in SETS:
        os.makedirs(argv[3], exist_ok=True)
        for rname, img in build(argv[2]).items():
            open(os.path.join(argv[3], rname + '.bin'), 'wb').write(img)
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
