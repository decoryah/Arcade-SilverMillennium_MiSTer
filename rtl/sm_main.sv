// Para "Silver Millennium" board (MAME src/mame/f32/silvmil.cpp, silvmil_state::mem_map): the 68000 side.
//
// The 68000 (fx68k, 12 MHz), its memory map, the RAMs the video reads, the inputs, the tile bank registers, the scroll registers and
// the sound latch.  The same map for Silver Millennium and both PuzzLove sets.
//
//   000000-0FFFFF  program ROM (SDRAM, through a cache; writes are ignored)
//   100000 (w)     tile bank select: which = (data >> 8) & 3                              (tilebank1_w)
//   100002 (w)     FG scroll x       100004 (w)  FG scroll y + 8
//   100006 (w)     BG scroll x + 4   100008 (w)  BG scroll y + 8                          (the values the tilemaps' set_scroll get)
//   10000E (w)     tile bank data:   bank[which] = (data >> 8) & 1F                       (tilebank_w)
//   120000-120FFF  FG video RAM (64 x 32 words)       122000-122FFF  BG video RAM (64 x 32 words)
//   200000-2005FF  palette RAM (0x300 words, xRGB555) 210000-2107FF  sprite RAM (256 entries x 4 words)
//   270001 (w)     sound latch (low byte)
//   280000 P1_P2   280002 COIN   280004 DSW           (16 bit, active low)
//   300000-30FFFF  64 KB work RAM
//
// Every access completes with DTACK from here: block-RAM accesses after four clocks, ROM accesses when the cache has the word.
// Unmapped addresses read as 0 and swallow writes (MAME's defaults).
`default_nettype none

module sm_main (
    input  logic        clk,
    input  logic        reset,                        // the CPU (also held by the frozen-state bench)
    input  logic        regs_reset,                   // the machine's reset: the tile banks (silvmil_state::machine_reset)
    input  logic        cen_phi1, cen_phi2,           // the CPU clock as alternating enables

    // program ROM word read (through the cache): level request until ack
    output logic        rom_req,
    output logic [19:1] rom_addr,
    input  logic        rom_ack,                      // one cycle, rom_data valid
    input  logic [15:0] rom_data,

    // inputs, active low, in the board's bit order
    input  logic [15:0] p1p2_in, coin_in, dsw_in,

    input  logic        vblank_irq,                   // pulse: raise the level 6 interrupt (the start of vertical blank)
    input  logic        vsnap,                        // 1: the picture shows the video RAMs and registers as they were at the start of
                                                      //    vertical blank (MAME); 0: as they are while each line is drawn

    // video: tile RAM read ports (registered, one clock after the address)
    input  logic [10:0] fg_addr, bg_addr,
    output logic [15:0] fg_data, bg_data,
    // video: sprite RAM read port ({w3, w2, w1, w0} of an entry)
    input  logic [7:0]  sr_addr,
    output logic [63:0] sr_data,
    // video: palette RAM read port (always live: the palette is looked up as the dots go out)
    input  logic [9:0]  pal_addr,
    output logic [15:0] pal_data,
    // video: registers (snapshot or live, as the RAMs)
    output logic [15:0] fg_sx, fg_sy, bg_sx, bg_sy,
    output logic [4:0]  bank0, bank1, bank2, bank3,

    // sound
    output logic [7:0]  snd_latch,
    output logic        snd_latch_wr,                 // one-cycle pulse

    // bus trace for the simulation
    output logic        trc_stb,
    output logic [23:1] trc_addr,
    output logic        trc_rw,
    output logic [15:0] trc_data,
    output logic [1:0]  trc_be,
    output logic        cpu_halted
);

    // ------------------------------------------------------------------ CPU
    logic [23:1] eab;
    logic [15:0] oEdb, iEdb;
    logic        eRWn, ASn, LDSn, UDSn, VMAn, E;
    logic        FC0, FC1, FC2, BGn, oRESETn, oHALTEDn;
    logic        DTACKn;

    wire iack = FC2 & FC1 & FC0 & ~ASn;

    // level 6 interrupt, held until acknowledged (MAME: irq6_line_hold)
    logic irq6;
    logic iack_d;
    always_ff @(posedge clk) begin
        iack_d <= iack;
        if (reset)                   irq6 <= 1'b0;
        else if (iack_d & ~iack)     irq6 <= 1'b0;
        else if (vblank_irq)         irq6 <= 1'b1;
    end

    logic pwr_d;
    always_ff @(posedge clk) pwr_d <= reset;

    fx68k u_cpu (
        .clk(clk), .HALTn(1'b1),
        .extReset(reset | pwr_d), .pwrUp(reset),
        .enPhi1(cen_phi1), .enPhi2(cen_phi2),
        .eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
        .E(E), .VMAn(VMAn),
        .FC0(FC0), .FC1(FC1), .FC2(FC2),
        .BGn(BGn),
        .oRESETn(oRESETn), .oHALTEDn(oHALTEDn),
        .DTACKn(DTACKn), .VPAn(~iack),
        .BERRn(1'b1),
        .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(1'b1), .IPL1n(~irq6), .IPL2n(~irq6),     // level 6 = 110
        .iEdb(iEdb), .oEdb(oEdb),
        .eab(eab)
    );
    assign cpu_halted = ~oHALTEDn;

    // ------------------------------------------------------------------ decode
    wire [23:0] ba = {eab, 1'b0};
    wire sel_rom   = ba[23:20] == 4'h0;                // 000000-0FFFFF
    wire sel_reg   = ba[23:4]  == 20'h10000;           // 100000-10000F
    wire sel_fg    = ba[23:12] == 12'h120;             // 120000-120FFF
    wire sel_bg    = ba[23:12] == 12'h122;             // 122000-122FFF
    wire sel_pal   = (ba[23:11] == 13'h0400) && (ba[10:9] != 2'b11);   // 200000-2005FF
    wire sel_spr   = ba[23:11] == 13'h0420;            // 210000-2107FF
    wire sel_latch = eab == 23'h138000;                // 270000 / 270001 (the byte at 270001)
    wire sel_p12   = eab == 23'h140000;                // 280000
    wire sel_coin  = eab == 23'h140001;                // 280002
    wire sel_dsw   = eab == 23'h140002;                // 280004
    wire sel_ram   = ba[23:16] == 8'h30;               // 300000-30FFFF

    // ------------------------------------------------------------------ RAMs
    logic        we;                                   // one-cycle write strobe
    wire  [1:0]  be = {~UDSn, ~LDSn};

    logic [15:0] q_ram, q_fg, q_bg, q_pal;
    logic [15:0] q_s0, q_s1, q_s2, q_s3;

    sm_ram16 #(.AW(15)) u_ram (
        .clka(clk), .addra(eab[15:1]), .da(oEdb), .wea(we && sel_ram ? be : 2'b00), .qa(q_ram),
        .clkb(clk), .addrb(15'd0), .qb());
    // The CPU's tile and sprite RAMs are copied into the renderer's copies of them (`*_d`) by a sweep of 2048 clocks: once at the start
    // of vertical blank when `vsnap` (MAME draws the whole frame at that moment, before the interrupt routine rewrites the RAMs),
    // over and over otherwise (the copy then trails the CPU's writes by at most 21 us).
    logic [11:0] cp_i = 12'd0;
    logic        cp_run = 1'b0;
    logic        cp_we;
    logic [10:0] cp_wa;
    wire  [10:0] cp_ra = cp_i[10:0];
    always_ff @(posedge clk) begin
        cp_we <= cp_run;
        cp_wa <= cp_ra;
        if (vsnap ? vblank_irq : !cp_run) begin cp_i <= 12'd0; cp_run <= 1'b1; end
        else if (cp_run) begin
            cp_i <= cp_i + 12'd1;
            if (cp_i == 12'd2047) cp_run <= 1'b0;
        end
    end
    logic [15:0] c_fg, c_bg, c_s0, c_s1, c_s2, c_s3;

    sm_ram16 #(.AW(11)) u_fg (
        .clka(clk), .addra(eab[11:1]), .da(oEdb), .wea(we && sel_fg ? be : 2'b00), .qa(q_fg),
        .clkb(clk), .addrb(cp_ra), .qb(c_fg));
    sm_ram16 #(.AW(11)) u_bg (
        .clka(clk), .addra(eab[11:1]), .da(oEdb), .wea(we && sel_bg ? be : 2'b00), .qa(q_bg),
        .clkb(clk), .addrb(cp_ra), .qb(c_bg));
    sm_ram16 #(.AW(10)) u_pal (
        .clka(clk), .addra(eab[10:1]), .da(oEdb), .wea(we && sel_pal ? be : 2'b00), .qa(q_pal),
        .clkb(clk), .addrb(pal_addr), .qb(pal_data));
    // sprite RAM: word field in four RAMs, the entry (0..255) as the address: CPU word w = eab[10:1]: entry = w[9:2], field = w[1:0]
    sm_ram16 #(.AW(8)) u_s0 (
        .clka(clk), .addra(eab[10:3]), .da(oEdb), .wea(we && sel_spr && eab[2:1] == 2'd0 ? be : 2'b00), .qa(q_s0),
        .clkb(clk), .addrb(cp_ra[7:0]), .qb(c_s0));
    sm_ram16 #(.AW(8)) u_s1 (
        .clka(clk), .addra(eab[10:3]), .da(oEdb), .wea(we && sel_spr && eab[2:1] == 2'd1 ? be : 2'b00), .qa(q_s1),
        .clkb(clk), .addrb(cp_ra[7:0]), .qb(c_s1));
    sm_ram16 #(.AW(8)) u_s2 (
        .clka(clk), .addra(eab[10:3]), .da(oEdb), .wea(we && sel_spr && eab[2:1] == 2'd2 ? be : 2'b00), .qa(q_s2),
        .clkb(clk), .addrb(cp_ra[7:0]), .qb(c_s2));
    sm_ram16 #(.AW(8)) u_s3 (
        .clka(clk), .addra(eab[10:3]), .da(oEdb), .wea(we && sel_spr && eab[2:1] == 2'd3 ? be : 2'b00), .qa(q_s3),
        .clkb(clk), .addrb(cp_ra[7:0]), .qb(c_s3));

    // the renderer's copies
    sm_sdp #(.AW(11), .DW(16)) u_fg_d (.clk(clk), .we(cp_we), .waddr(cp_wa), .wdata(c_fg), .raddr(fg_addr), .rdata(fg_data));
    sm_sdp #(.AW(11), .DW(16)) u_bg_d (.clk(clk), .we(cp_we), .waddr(cp_wa), .wdata(c_bg), .raddr(bg_addr), .rdata(bg_data));
    sm_sdp #(.AW(8),  .DW(64)) u_sp_d (.clk(clk), .we(cp_we && cp_wa[10:8] == 3'd0), .waddr(cp_wa[7:0]), .wdata({c_s3, c_s2, c_s1, c_s0}),
                                       .raddr(sr_addr), .rdata(sr_data));

    // ------------------------------------------------------------------ registers
    // The raw scroll registers (100000-10000F as last written) and the sound latch are plain latches: the machine's reset does not
    // clear them (MAME's tilemap scrolls keep their values over a reset and are 0 only until the first write), which also lets the
    // simulation hold the CPU in reset with a frozen state loaded.  `wv` marks a register that has been written: until then its
    // scroll contribution is 0, as the MAME tilemap's.  The tile banks and the bank select are cleared by the machine's reset
    // (silvmil_state::machine_reset), not by the bench's CPU hold.
    logic [15:0] raw [8];
    logic  [7:0] wv;
    logic  [1:0] tb_sel;
    logic  [4:0] tbank [4];
    initial begin
        for (int i = 0; i < 8; i++) raw[i] = 16'd0;
        wv = 8'd0; tb_sel = 2'd0;
        tbank[0] = 5'd0; tbank[1] = 5'd0; tbank[2] = 5'd0; tbank[3] = 5'd0;
        snd_latch = 8'd0;
    end

    // MAME hands a byte write to a 16-bit handler as the byte on both lanes (the 68000 puts it there); the handlers ignore the mask
    wire [15:0] wdat = (be == 2'b11) ? oEdb : be[1] ? {oEdb[15:8], oEdb[15:8]} : {oEdb[7:0], oEdb[7:0]};

    always_ff @(posedge clk) begin
        snd_latch_wr <= 1'b0;
        if (regs_reset) begin
            tb_sel <= 2'd0;
            tbank[0] <= 5'd0; tbank[1] <= 5'd0; tbank[2] <= 5'd0; tbank[3] <= 5'd0;
        end else if (we && sel_reg) begin
            case (eab[3:1])
                3'd0:    tb_sel <= wdat[9:8];                                   // tilebank1_w
                3'd7:    tbank[tb_sel] <= wdat[12:8];                           // tilebank_w
                default: begin raw[eab[3:1]] <= wdat; wv[eab[3:1]] <= 1'b1; end
            endcase
        end
        if (we && sel_latch && be[0]) begin snd_latch <= oEdb[7:0]; snd_latch_wr <= 1'b1; end
    end

    // the scroll values the driver's handlers give the tilemaps (1024 x 512: the low 10 / 9 bits matter)
    logic [15:0] fg_sx_l, fg_sy_l, bg_sx_l, bg_sy_l;            // live
    always_comb begin
        fg_sx_l = wv[1] ? raw[1]         : 16'd0;               // 100002 fg_scrollx_w: data
        fg_sy_l = wv[2] ? raw[2] + 16'd8 : 16'd0;               // 100004 fg_scrolly_w: data + 8
        bg_sx_l = wv[3] ? raw[3] + 16'd4 : 16'd0;               // 100006 bg_scrollx_w: data + 4
        bg_sy_l = wv[4] ? raw[4] + 16'd8 : 16'd0;               // 100008 bg_scrolly_w: data + 8
    end

    // as the picture uses them: latched with the RAMs' snapshot at the start of vertical blank, or live
    logic [15:0] fg_sx_s, fg_sy_s, bg_sx_s, bg_sy_s;
    logic  [4:0] bank_s [4];
    always_ff @(posedge clk) if (vblank_irq) begin
        fg_sx_s <= fg_sx_l; fg_sy_s <= fg_sy_l; bg_sx_s <= bg_sx_l; bg_sy_s <= bg_sy_l;
        bank_s[0] <= tbank[0]; bank_s[1] <= tbank[1]; bank_s[2] <= tbank[2]; bank_s[3] <= tbank[3];
    end
    assign fg_sx = vsnap ? fg_sx_s : fg_sx_l;
    assign fg_sy = vsnap ? fg_sy_s : fg_sy_l;
    assign bg_sx = vsnap ? bg_sx_s : bg_sx_l;
    assign bg_sy = vsnap ? bg_sy_s : bg_sy_l;
    assign {bank3, bank2, bank1, bank0} = vsnap ? {bank_s[3], bank_s[2], bank_s[1], bank_s[0]} : {tbank[3], tbank[2], tbank[1], tbank[0]};

    // ------------------------------------------------------------------ bus cycle
    logic        rdy;                             // DTACK
    logic [2:0]  cnt;
    logic        wr_seen;
    assign DTACKn = ~rdy;

    logic [15:0] rd_mux;
    always_comb begin
        rd_mux = 16'h0000;
        if      (sel_ram)   rd_mux = q_ram;
        else if (sel_fg)    rd_mux = q_fg;
        else if (sel_bg)    rd_mux = q_bg;
        else if (sel_pal)   rd_mux = q_pal;
        else if (sel_spr)   rd_mux = (eab[2:1] == 2'd0) ? q_s0 : (eab[2:1] == 2'd1) ? q_s1 : (eab[2:1] == 2'd2) ? q_s2 : q_s3;
        else if (sel_p12)   rd_mux = p1p2_in;
        else if (sel_coin)  rd_mux = coin_in;
        else if (sel_dsw)   rd_mux = dsw_in;
    end

    assign rom_addr = eab[19:1];

    always_ff @(posedge clk) begin
        we         <= 1'b0;
        trc_stb    <= 1'b0;
        if (reset || ASn) begin
            rdy     <= 1'b0;
            cnt     <= 3'd0;
            wr_seen <= 1'b0;
            rom_req <= 1'b0;
        end else if (!iack && !rdy) begin
            if (!eRWn) begin
                // write: the data strobes (and the data) arrive a clock after AS
                if (!wr_seen) begin
                    if (be != 2'b00) begin
                        wr_seen <= 1'b1;
                        we      <= 1'b1;
                        trc_stb <= 1'b1; trc_addr <= eab; trc_rw <= 1'b0; trc_data <= oEdb; trc_be <= be;
                    end
                end else begin
                    rdy <= 1'b1;
                end
            end else if (sel_rom) begin
                // read from the ROM cache
                rom_req <= 1'b1;
                if (rom_ack) begin
                    iEdb    <= rom_data;
                    rom_req <= 1'b0;
                    rdy     <= 1'b1;
                    trc_stb <= 1'b1; trc_addr <= eab; trc_rw <= 1'b1; trc_data <= rom_data; trc_be <= be;
                end
            end else begin
                cnt <= cnt + 3'd1;
                if (cnt == 3'd3) begin
                    iEdb <= rd_mux;
                    rdy  <= 1'b1;
                    trc_stb <= 1'b1; trc_addr <= eab; trc_rw <= 1'b1; trc_data <= rd_mux; trc_be <= be;
                end
            end
        end
    end
endmodule
`default_nettype wire
