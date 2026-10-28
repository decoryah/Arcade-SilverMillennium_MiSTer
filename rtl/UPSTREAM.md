# Files in this directory derived from other projects

The core started as a copy of the owner's Cross Pang core (`crospang-mister`, MAME's `f32/crospang.cpp`: the same family of
"bootleg Tumble Pop" boards), on 2026-10-28.  What each file kept and what changed:

| File | Derived from | Licence | Changes for this core |
|---|---|---|---|
| `sdram_ctrl.sv` | the owner's `crospang-mister/mister/rtl/sdram_ctrl.sv` (from `ohmygod-mister` / `mcatadv-mister`, itself the Pocket Gaiapolis core's multi-port controller by plasticbugs, carried to MiSTer, with the Punch-Out!! core's `sdram16.sv` pin-level behaviour) | GPL-3.0-or-later (`../LICENSE`) | none: byte-identical |
| `sm_ram.sv` | `cp_ram.sv` (from `omg_ram.sv` / `mcatadv_ram.sv`: block RAMs written the way Quartus 17 infers M10K) | same | renamed |
| `sm_cache.sv` | `cp_cache.sv` (from `omg_cache.sv`) | same | renamed |
| `sm_video.sv` | `cp_video.sv` (from `omg_video.sv`) | same | renamed: the same 320 x 240 raster, xRGB555 palette |
| `sm_mem.sv` | `cp_mem.sv` (from `omg_mem.sv` / `mcatadv_mem.sv`: loader, burst arbiter) | same | this board's image layout: the 4 MB tile ROM (15-bit tile numbers in the remap), the sprite ROM, samples, Z80 program and configuration bytes at new offsets |
| `sm_crtadj.sv` | `cp_crtadj.sv` (the Metro core's `metro_crtadj.sv`: glue for rmonic79's CRT Adjust, `../modules/crt_adjust`) | same | renamed; same totals (`VTOTAL` 260, `HTOTAL` 384) |
| `sm_fastload.sv` | `cp_fastload.sv` (the fast load of the owner's Monster Maulers / Violent Storm cores) | same | renamed; in `../Silvmil.sv` it now shares the DDR3 port with screen_rotate's frame buffer |
| `sm_main.sv` | `cp_main.sv` | same | Silver Millennium's map (one for all three sets): 64 x 32 tile RAMs (0x1000 bytes each), 5-bit tile banks cleared by the machine's reset, the one scroll register order, work RAM at 0x300000 |
| `sm_render.sv` | `cp_render.sv` | same | 64 x 32 tilemaps (1024 x 512, scan_rows), 15-bit tile numbers, decospr's bootleg_type 1 for PuzzLove (flash bit, height bits), Flip Screen (the line and the dots turned) |
| `sm_core.sv` | `cp_core.sv` | same | wiring for the above, the YM2151's stereo outputs, the per-set clocks |
| `pll.v`, `pll.qip`, `pll/` | the Metro core's PLL via `crospang-mister` (reference 50 MHz: 96 MHz machine clock, 96 MHz shifted for the SDRAM chip) | same | none |
| `../sim/` | `crospang-mister/mister/sim` (the owner's Monster Maulers core's scandoubler bench under `sd/`) | same | this board's image layout, state format, jt51 |

Written for this core (not derived): `sm_sound.sv` (Z80, YM2151, OKI, latch; the sound board's memory-mapped chips; structure after
`cp_sound.sv`), `sm_cen.sv` (the clock enables of the board's three crystals, per set).  The 68000 core (`../modules/cpu-fx68k`), the
Z80 (`../modules/cpu-tv80`), the YM2151 (`../modules/jt51`), the OKI (`../modules/jt6295`) and the CRT Adjust page
(`../modules/crt_adjust`) are vendored: `../modules/VENDOR.md`.  The picture's rotation is the framework's `screen_rotate`
(`../sys/arcade_video.v`), wired as in the owner's Gaiapolis and PGM2 cores.
