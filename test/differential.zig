//! Differential tests: the Zig ports against the original C and C++ built
//! from reference/, block by block on the fixed image set, at every quality
//! setting. Any differing byte fails the test.

const build_options = @import("build_options");

comptime {
    _ = @import("stb_dxt_test.zig");
    _ = @import("bc6h_test.zig");
    // Under `zig build coverage` the reference is instrumented; referencing
    // this symbol keeps the profile runtime's exit hook, which writes the
    // counts.
    if (build_options.coverage) _ = &llvm_profile.__llvm_profile_runtime;
}

const llvm_profile = struct {
    extern var __llvm_profile_runtime: c_int;
};
