// Test-only: texcomp's BC6H encoder, compiled in place of its own file, with
// each mode encoder exported so the tests compare every mode's output and
// error estimate with the port's, not only the mode that wins.
#include "../texcomp/src/texcomp_bc6h.c"

// Runs mode `mode` (0 to 13) of the unsigned (is_signed == 0) or signed
// encoder. Returns 0 if texcomp has no encoder for that mode and format,
// else 1 with the error estimate in *err and, when it is not UINT64_MAX,
// the block in out.
int ref_bc6h_mode(int is_signed, int mode, const float pix[16][3], uint8_t out[16], uint64_t *err) {
    static const uint8_t d234[3][3] = {{5, 4, 4}, {4, 5, 4}, {4, 4, 5}};
    static const uint8_t d678[3][3] = {{6, 5, 5}, {5, 6, 5}, {5, 5, 6}};
    if (!is_signed) {
        switch (mode) {
        case 0: *err = tc_bc6h_mode0_uf16(pix, out); return 1;
        case 1: *err = tc_bc6h_mode1_uf16(pix, out); return 1;
        case 2: case 3: case 4: *err = tc_bc6h_mode234_uf16(pix, d234[mode - 2], mode, out); return 1;
        case 5: *err = tc_bc6h_mode5_uf16(pix, out); return 1;
        case 6: case 7: case 8: *err = tc_bc6h_mode678_uf16(pix, d678[mode - 6], mode, out); return 1;
        case 9: *err = tc_bc6h_mode9_uf16(pix, out); return 1;
        case 10: *err = tc_bc6h_mode10_uf16(pix, out); return 1;
        case 12: *err = tc_bc6h_mode12_uf16(pix, out); return 1;
        case 13: *err = tc_bc6h_mode13_uf16(pix, out); return 1;
        default: return 0;
        }
    }
    switch (mode) {
    case 0: *err = tc_bc6h_mode0_sf16(pix, out); return 1;
    case 1: *err = tc_bc6h_mode1_sf16(pix, out); return 1;
    case 2: case 3: case 4: *err = tc_bc6h_mode234_sf16(pix, d234[mode - 2], mode, out); return 1;
    case 5: *err = tc_bc6h_mode5_sf16(pix, out); return 1;
    case 6: case 7: case 8: *err = tc_bc6h_mode678_sf16(pix, d678[mode - 6], mode, out); return 1;
    case 9: *err = tc_bc6h_mode9_sf16(pix, out); return 1;
    case 12: *err = tc_bc6h_mode12_sf16(pix, out); return 1;
    case 13: *err = tc_bc6h_mode13_sf16(pix, out); return 1;
    default: return 0;
    }
}

// The whole block encoders, without the image walk.
void ref_bc6h_block(int is_signed, const float pix[16][3], uint8_t out[16]) {
    if (is_signed) tc_encode_bc6h_block_sf16(pix, out);
    else tc_encode_bc6h_block_uf16(pix, out);
}
