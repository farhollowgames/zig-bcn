const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("bcn", .{
        .root_source_file = b.path("src/bcn.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests default to ReleaseSafe: the slow encoder settings take minutes in
    // Debug, and ReleaseSafe keeps every assert and overflow check on.
    const test_optimize = b.option(std.lang.Optimize, "test-optimize", "Optimize mode for the tests (default ReleaseSafe)") orelse .safe;
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &.{};

    const bcn_test_mod = b.createModule(.{
        .root_source_file = b.path("src/bcn.zig"),
        .target = target,
        .optimize = test_optimize,
    });

    const test_step = b.step("test", "Run unit and differential tests");

    const unit_tests = b.addTest(.{ .root_module = bcn_test_mod, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // The original C and C++ encoders, built only for the differential tests.
    // Fused multiply-adds are off so the float paths round as written, as
    // Zig's do.
    const reference = b.addLibrary(.{
        .name = "bcn_reference",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .fast,
            .link_libc = true,
            // Only for the C++ standard headers bc7e includes; the library
            // itself never links libc++.
            .link_libcpp = true,
        }),
    });
    const c_flags: []const []const u8 = &.{ "-std=c11", "-ffp-contract=off", "-fno-fast-math" };
    const cpp_flags: []const []const u8 = &.{ "-std=c++17", "-ffp-contract=off", "-fno-fast-math", "-fno-exceptions", "-fno-rtti", "-fno-threadsafe-statics" };
    reference.root_module.addIncludePath(b.path("reference/texcomp/include"));
    reference.root_module.addIncludePath(b.path("reference/texcomp/src"));
    reference.root_module.addCSourceFiles(.{
        .root = b.path("reference"),
        .files = &.{
            "shim/stb_dxt_impl.c",
        },
        .flags = c_flags,
    });
    // texcomp's BC6H error sums overflow int32 (undefined behaviour); with
    // -fwrapv they wrap, which every compiler and the port agree on, while
    // optimizers that exploit the overflow change the chosen blocks.
    reference.root_module.addCSourceFiles(.{
        .root = b.path("reference"),
        .files = &.{
            "shim/texcomp_stubs.c",
            "texcomp/src/texcomp.c",
            "texcomp/src/texcomp_bc1.c",
            "texcomp/src/texcomp_bc3.c",
            "texcomp/src/texcomp_bc5.c",
            "texcomp/src/texcomp_bc6h.c",
            "texcomp/src/texcomp_bc6h_decode.c",
            "texcomp/src/texcomp_bc7.c",
        },
        .flags = c_flags ++ &[_][]const u8{"-fwrapv"},
    });
    reference.root_module.addCSourceFiles(.{
        .root = b.path("reference"),
        .files = &.{
            "shim/bc7e_shim.cpp",
            "bc7e/basisu_bc7e_scalar.cpp",
        },
        .flags = cpp_flags,
    });

    const differential = b.addTest(.{
        .name = "differential",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/differential.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "bcn", .module = bcn_test_mod }},
        }),
        .filters = test_filters,
    });
    differential.root_module.linkLibrary(reference);
    test_step.dependOn(&b.addRunArtifact(differential).step);
}
