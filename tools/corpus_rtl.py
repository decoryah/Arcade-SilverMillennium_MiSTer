#!/usr/bin/env python3
"""Frozen-state check of the RTL: every captured MAME state is loaded into the RAMs of the bench (sim/run.sh +state=, both CPUs held in
reset) and the RTL's picture is compared with the pixels MAME drew from the same state.

    corpus_rtl.py <set> <state dir> [--limit N] [--step K] [--flip]   (the bench must be built: run sim/run.sh once;
                                                               SILVMIL_BDIR picks its build directory, default $HOME/build_silvmil)

Images: work/<set>.rom (built here with tools/silvmil_image.py if missing).  Pictures: work/rtl_corpus/<set>/ (<set>_flip/ with --flip:
the bench's Flip Screen, compared with MAME's pictures turned 180 degrees).
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import silvmil_image
import cmp_frame


def wsl_path(p):
    p = os.path.abspath(p)
    return '/mnt/' + p[0].lower() + p[2:].replace('\\', '/')


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    if len(args) < 2:
        print(__doc__)
        return 2
    s, sdir = args[0], args[1]
    limit = int(argv[argv.index('--limit') + 1]) if '--limit' in argv else 0
    step = int(argv[argv.index('--step') + 1]) if '--step' in argv else 1
    flip = '--flip' in argv
    rom = os.path.join(paths.WORK, s + '.rom')
    if not os.path.exists(rom):
        open(rom, 'wb').write(silvmil_image.build(s))
    states = sorted(f[:-5] for f in os.listdir(sdir) if f.endswith('.regs'))[::step]
    if limit:
        states = states[:limit]
    out = os.path.join(paths.WORK, 'rtl_corpus', s + ('_flip' if flip else ''))
    os.makedirs(out, exist_ok=True)
    # one WSL call runs the bench for every state (2 pictures each: the first complete one is frame 1), $SILVMIL_JOBS (default 7) at
    # a time (a state takes about 40 s)
    bdir = os.environ.get('SILVMIL_BDIR', '$HOME/build_silvmil')      # the bench's build directory in WSL (sim/run.sh BDIR)
    lines = []
    for st in states:
        # no stale picture may pass for this run's: remove the state's old ones first
        for f in os.listdir(out):
            if f.startswith(st + '.f') and f.endswith('.ppm'):
                os.remove(os.path.join(out, f))
        # +foff=-1: the first complete picture drawn from the loaded state (the one after the first vertical blank) is named frame 1
        lines.append('nice -n 10 ./obj/Vtb_top %s 1 %s +state=%s +first=1 +foff=-1%s > /dev/null 2>&1' % (
            wsl_path(rom), wsl_path(os.path.join(out, st)), wsl_path(os.path.join(sdir, st)), ' +flip' if flip else ''))
    jobs = os.path.join(out, 'jobs.txt')
    open(jobs, 'w', newline='\n').write('\n'.join(lines) + '\n')
    script = os.path.join(out, 'run.sh')
    open(script, 'w', newline='\n').write('\n'.join([
        'export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"', 'cd "%s"' % bdir,
        'xargs -P %d -d "\\n" -I CMD bash -c CMD < "%s"' % (int(os.environ.get('SILVMIL_JOBS', '7')), wsl_path(jobs))]) + '\n')
    r = subprocess.run(['wsl.exe', '-d', 'Ubuntu', '--', 'bash', wsl_path(script)])
    if r.returncode:
        print('bench failed (%d)' % r.returncode)
        return 1
    total = bad = 0
    for st in states:
        ppm = os.path.join(out, st + '.f00001.ppm')
        if not os.path.exists(ppm):
            print('%s: no picture (the bench did not write it)' % st)
            total += 1
            bad += 1
            continue
        n = cmp_frame.compare(ppm, os.path.join(sdir, st), os.path.join(out, st + '.diff.png'), flip)
        total += 1
        bad += 1 if n else 0
    print('%s: %d of %d states pixel-identical' % (s, total - bad, total))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
