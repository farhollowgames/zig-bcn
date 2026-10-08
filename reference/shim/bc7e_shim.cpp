// Test-only: a C ABI over the bc7e scalar encoder, the oracle for the Zig port.
#include <string.h>
#include "../bc7e/basisu_bc7e_scalar.h"

using bc7e_scalar::bc7e_compress_block_params;

extern "C" {

void ref_bc7e_init(void) { bc7e_scalar::bc7e_compress_block_init(); }

unsigned ref_bc7e_params_size(void) { return (unsigned)sizeof(bc7e_compress_block_params); }

// Levels run from fastest (0) to slowest (6), the same order as the Zig port.
void ref_bc7e_params_init(unsigned level, int perceptual, void *out) {
    bc7e_compress_block_params p;
    memset(&p, 0, sizeof(p)); // padding is compared byte for byte
    const bool perc = perceptual != 0;
    switch (level) {
    case 0: bc7e_scalar::bc7e_compress_block_params_init_ultrafast(&p, perc); break;
    case 1: bc7e_scalar::bc7e_compress_block_params_init_veryfast(&p, perc); break;
    case 2: bc7e_scalar::bc7e_compress_block_params_init_fast(&p, perc); break;
    case 3: bc7e_scalar::bc7e_compress_block_params_init_basic(&p, perc); break;
    case 4: bc7e_scalar::bc7e_compress_block_params_init_slow(&p, perc); break;
    case 5: bc7e_scalar::bc7e_compress_block_params_init_veryslow(&p, perc); break;
    default: bc7e_scalar::bc7e_compress_block_params_init_slowest(&p, perc); break;
    }
    memcpy(out, &p, sizeof(p));
}

void ref_bc7e_compress_blocks(unsigned num_blocks, uint64_t *blocks, const uint32_t *pixels, const void *params) {
    bc7e_scalar::bc7e_compress_blocks(num_blocks, blocks, pixels, (const bc7e_compress_block_params *)params, nullptr);
}

}
