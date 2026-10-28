// The framework's video_scale_int (sys/video_freak.sv) with the sizes Silvmil.sv gives it for the turned picture: what the HDMI
// scaler is told for each Scale mode.  sim/scale/run.sh prints one line per (HDMI size, scale, picture size).
`timescale 1ns / 1ps
module tb_scale (
    input  logic        clk,
    input  logic [11:0] hdmi_w, hdmi_h,
    input  logic [2:0]  scale,
    input  logic [11:0] hsize, vsize,
    input  logic [11:0] arx, ary,
    output logic [12:0] arx_o, ary_o
);
    video_scale_int u (
        .CLK_VIDEO(clk), .HDMI_WIDTH(hdmi_w), .HDMI_HEIGHT(hdmi_h), .SCALE(scale),
        .hsize(hsize), .vsize(vsize), .arx_i(arx), .ary_i(ary), .arx_o(arx_o), .ary_o(ary_o)
    );
endmodule
