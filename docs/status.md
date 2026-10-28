# Status and measurements (2026-10-28)

Every number below is from MAME 0.289 and Verilator / Quartus runs on the owner's machine; the scripts are in `../tools/`
(`tools/paths.py` says where they look for MAME, the romsets and the scratch folder `work/`), the benches in `../sim/`.
**Tested on a real MiSTer** by the owner (`silvmil_20261028`): all three sets load and play.

## The board (from MAME's `src/mame/f32/silvmil.cpp`, kept in `../../ref/mame/`)

"Yet another Data East / Tumble Pop derived hardware", close to the F2 System board of the owner's Cross Pang core. One memory map
for all three sets:

| | Silver Millennium | PuzzLove | PuzzLove (Korea) |
|---|---|---|---|
| 68000 | 12 MHz | 12 MHz | 12 MHz |
| Z80 | 4.096 MHz | 4 MHz | 4 MHz |
| YM2151 | 14.31818 / 4 MHz | 14.31818 / 4 MHz | 15 / 4 MHz |
| OKI M6295 (pin 7 high) | 4.096 / 4 MHz | 4 / 4 MHz | 4 / 4 MHz |
| tile ROM | 4 MB (32768 tiles) | 1 MB (8192) | 1 MB (8192) |
| decospr bootleg_type | 0 | 1 | 1 |
| screen | ROT270 | ROT0 | ROT0 |

* 68000 map: ROM 000000-0FFFFF; 100000 tile bank select `(data >> 8) & 3`, 10000E bank data `(data >> 8) & 1F` (four 5-bit banks,
  cleared by the machine's reset); 100002 FG x, 100004 FG y + 8, 100006 BG x + 4, 100008 BG y + 8; FG RAM 120000-120FFF, BG RAM
  122000-122FFF (64 x 32 tiles each, `scan_rows`); palette 200000-2005FF (xRGB555); sprites 210000-2107FF; sound latch 270001;
  inputs 280000 / 2 / 4; work RAM 300000-30FFFF. Level 6 interrupt at vertical blank (hold line).
* Z80 map: ROM 0000-BFFF, YM2151 C000-C001, OKI C002 (mirror C003), latch C006 (read; no interrupt: polled), RAM D000-D7FF. The YM2151's
  IRQ is the Z80's INT; the NMI is not connected (the driver's TODO).
* Mix: YM2151 both outputs and the OKI, each at route 0.25, one speaker.
* Tilemaps: tile = `code + bank[sel] * 0x400` (modulo the ROM's tiles), BG colours 0x200-0x2FF (opaque), FG 0x100-0x1FF (pen 0
  transparent), sprites 0x000-0x1FF. Draw order BG, FG, sprites (decospr, offsets 5 / 7, bootleg: no `~multi` masking).
* decospr bootleg_type 1 (PuzzLove): flash = w0 bit 10, height = `bitswap<2>(w0, 9, 12)`; type 0: bit 12 and `(10, 9)`.

## ROM path

| check | result |
|---|---|
| `tools/silvmil_rom.py check`: the regions built from the ROM_START lists (incl. Silver Millennium's ROM_CONTINUE-split tile ROMs) vs MAME's loaded regions (`tools/lua/dump_regions.lua`) | all 3 sets x 5 regions (maincpu, audiocpu, oki, tiles, sprites) byte-identical |
| `tools/silvmil_image.py check`: the loader's graphics remap + the renderer's pixel pick vs MAME's gfx decode (`tlayout_alt` tiles, `tlayout` sprites) | all 98,304 tiles of the three sets (32768 + 16384 Silver Millennium, 8192 + 16384 each PuzzLove), every row and pixel, identical |
| `tools/make_mra.py`: the image `tools/mra_build.py` builds from each `.mra` and the merged romset vs `silvmil_image.py` | all three byte-identical; the MRAs carry MiSTer's md5 (`mra_build.mister_md5`) |
| DIP switch defaults the script derives from the driver's `INPUT_PORTS` (incl. puzzlovek's `PORT_INCLUDE` + `PORT_MODIFY`) vs MAME's port values (`tools/lua/ports.lua`) | FBFF silvmil, FDFF puzzlove, FDFE puzzlovek: equal |

## Reference renderer (`tools/silvmil_ref.py`, MAME's `screen_update` + `decospr` written out)

