// Test-only: texcomp.c references these ETC2 helpers from its KTX writers,
// which the differential tests never call; the ETC2 sources are not vendored.
#include <stdlib.h>
#include "texcomp.h"

void tc_etc2_options_init(tc_etc2_options *opt) { (void)opt; abort(); }
size_t tc_etc2_rgb_compressed_size(uint32_t w, uint32_t h) { (void)w; (void)h; abort(); }
size_t tc_etc2_rgba_compressed_size(uint32_t w, uint32_t h) { (void)w; (void)h; abort(); }
