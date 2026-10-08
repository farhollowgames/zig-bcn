//! Differential tests: the Zig ports against the original C and C++ built
//! from reference/, block by block on the fixed image set, at every quality
//! setting. Any differing byte fails the test.

comptime {
    _ = @import("stb_dxt_test.zig");
    _ = @import("bc7_test.zig");
}