165 MAME frames (`tools/capture.py`, scripted play: coin 200, start 260, random joystick and buttons from 330): 47 Silver Millennium,
47 PuzzLove, 31 PuzzLove (Korea) at every 75th frame, and 20 consecutive frames each of Silver Millennium and PuzzLove (flash
parity): **0 differing pixels**. Drawing PuzzLove with the standard sprite format instead of bootleg_type 1 gives 3,669 differing
pixels over 2 frames: the comparison discriminates.

Features in those frames: sprites 1 / 2 / 4 / 8 tiles tall in all three sets, flashing entries (Silver Millennium, PuzzLove Korea),
flip Y (Silver Millennium), 31 scroll states (Silver Millennium), tile bank changes incl. bank 28 (Silver Millennium: only possible
with the 5-bit banks) and bank 4 (PuzzLove Korea). Never seen: the wide flag (w0 bit 11), flip X.

## Buttons (`tools/probe.py`, MAME)

`probe.py` presses an input at the 68000's port read and compares the pictures with a run without the press. MAME 0.289's INPUT_PORTS
give both games three buttons.

| set | button 1 | button 2 | button 3 |
|---|---|---|---|
| silvmil | one shot per press (held: one shot, no auto-fire; tapped every 8 frames: a stream) | a burst of flame around the ship, over a second (bomb) | no effect: tapped in play, held 2 s in play, at the player select |
| puzzlove | the player jumps along the path and picks up what is there (the apple: 2000 points) | "TIME" over the player, the timer 027 -> 037, one of the three stock dots at the left gone | no effect: tapped and held 2 s in play |

Neither game's service mode has an input test or a flip setting (DIP pages, colour test, sound test only), and no DIP switch flips
the screen: Flip Screen is the core's own.

## RTL, frozen states (`tools/corpus_rtl.py`)

The RTL's picture of each MAME state (tile, sprite and palette RAMs and the registers loaded, both CPUs held in reset) against MAME's
pixels, through the real loader layout and SDRAM controller and a behavioural SDRAM chip:

| set | states | pixel-identical |
|---|---|---|
| silvmil (scripted play, every 75th frame) | 47 | 47 |
| puzzlove (the same) | 47 | 47 |
| puzzlovek (every 75th frame to 2400) | 31 | 31 |
| silvmil, 20 consecutive frames (900-919: flash parity) | 20 | 20 |
| puzzlove, 20 consecutive frames | 20 | 20 |
| silvmil, **Flip Screen** (every 3rd state; vs MAME's picture turned 180 degrees, `corpus_rtl.py --flip`) | 16 | 16 |
| puzzlove, **Flip Screen** | 16 | 16 |

**197 of 197 states pixel-identical.**

## Scale while the picture is turned (`sim/scale/run.sh`)

The framework's `video_freak` measures the raster before it is turned (320 x 240), so `Silvmil.sv` gives a second
`video_scale_int` the turned size (rows as the width, dots as the height) and the scaler gets its result while Orientation is Vert.
That module alone, with the sizes the core gives it:

| HDMI | picture | Normal | every integer mode |
|---|---|---|---|
| 1920 x 1080 | turned 240 x 320 (3:4) | 3:4 | 720 x 960 (x 3) |
| 1280 x 720 | turned 240 x 320 | 3:4 | 480 x 640 (x 2) |
| 1280 x 1024 | turned 240 x 320 | 3:4 | 720 x 960 (x 3) |
| 1920 x 1080 | as is 320 x 240 (Horz, and PuzzLove) | 4:3 | 1280 x 960 (x 4) |

(With the scandoubler the turned picture is 480 x 640 and gets x 1 on all three, as the doubled 640 x 480 raster gets x 2 on 1080p:
the same rule.)

## The scandoubler (`sim/sd/sweep.sh`)

This core's raster (`rtl/sm_video.sv`, unchanged from Cross Pang) through CRT Adjust into the framework's `arcade_video`, 4 frames each:
CRT Adjust On without the gate and forced_scandoubler: **STALLED** (no VGA_VS: why the gate exists); with the core's gate (CRT Adjust
off while the scandoubler is in use): 480 lines, each source line twice, in order; HQ2x and CRT 25 %: 480 lines in order; 15 kHz with
and without CRT Adjust: 240 lines in order. The same as the Cross Pang core's results.

