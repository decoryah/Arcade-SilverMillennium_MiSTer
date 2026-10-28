// Clock enables from the 96 MHz machine clock.  The board has three crystals (silvmil.cpp: "OSC on Silver Millennium are 12MHz,
// 14.31818MHz & 4.096MHz"; the PuzzLove boards have 4 MHz in place of 4.096 MHz, the Korean one 15 MHz in place of 14.31818 MHz):
//
//                  Silver Millennium (0)    PuzzLove (1)             PuzzLove Korea (2)
//   68000          12 MHz                   12 MHz                   12 MHz           cen_phi1 / cen_phi2, alternating, every 4 clocks
//   Z80            4.096 MHz                4 MHz                    4 MHz            cen_z80
//   YM2151         14.31818 / 4 MHz         14.31818 / 4 MHz         15 / 4 MHz       cen_ym (the chip's clock), cen_ym_p1 (every second)
//   OKI M6295      4.096 / 4 MHz            4 / 4 MHz                4 / 4 MHz        cen_oki (pin 7 high: sample rate clock / 132)
//
// The 68000's clock is an exact division (96 / 8); the others come from phase accumulators (a pulse whenever the sum passes 96 MHz),
// exact on average.  The dot clock (6 MHz = 96 / 16) is generated in sm_video.
`default_nettype none
module sm_cen (
    input  logic       clk,
    input  logic [1:0] sel,                                 // the set's sound clocks (the table above)
    output logic       cen_phi1, cen_phi2,
    output logic       cen_z80,
    output logic       cen_ym, cen_ym_p1,
    output logic       cen_oki
);
    localparam [27:0] MCLK = 28'd96_000_000;

    // the CPU's phase enables alternate on a 24 MHz step (one every 4 clocks): each phase at 12 MHz
    logic [1:0] d4 = 2'd0;
    logic       ph = 1'b0;
    always_ff @(posedge clk) begin
        d4 <= d4 + 2'd1;
        cen_phi1 <= 1'b0;
        cen_phi2 <= 1'b0;
        if (d4 == 2'd3) begin
            ph <= ~ph;
            if (ph) cen_phi2 <= 1'b1; else cen_phi1 <= 1'b1;
        end
    end

    // phase accumulators
    logic [27:0] f_z80, f_ym, f_oki;
    always_comb begin
        f_z80 = (sel == 2'd0) ? 28'd4_096_000 : 28'd4_000_000;
        f_ym  = (sel == 2'd2) ? 28'd3_750_000 : 28'd3_579_545;
        f_oki = (sel == 2'd0) ? 28'd1_024_000 : 28'd1_000_000;
    end
    logic [27:0] a_z80 = 28'd0, a_ym = 28'd0, a_oki = 28'd0;
    wire  [27:0] n_z80 = a_z80 + f_z80, n_ym = a_ym + f_ym, n_oki = a_oki + f_oki;
    logic        ym_ph = 1'b0;
    always_ff @(posedge clk) begin
        cen_z80   <= 1'b0;
        cen_ym    <= 1'b0;
        cen_ym_p1 <= 1'b0;
        cen_oki   <= 1'b0;
        if (n_z80 >= MCLK) begin a_z80 <= n_z80 - MCLK; cen_z80 <= 1'b1; end else a_z80 <= n_z80;
        if (n_oki >= MCLK) begin a_oki <= n_oki - MCLK; cen_oki <= 1'b1; end else a_oki <= n_oki;
        if (n_ym >= MCLK) begin
            a_ym      <= n_ym - MCLK;
            cen_ym    <= 1'b1;
            cen_ym_p1 <= ym_ph;
            ym_ph     <= ~ym_ph;
        end else a_ym <= n_ym;
    end
endmodule
`default_nettype wire
