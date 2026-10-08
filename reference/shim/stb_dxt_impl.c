// Test-only: instantiates stb_dxt as the oracle for the Zig port.
// stb_dxt.h calls memcpy without including <string.h>.
#include <string.h>
#define STB_DXT_IMPLEMENTATION
#include "../stb/stb_dxt.h"
