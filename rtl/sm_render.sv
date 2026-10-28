// Line renderer: MAME's silvmil_state::screen_update for one line (the one after the line being shown).
//
//   1. BG tilemap: 64 x 32 tiles of 16 x 16 (1024 x 512), opaque; 21 tiles cover the line.  Per tile: the word from the BG video RAM
//      ({colour[15:12], bank select[11:10], code[9:0]}, at scan_rows' {col[5], row[4:0], col[4:0]}), the tile = bank[sel] * 0x400 + code
//      (taken modulo the ROM's tiles), the row's 4 words from the tile ROM in SDRAM, 16 pen writes.
//   2. FG tilemap, the same, pen 0 transparent.   Pen = (colour + 0x20) * 16 + pixel for BG, (colour + 0x10) * 16 + pixel for FG.
//   3. sprites: decospr (standard list format, bootleg mode, offsets 5 / 7, flip screen off), 256 entries of 4 words, drawn in entry order,
//      the last one on top, pen 0 transparent, pen = colour * 16 + pixel.  The entry scan runs one entry a clock and stops at a hit.
//      bootleg_type 1 (PuzzLove, `spr_type`): the flash bit is w0 bit 10 and the height is bitswap<2>(w0, 9, 12); otherwise bit 12 and (10, 9).
//
// Sprite placement (decospr.cpp draw_sprites_common, the 320-wide branch):
//   y' = ((w0 & 1FF) + 7) & 1FF, signed 9 bit;  yb = 240 - y';   a sprite of M + 1 tiles covers the lines yb - 16 * M ... yb + 15;
//   x' = ((w2 & 1FF) + 5) & 1FF, signed with the threshold 320 (x' >= 320 -> x' - 512);  xl = 304 - x'  (left edge of the 16-pixel column)
//   row of the sprite on this line  d = line - (yb - 16 * M),  tile row t = d / 16 (0 = top),  pixel row d % 16 (15 - that when flip Y)
//   tile = w1 + (flip Y ? M - t : t)   (bootleg: no masking of w1 with ~M);  wide (w0 bit 11): a second tile of the row at xl - 16 with tile - (M + 1)
//
// Flip Screen (the OSD's; the board has none): the whole picture turned 180 degrees.  Line n of the raster is drawn from line 239 - n of
// the board's picture, and dot x of it goes to x 319 - x of the line buffer: the same pixels as MAME's picture, turned.
//
// The ROM layout (the loader's remap, sm_mem.sv / tools/silvmil_image.py): a 16-pixel row of a tile is 4 words at {tile, row[3:0], col half, plane half}:
//   word 0 / 1: pixels 0..7, plane half 0 / 1; word 2 / 3: pixels 8..15.  Each word = {byte +8, byte +0} of the gfx layout's 16-bit rows; the pixel x of a
//   byte is bit 7 - x.   tiles:   pen = {w0[hi], w0[lo], w1[hi], w1[lo]}    sprites:  pen = {w1[hi], w1[lo], w0[hi], w0[lo]}   (MAME's tlayout_alt / tlayout)
//
// Line buffer entries are palette indexes.  (Structure after omg_render.sv.)
`default_nettype none
module sm_render #(
    parameter [24:1] TILE_BASE = 24'h080000,      // SDRAM word address of the (remapped) tile ROM (32768 tiles: 4 MB)
    parameter [24:1] SPR_BASE  = 24'h280000       // ... and of the sprite ROM (16384 tiles: 2 MB)
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        start,                    // draw `line` into half `bank` of the line buffer
    input  logic [7:0]  line,
    input  logic        bank,
    output logic        busy,
    output logic        overrun,                  // pulse: a line started while the last one was still being drawn

    input  logic [15:0] fg_sx, fg_sy, bg_sx, bg_sy,
    input  logic [4:0]  bank0, bank1, bank2, bank3,
    input  logic        tmask_big,                // tile ROM: 32768 tiles (else 8192)
    input  logic        spr_type,                 // decospr bootleg_type 1 (PuzzLove)
    input  logic        flip,                     // Flip Screen
    input  logic        flash_hide,               // flashing sprites are hidden in this frame

    // tile RAMs (registered, one clock after the address)
    output logic [10:0] fg_addr, bg_addr,
    input  logic [15:0] fg_data, bg_data,
    // sprite RAM: {w3, w2, w1, w0} of the entry, one clock after the address
    output logic [7:0]  sr_addr,
    input  logic [63:0] sr_data,

    // SDRAM burst clients (level request, a word per wr with its index, a pulse at the end): 4 words each
    output logic        t_req,
    output logic [24:1] t_addr,
    input  logic        t_wr,
    input  logic [1:0]  t_idx,
    input  logic [15:0] t_data,
    input  logic        t_done,
    output logic        s_req,
    output logic [24:1] s_addr,
    input  logic        s_wr,
    input  logic [1:0]  s_idx,
    input  logic [15:0] s_data,
    input  logic        s_done,

    // line buffer write port
    output logic        lb_we,
    output logic [9:0]  lb_addr,                  // {bank, x[8:0]}
    output logic [9:0]  lb_data
);
    typedef enum logic [3:0] {
        S_IDLE, T_ADDR, T_WAIT, T_CAP, T_FETCH, T_PIX,
        S_SCAN, S_FETCH, S_DRAW
    } st_t;
    st_t st = S_IDLE;

    // latched at the start of the line
    logic [7:0]  y;                               // the board's line being drawn (239 - the raster's with Flip Screen)
    logic        bk;
    logic        fl;                              // Flip Screen, for the whole line
    logic        layer;                           // 0 BG, 1 FG
    logic [9:0]  sx;                              // the layer's scroll
    logic [8:0]  sy;
    logic [8:0]  my;                              // tile row source line: y + scroll y
    logic        fl_hide;

    // tile pass
    logic [4:0]  ti;                              // tile 0..20
    logic [3:0]  t_col;                           // colour of the tile
    logic [15:0] tw [4];
    logic [3:0]  pp;                              // pixel 0..15
    wire  [5:0]  tcol = sx[9:4] + {1'b0, ti};
    wire  [10:0] t_ram = {tcol[5], my[8:4], tcol[4:0]};                                // scan_rows (32 rows)
    wire  [10:0] tl_x = {2'b00, ti, 4'b0000} - {7'd0, sx[3:0]} + {7'd0, pp};      // signed 11 bit: screen x of the pixel

    // sprite pass
    logic [7:0]  ia;                              // next entry to ask for
    logic        scan_run;
    logic [7:0]  i_sa, i_sd, i_sq;
    logic        v_sa, v_sd, v_sq;
    logic [47:0] wq;                              // the entry's words, registered (the hit test starts from a register)
    logic [7:0]  resume;
    logic        last_hit;
    logic [15:0] sp_code;                         // the tile of the row being drawn (before the ROM mask)
    logic [4:0]  sp_col;
    logic        sp_fx, sp_wide, sp_second;
    logic [3:0]  sp_row;                          // pixel row in the tile (flip Y applied)
    logic [2:0]  sp_ntm1;                         // M
    logic [15:0] sp_w1;
    logic [10:0] sp_xl;                           // xl, signed 11 bit
    logic [15:0] sw [4];
    logic [3:0]  sp;                              // pixel 0..15

    wire [15:0] w0 = wq[15:0], w1 = wq[31:16], w2 = wq[47:32];

    // ---- the hit test (decospr placement)
    wire  [8:0]  yq   = w0[8:0] + 9'd7;                                            // (y & 1ff) + y_offset, mod 512
    wire signed [10:0] ys   = {{2{yq[8]}}, yq};                                    // signed 9 bit
    wire signed [10:0] yb   = 11'sd240 - ys;                                       // bottom tile's top line
    wire         w_flash = spr_type ? w0[10] : w0[12];
    wire  [1:0]  w_tall  = spr_type ? {w0[9], w0[12]} : {w0[10], w0[9]};
    logic [2:0]  mtall;                                                             // M: 0 / 1 / 3 / 7 (1, 2, 4, 8 tiles tall)
    always_comb case (w_tall)
        2'd0: mtall = 3'd0;
        2'd1: mtall = 3'd1;
        2'd2: mtall = 3'd3;
        default: mtall = 3'd7;
    endcase
    wire signed [10:0] top  = yb - {4'd0, mtall, 4'd0};                            // yb - 16 * M
    wire signed [10:0] dd   = {3'b000, y} - top;                                   // line - top
    wire         hit_y = (dd >= 11'sd0) && (dd < ({4'd0, mtall, 4'd0} + 11'sd16));
    wire  [8:0]  xq   = w2[8:0] + 9'd5;
    wire signed [10:0] xs   = (xq >= 9'd320) ? ({2'b00, xq} - 11'sd512) : {2'b00, xq};   // x' (>= 320 wraps to negative)
    wire signed [10:0] xl   = 11'sd304 - xs;
    wire         hit_x = (xl < 11'sd320) || (w0[11] && (xl < 11'sd336));
    wire         hit   = v_sq && hit_y && hit_x && !(w_flash && fl_hide);

    // ---- pixel pick from the fetched row words
    function automatic [3:0] pick(input [15:0] a0, input [15:0] a1, input [15:0] b0, input [15:0] b1, input [3:0] x, input is_spr);
        // x = pixel 0..15 of the row; words 0/1 hold pixels 0..7, 2/3 pixels 8..15
        logic [15:0] p, q;
        logic [2:0]  b;
        begin
            p = x[3] ? b0 : a0;
            q = x[3] ? b1 : a1;
            b = 3'd7 - x[2:0];
            pick = is_spr ? {q[8 + b], q[b], p[8 + b], p[b]}
                          : {p[8 + b], p[b], q[8 + b], q[b]};
        end
    endfunction
    wire [3:0] t_pen  = pick(tw[0], tw[1], tw[2], tw[3], pp, 1'b0);
    wire [3:0] sp_c   = sp_fx ? (4'd15 - sp) : sp;                                   // source pixel column
    wire [3:0] s_pen  = pick(sw[0], sw[1], sw[2], sw[3], sp_c, 1'b1);
    wire signed [10:0] sp_x = sp_xl + {7'd0, sp};
    // the line buffer's x of a picture dot (0..319): turned with Flip Screen
    function automatic [8:0] lbx(input [8:0] x, input f);
        lbx = f ? (9'd319 - x) : x;
    endfunction

    assign busy = (st != S_IDLE);

    // the last row fetched of each kind, kept for the next tile / sprite of the same row (the ROMs do not change while the machine runs;
    // rst invalidates them, and a ROM load holds the machine in reset)
    logic        tc_valid, sc_valid;
    logic [18:0] tc_key;                          // {tile[14:0], row[3:0]}
    logic [17:0] sc_key;                          // {tile[13:0], row[3:0]}
    wire  t_empty = ~|{tw[0], tw[1], tw[2], tw[3]};
    wire  s_empty = ~|{sw[0], sw[1], sw[2], sw[3]};

    // the sprite code the ROM sees: the row's tile, or the second tile of a wide sprite (tile - (M + 1))
    // (the sprite ROM holds 16384 tiles in all three sets: the code is taken modulo that, as MAME's gfx element does)
    wire [15:0] sp_code_use = sp_second ? (sp_code - {12'd0, 1'b0, sp_ntm1} - 16'd1) : sp_code;
    wire [13:0] sp_code_m   = sp_code_use[13:0];

    always_ff @(posedge clk) begin
        lb_we   <= 1'b0;
        overrun <= 1'b0;
        if (t_wr) tw[t_idx] <= t_data;
        if (s_wr) sw[s_idx] <= s_data;

        if (rst) begin
            st <= S_IDLE; t_req <= 1'b0; s_req <= 1'b0; scan_run <= 1'b0; tc_valid <= 1'b0; sc_valid <= 1'b0;
        end else begin
            if (start && st != S_IDLE) overrun <= 1'b1;
            case (st)
                S_IDLE: if (start) begin
                    y       <= flip ? (8'd239 - line) : line;
                    bk      <= bank;
                    fl      <= flip;
                    layer   <= 1'b0;
                    sx      <= bg_sx[9:0];
                    sy      <= bg_sy[8:0];
                    fl_hide <= flash_hide;
                    ti      <= 5'd0;
                    st      <= T_ADDR;
                end

                // ---------------------------------------------------- tiles
                T_ADDR: begin
                    my <= {1'b0, y} + sy;
                    st <= T_WAIT;
                end
                T_WAIT: begin
                    if (layer) fg_addr <= t_ram;
                    else       bg_addr <= t_ram;
                    st <= T_CAP;
                end
                T_CAP: begin                                    // the RAM's word arrives one clock after the address (T_FETCH's first clock)
                    st <= T_FETCH;
                    t_req <= 1'b0;
                end
                T_FETCH: begin
                    // (entered from T_CAP: the data is valid now; the request goes out in the clock after)
                    if (!t_req && !t_done) begin
                        logic [15:0] v;
                        logic [4:0]  bkv;
                        logic [14:0] code;
                        logic [18:0] key;
                        v = layer ? fg_data : bg_data;
                        case (v[11:10])
                            2'd0: bkv = bank0;
                            2'd1: bkv = bank1;
                            2'd2: bkv = bank2;
                            default: bkv = bank3;
                        endcase
                        code  = {bkv, v[9:0]};                  // code + bank * 0x400
                        key   = {tmask_big ? code : {2'b00, code[12:0]}, my[3:0]};
                        t_col <= v[15:12];
                        if (tc_valid && tc_key == key) begin    // the same row as the last fetch: its words are still in tw
                            pp <= 4'd0;
                            st <= T_PIX;
                        end else begin
                            t_addr   <= TILE_BASE + {key, 2'b00};
                            t_req    <= 1'b1;
                            tc_key   <= key;
                            tc_valid <= 1'b0;
                        end
                    end else if (t_done) begin
                        t_req    <= 1'b0;
                        tc_valid <= 1'b1;
                        pp       <= 4'd0;
                        st       <= T_PIX;
                    end
                end
                T_PIX: begin
                    if (tl_x[10] == 1'b0 && tl_x < 11'd320 && (!layer || t_pen != 4'd0)) begin
                        lb_we   <= 1'b1;
                        lb_addr <= {bk, lbx(tl_x[8:0], fl)};
                        lb_data <= {layer ? 2'b01 : 2'b10, t_col, t_pen};
                    end
                    pp <= pp + 4'd1;
                    if (pp == 4'd15 || (layer && t_empty)) begin          // an FG row of pen 0 only draws nothing
                        if (ti == 5'd20) begin
                            if (!layer) begin
                                layer <= 1'b1;
                                sx    <= fg_sx[9:0];
                                sy    <= fg_sy[8:0];
                                ti    <= 5'd0;
                                st    <= T_ADDR;
                            end else begin
                                ia <= 8'd0; scan_run <= 1'b1; v_sa <= 1'b0; v_sd <= 1'b0; v_sq <= 1'b0;
                                st <= S_SCAN;
                            end
                        end else begin
                            ti <= ti + 5'd1;
                            st <= T_ADDR;
                        end
                    end
                end

                // ---------------------------------------------------- sprites
                S_SCAN: begin
                    // pipeline: ia -> sr_addr -> (RAM) -> sr_data -> wq, evaluated from the register
                    sr_addr <= ia;
                    i_sa    <= ia;
                    v_sa    <= scan_run;
                    i_sd    <= i_sa;
                    v_sd    <= v_sa;
                    wq      <= sr_data[47:0];
                    i_sq    <= i_sd;
                    v_sq    <= v_sd;
                    if (scan_run) begin
                        ia <= ia + 8'd1;
                        if (ia == 8'd255) scan_run <= 1'b0;
                    end
                    if (hit) begin
                        sp_w1     <= w1;
                        sp_col    <= w2[13:9];
                        sp_fx     <= w0[13];
                        sp_wide   <= w0[11];
                        sp_ntm1   <= mtall;
                        sp_xl     <= xl;
                        sp_second <= 1'b0;
                        sp_row    <= w0[14] ? (4'd15 - dd[3:0]) : dd[3:0];
                        // tile row t = dd / 16; the tile is w1 + (flip Y ? M - t : t)
                        sp_code   <= w1 + {13'd0, w0[14] ? (mtall - dd[6:4]) : dd[6:4]};
                        resume    <= i_sq + 8'd1;
                        last_hit  <= (i_sq == 8'd255);
                        scan_run  <= 1'b0;
                        v_sa      <= 1'b0;
                        v_sd      <= 1'b0;
                        v_sq      <= 1'b0;
                        st        <= S_FETCH;
                    end else if (!scan_run && !v_sa && !v_sd && !v_sq) begin
                        st <= S_IDLE;                           // all entries seen
                    end
                end
                S_FETCH: begin
                    if (!s_req && !s_done) begin
                        if (sc_valid && sc_key == {sp_code_m, sp_row}) begin     // the same row as the last fetch: still in sw
                            sp <= 4'd0;
                            st <= S_DRAW;
                        end else begin
                            s_addr   <= SPR_BASE + {sp_code_m, sp_row, 2'b00};
                            s_req    <= 1'b1;
                            sc_key   <= {sp_code_m, sp_row};
                            sc_valid <= 1'b0;
                        end
                    end else if (s_done) begin
                        s_req    <= 1'b0;
                        sc_valid <= 1'b1;
                        sp       <= 4'd0;
                        st       <= S_DRAW;
                    end
                end
                S_DRAW: begin
                    if (s_pen != 4'd0 && sp_x[10] == 1'b0 && sp_x < 11'd320) begin
                        lb_we   <= 1'b1;
                        lb_addr <= {bk, lbx(sp_x[8:0], fl)};
                        lb_data <= {1'b0, sp_col, s_pen};
                    end
                    sp <= sp + 4'd1;
                    if (sp == 4'd15 || s_empty) begin                    // a row of pen 0 only draws nothing
                        if (sp_wide && !sp_second) begin
                            sp_second <= 1'b1;
                            sp_xl     <= sp_xl - 11'd16;
                            st        <= S_FETCH;
                        end else if (last_hit) st <= S_IDLE;
                        else begin
                            ia <= resume; scan_run <= 1'b1; v_sa <= 1'b0; v_sd <= 1'b0; v_sq <= 1'b0;
                            st <= S_SCAN;
                        end
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    wire unused = ^{sp_w1, sr_data[63:48], wq[47:46]};
endmodule
`default_nettype wire
