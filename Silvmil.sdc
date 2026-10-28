derive_pll_clocks
derive_clock_uncertainty

# ==============================================================================
# SDRAM. The chip is clocked by the PLL's second 96 MHz output, shifted about half a period (rtl/pll/pll_0002.v, JTFRAME's phase
# for MiSTer SDRAM); like the owner's other cores the pin's clock is modelled as the machine clock inverted, and the read data --
# launched by the chip's edge, captured by sdram_ctrl's input register three edges after the READ command -- gets a two-cycle
# path. The register assignments in sys/sys.tcl put the SDRAM pins' registers in the IO cells.
# ==============================================================================
set sdram_clk_src [get_pins -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sdram_clk_src] == 0 } {
    set sdram_clk_src [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
create_generated_clock -name SDRAM_CLK -source $sdram_clk_src -divide_by 1 -phase 180 [get_ports {SDRAM_CLK}]

set sys_clk [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sys_clk] == 0 } {
    set sys_clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -setup -end 2
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -hold  -end 2

# the controller's round-robin pointer settles long before it is used (S_IDLE -> S_ARB)
set_multicycle_path -setup 3 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]
set_multicycle_path -hold  2 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]

# ==============================================================================
# fx68k steps on its phase enables (sm_cen.sv): one every 4 machine clocks (12 MHz).  Only paths inside the CPU are relaxed; the
# paths between it and the bus logic, the RAMs and DTACK stay single-cycle.
# ==============================================================================
set_multicycle_path -setup -end 2 -from [get_registers {emu|u_core|u_main|*u_cpu|*}] -to [get_registers {emu|u_core|u_main|*u_cpu|*}]
set_multicycle_path -hold  -end 1 -from [get_registers {emu|u_core|u_main|*u_cpu|*}] -to [get_registers {emu|u_core|u_main|*u_cpu|*}]

# jt6295 steps on its clock enable, every 94-96 clocks (1.024 / 1 MHz)
set_multicycle_path -setup -end 2 -from [get_registers {emu|u_core|u_sound|u_oki|*}] -to [get_registers {emu|u_core|u_sound|u_oki|*}]
set_multicycle_path -hold  -end 1 -from [get_registers {emu|u_core|u_sound|u_oki|*}] -to [get_registers {emu|u_core|u_sound|u_oki|*}]

# the Z80 (tv80s_cen) steps on its clock enable, every 23-24 clocks (4.096 / 4 MHz); its bus outputs are registers read by the
# sound board's logic on every clock, which stay single-cycle
set_multicycle_path -setup -end 2 -from [get_registers {emu|u_core|u_sound|u_cpu|*}] -to [get_registers {emu|u_core|u_sound|u_cpu|*}]
set_multicycle_path -hold  -end 1 -from [get_registers {emu|u_core|u_sound|u_cpu|*}] -to [get_registers {emu|u_core|u_sound|u_cpu|*}]

# jt51 (YM2151) steps on its clock enable, every 25-27 clocks (3.579545 / 3.75 MHz; cen_p1 every second one): its internal paths
# have several clocks, as in the owner's Metro core and Arcade-HyperDuel_MiSTer (the first build missed 96 MHz by 1.5 ns in jt51_pg).
# The paths into it from the sound board (the held write, cs_n with cen_p1) stay single-cycle.
set_multicycle_path -setup -end 4 -from [get_registers {emu|u_core|u_sound|u_ym|*}] -to [get_registers {emu|u_core|u_sound|u_ym|*}]
set_multicycle_path -hold  -end 3 -from [get_registers {emu|u_core|u_sound|u_ym|*}] -to [get_registers {emu|u_core|u_sound|u_ym|*}]

# The framework's HQ2x scandoubler (sys/hq2x.sv): the blender's registers all advance on `clk_en` = ce_x4 of the scandoubler, which
# is 4 clocks apart for this core's 16-clock pixels, so a path from one blender register to another has two clocks.
set_multicycle_path -setup -end 2 -from [get_registers {emu|arcade_video|video_mixer|sd|Hq2x|blender|*}] -to [get_registers {emu|arcade_video|video_mixer|sd|Hq2x|blender|*}]
set_multicycle_path -hold  -end 1 -from [get_registers {emu|arcade_video|video_mixer|sd|Hq2x|blender|*}] -to [get_registers {emu|arcade_video|video_mixer|sd|Hq2x|blender|*}]