## The loader (`sim/run.sh <image> 0 <out> +load=fast | +load=rtl`)

The image pushed through `rtl/sm_mem.sv` (the RTL remap), then every SDRAM word, Z80 ROM byte and configuration byte read back:

| run | SDRAM words differing | Z80 ROM bytes differing | configuration bytes differing |
|---|---|---|---|
| silvmil, fast load (`rtl/sm_fastload.sv` from the bench's DDR3 model: busy at random, beats late and with gaps; image at 0x32000000) | 0 of 3,801,088 | 0 of 65,536 | 0 of 8 |
| puzzlove, the ordinary byte download | 0 of 3,801,088 | 0 of 65,536 | 0 of 8 |

The fast load takes 27.0 M clocks (0.28 s) from the end of the empty download to the last word in the SDRAM.

## Whole machine from reset (`sim/run.sh ... +inputs=`, `tools/sys_match.py`)

Silver Millennium from reset with MAME's input log (`dump_state.lua` INPUTLOG, scripted play: coin at frame 200, start at 260, random
joystick and buttons from 330), every picture from frame 58 against MAME's picture of the same frame (`work/states/silvmil_all`),
bench defaults `+foff=-2 +ioff=1` (Cross Pang's measurements; the same board structure):

* frames 58-119 (the Para logo and its fades): identical except 61 and 62, a fade step one frame apart (MAME already black where the
  core still shows white; from 63 on identical again) -- the CPU's pace against the raster, as in Cross Pang's colour test.
* frames 120-334 (the attract mode, the coin at 200, the start at 261, the player select): every picture is MAME's picture of the
  same frame or of the next one. The game animates on alternate frames, and the core reaches that update one frame earlier on every
  second frame (no sprite has the flash bit in these frames: it is the game's main loop against the 60.096 Hz raster and the 68000's
  wait states, not the video). Frame 202 (the coin) is 304 pixels from MAME's next frame (the credit counter).
* from 335 on, with the random joystick, the game state drifts from MAME's (the inputs are read at slightly different moments);
  the comparison stops being a test of the core there.
* the second run below: 0 lines over their budget in 181 frames from reset, the longest 1,272 of 6,144 clocks.

A second run on the final RTL (flash phase reset by the machine's reset, the sprite scan's extra register) to frame 178: the same
pictures.

## Build (Quartus Prime Lite 17.0.2, `quartus_sh --flow compile Silvmil`, about 45 min)

| | |
|---|---|
| ALMs | 14,436 / 41,910 (34 %) |
| block memory | 269 / 553 RAM blocks (49 %) |
| DSP | 36 / 112 |
| PLLs | 3 / 6 |
| setup slack, machine clock (96 MHz) | +0.609 ns; no negative slack anywhere; hold > 0.24 ns |
| `tools/check_ram_depth.py` | 0 problems |

The first build missed 96 MHz by 1.5 ns inside jt51 (its phase generator): jt51 steps on its enable, so `Silvmil.sdc` gives its
internal paths four clocks, as the owner's Metro core does. The second missed by 0.6 ns on the sprite scan (sprite RAM -> PuzzLove's
format muxes -> hit test -> tile number): the scan now evaluates a registered copy of the entry (one clock more per hit; all frozen
states re-checked: 60 of 60 identical, Flip Screen included), and on the static aspect / orientation settings (now registered).
`releases/silvmil_20261028.rbf` is the third build.

## Sound (`tools/cmp_audio.py`; MAME `-wavwrite` at 48 kHz, the same scripted play)

The run from reset (`+wav +mix`: the core's mix, `Silvmil.sv`, Volume Normal) against MAME's recording, 1-7 s (the boot sound, the
attract mode, the coin): lag 4 samples, **envelope correlation 0.976**, RMS 1147 (core) vs 1137 (MAME): the level is MAME's within
0.1 dB. The sample correlation is about 0: jt51 and MAME's ymfm are different FM implementations, the waveforms' phases differ while
the envelopes agree. 421 frames, 0 lines over budget. Note that MAME's mix is quiet (each chip at route 0.25: about -29 dBFS RMS in
the attract mode); the OSD's Volume only goes lower.
