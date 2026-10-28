// sim/scale: video_scale_int with the turned picture's size (Silvmil.sv: hsize = rows, vsize = dots of a row) for every Scale mode.
#include <cstdio>
#include "Vtb_scale.h"
#include "verilated.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_scale* t = new Vtb_scale;
    const char* names[5] = {"Normal", "V-Integer", "Narrower HV-Integer", "HV-Integer+", "HV-Integer"};
    struct { int w, h; } hdmi[] = {{1920, 1080}, {1280, 720}, {1280, 1024}};
    // (picture as the scaler gets it, aspect): turned 15 kHz raster, turned scandoubled raster, the raster itself (Horz)
    struct { int hs, vs, ax, ay; const char* what; } pic[] = {
        {240, 320, 3, 4, "turned 240x320 (Vert)"}, {480, 640, 3, 4, "turned, scandoubled 480x640"}, {320, 240, 4, 3, "as is 320x240 (Horz)"}};
    for (auto& h : hdmi)
        for (auto& p : pic)
            for (int s = 0; s < 5; s++) {
                t->hdmi_w = h.w; t->hdmi_h = h.h; t->scale = s; t->hsize = p.hs; t->vsize = p.vs; t->arx = p.ax; t->ary = p.ay;
                for (int i = 0; i < 4000; i++) { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
                int ax = t->arx_o, ay = t->ary_o;
                if (ax & 0x1000) printf("%4dx%-4d %-28s %-20s -> %4d x %4d px (x %.2f, y %.2f)\n", h.w, h.h, p.what, names[s], ax & 0xfff, ay & 0xfff,
                                        (ax & 0xfff) / (double)p.hs, (ay & 0xfff) / (double)p.vs);
                else printf("%4dx%-4d %-28s %-20s -> aspect %d:%d\n", h.w, h.h, p.what, names[s], ax, ay);
            }
    delete t;
    return 0;
}
