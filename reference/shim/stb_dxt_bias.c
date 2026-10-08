// Test-only: stb_dxt again with STB_DXT_USE_ROUNDING_BIAS, under other names,
// as the oracle for the port's biased rounding option.
#include <string.h>
#define stb_compress_dxt_block stb_compress_dxt_block_bias
#define stb_compress_bc4_block stb_compress_bc4_block_bias
#define stb_compress_bc5_block stb_compress_bc5_block_bias
#define STB_DXT_USE_ROUNDING_BIAS
#define STB_DXT_IMPLEMENTATION
#include "../stb/stb_dxt.h"
