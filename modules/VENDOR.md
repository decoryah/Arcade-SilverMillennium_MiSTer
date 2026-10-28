# Vendored modules

Third-party HDL cores copied into the tree -- no submodules, so the build is self-contained and reproducible.
Each keeps its own LICENSE alongside.

| module | upstream | via | licence |
|---|---|---|---|
| cpu-fx68k (+ `../microrom.mem`, `../nanorom.mem`) | https://github.com/ijor/fx68k (Jorge Cwik) | copied unchanged from the owner's `crospang-mister/mister/modules/cpu-fx68k` (the `ohmygod-mister` / `metro-mister` / `mcatadv-mister` copy, the one that builds with Quartus 17 and runs in Verilator with `--no-assert-case -Wno-BLKANDNBLK`) on 2026-10-28 | GPL-3.0 |
| cpu-tv80 | https://github.com/hoglet67/tv80 (Guy Hutchison's TV80) | the five files the core needs (`tv80_alu.v`, `tv80_core.v`, `tv80_mcode.v`, `tv80_reg.v`, `tv80s_cen.v`: the clock-enable wrapper of plasticbugs/punchout), copied unchanged from the owner's `crospang-mister/mister/modules/cpu-tv80` (the `gaiapolis-mister` copy) on 2026-10-28 (`tv80s.v` is kept for reference, not built) | MIT |
| jt51 (YM2151) | https://github.com/jotego/jt51 (Jose Tejada) | the 22 `hdl/jt51*.v` files, copied unchanged from the owner's `metro-mister/mister/modules/jt51` (itself from searchsolved/Arcade-HyperDuel_MiSTer `rtl/vendor/jt51`, commit 7f154f1) on 2026-10-28; a write is held until `cen_p1`, as those cores do (`../rtl/sm_sound.sv`) | GPL-3.0 |
| jt6295 (OKI M6295) | https://github.com/jotego/jt6295 (Jose Tejada) | the 8 files `hdl/jt6295*.v` (INTERPOL=0 needs no others), copied unchanged from `crospang-mister/mister/modules/jt6295` (the `ohmygod-mister` copy) on 2026-10-28 | GPL-3.0 |
| crt_adjust (CRT Adjust: H-Size, H-Position, V-Shift) | https://github.com/rmonic79/MiSTer-CRT-Adjust (Umberto Parisi, rmonic79) | `rtl/crt_adjust.sv` of the upstream at commit c682de9, copied unchanged from `crospang-mister/mister/modules/crt_adjust` (the Metro core's copy) on 2026-10-28, which carries **two changes marked `METRO` in the file** (the sign extension of a negative H-Position in the content-shift mode, and the picture / vertical-blank gating with the vertical blank of the line being emitted); the glue is `../rtl/sm_crtadj.sv` | GPL-3.0-or-later |

The fx68k microcode ROM files are read with `$readmemb("microrom.mem")` / `"nanorom.mem"`, i.e. relative to the directory the simulator
or Quartus runs in: `sim/run.sh` copies them next to the binary, Quartus finds them in the project directory.

jt51 raises its busy flag only for a write that comes with `cen_p1`: `sm_sound.sv` holds a Z80 write to C000 / C001 until the
next `cen_p1` (at most 0.56 us) and gives it to the chip then.

To update one: re-copy from upstream at the new commit and record it here.
