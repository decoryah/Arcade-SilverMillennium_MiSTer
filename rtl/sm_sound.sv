// The sound board (MAME silvmil_state::sound_map): a Z80 (4.096 MHz; PuzzLove 4 MHz), its program in block RAM (written by the loader;
// the Z80 sees 0000-BFFF of it), 2 KB of RAM, a YM2151 (jt51, Jose Tejada; 3.579545 MHz, PuzzLove Korea 3.75 MHz) whose IRQ drives the
// Z80's INT, an OKI M6295 (jt6295, Jose Tejada; 1.024 MHz, PuzzLove 1 MHz, pin 7 high: sample rate clock / 132) reading its 256 KB of
// samples from SDRAM, and the sound latch the 68000 writes.  Everything is memory mapped; the latch raises no interrupt (the program
// polls it) and the NMI is not connected (the driver's TODO: "what is the audiocpu NMI for?").
//
//   0000-BFFF ROM    C000-C001 YM2151 (r/w)    C002-C003 OKI M6295 (r/w)    C006 sound latch (r)    C00F (w) ignored    D000-D7FF RAM
//   (MAME's unmapped reads are 0; the YM2151's even address reads 0xFF, its odd one the status, as ymfm's ym2151::read)
`default_nettype none
module sm_sound (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_z80,              // the Z80's clock
    input  logic        cen_ym, cen_ym_p1,    // the YM2151's clock, and every second pulse of it (jt51's cen_p1)
    input  logic        cen_oki,              // the OKI's clock

    input  logic [7:0]  latch,                // the 68000's sound latch

    // Z80 program load (from the loader)
    input  logic        zr_we,
    input  logic [15:0] zr_addr,
    input  logic [7:0]  zr_data,

    // OKI sample byte read: level request until ack (sm_mem.sv)
    output logic        pcm_req,
    output logic [17:0] pcm_addr,
    input  logic        pcm_ack,
    input  logic [7:0]  pcm_q,

    output logic signed [15:0] fm_l, fm_r,    // jt51's outputs
    output logic signed [13:0] pcm,           // jt6295's sum of the voices
    output logic [15:0] dbg_pc,
    output logic        dbg_irq
);
    // ------------------------------------------------------------------ Z80
    logic        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
    logic [15:0] A;
    logic [7:0]  cpu_di, cpu_do;
    logic        int_n;

    tv80s_cen u_cpu (
        .reset_n(~rst), .clk(clk), .cen(cen_z80), .wait_n(1'b1),
        .int_n(int_n), .nmi_n(1'b1), .busrq_n(1'b1),
        .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
        .rfsh_n(rfsh_n), .halt_n(), .busak_n(), .A(A), .di(cpu_di), .dout(cpu_do)
    );
    assign dbg_pc = A;

    // ------------------------------------------------------------------ memories
    // the bus signals come from registers that change only on cen_z80 (every 23-24 machine clocks), so the block RAMs' registered reads
    // of the live address are valid long before the CPU samples them
    wire sel_rom = A[15:14] != 2'b11;                         // 0000-BFFF
    wire sel_io  = A[15:4]  == 12'hC00;                       // C000-C00F: the chips and the latch
    wire sel_ram = A[15:11] == 5'b11010;                      // D000-D7FF
    wire mem_cyc = !mreq_n && rfsh_n;
    wire mem_wr  = mem_cyc && !wr_n;

    logic [7:0] rom_q, ram_q;
    sm_sdp #(.AW(16), .DW(8)) u_rom (.clk(clk), .we(zr_we), .waddr(zr_addr), .wdata(zr_data), .raddr(A), .rdata(rom_q));
    sm_ram8 #(.AW(11)) u_ram (.clk(clk), .we(mem_wr && sel_ram), .addr(A[10:0]), .d(cpu_do), .q(ram_q));

    // ------------------------------------------------------------------ the chips' writes
    logic mem_wr_d;
    always_ff @(posedge clk) mem_wr_d <= mem_wr;
    wire  wr_p = mem_wr && !mem_wr_d;                         // one pulse per memory write cycle

    logic       oki_wr;
    logic [7:0] wdat;
    // YM2151: jt51 takes a write only together with cen_p1 (its busy flag starts there), so a write is held until the next one
    // (at most 0.56 us; as the owner's Metro core and Arcade-HyperDuel do)
    logic       ym_pend;
    logic       ym_a0;
    logic [7:0] ym_d;
    always_ff @(posedge clk) begin
        oki_wr <= 1'b0;
        if (cen_ym_p1) ym_pend <= 1'b0;
        if (rst) ym_pend <= 1'b0;
        else if (wr_p && sel_io) begin
            wdat <= cpu_do;
            if (A[3:1] == 3'd0) begin ym_pend <= 1'b1; ym_a0 <= A[0]; ym_d <= cpu_do; end   // C000 / C001
            if (A[3:1] == 3'd1) oki_wr <= 1'b1;                                             // C002 / C003
        end
    end

    // YM2151
    logic [7:0] ym_dout;
    logic       ym_irq_n;
    jt51 u_ym (
        .rst(rst), .clk(clk), .cen(cen_ym), .cen_p1(cen_ym_p1),
        .cs_n(!(ym_pend && cen_ym_p1)), .wr_n(1'b0), .a0(ym_a0), .din(ym_d), .dout(ym_dout),
        .ct1(), .ct2(), .irq_n(ym_irq_n),
        .sample(), .left(), .right(), .xleft(fm_l), .xright(fm_r)
    );
    assign int_n   = ym_irq_n;
    assign dbg_irq = ~ym_irq_n;

    // OKI M6295
    logic [7:0]  oki_dout;
    logic [17:0] oki_a;
    logic [7:0]  oki_rd;
    logic        oki_ok;
    jt6295 #(.INTERPOL(0)) u_oki (
        .rst(rst), .clk(clk), .cen(cen_oki), .ss(1'b1),
        .wrn(~oki_wr), .din(wdat), .dout(oki_dout),
        .rom_addr(oki_a), .rom_data(oki_rd), .rom_ok(oki_ok),
        .sound(pcm), .sample()
    );
    // the sample byte is read from the SDRAM whenever the chip's address changes and held (as omg_sound.sv)
    logic [17:0] srv_a;
    logic        have;
    always_ff @(posedge clk) begin
        if (rst) begin
            have <= 1'b0; pcm_req <= 1'b0; oki_rd <= 8'h00; srv_a <= 18'd0;
        end else begin
            if (pcm_ack) begin
                oki_rd <= pcm_q; srv_a <= pcm_addr; have <= 1'b1; pcm_req <= 1'b0;
            end else if (!pcm_req && !(have && srv_a == oki_a)) begin
                pcm_addr <= oki_a; pcm_req <= 1'b1;
            end
        end
    end
    assign oki_ok = have && (srv_a == oki_a);

    // ------------------------------------------------------------------ the CPU's data input
    always_comb begin
        cpu_di = 8'h00;
        if (!m1_n && !iorq_n)       cpu_di = 8'hFF;               // interrupt acknowledge: the bus floats high (IM 1)
        else if (!mreq_n) begin
            if (sel_rom)            cpu_di = rom_q;
            else if (sel_ram)       cpu_di = ram_q;
            else if (sel_io) case (A[3:0])
                4'h0:               cpu_di = 8'hFF;               // YM2151 data port: ymfm reads 0xFF
                4'h1:               cpu_di = ym_dout;             // YM2151 status
                4'h2, 4'h3:         cpu_di = oki_dout;
                4'h6:               cpu_di = latch;
                default:            cpu_di = 8'h00;
            endcase
        end
    end

    wire unused = ^{rd_n};
endmodule
`default_nettype wire
