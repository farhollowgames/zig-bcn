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
    for (reference_include_dirs) |dir| reference.root_module.addIncludePath(b.path(dir));
    reference.root_module.addCSourceFiles(.{ .root = b.path("reference"), .files = &reference_c_files, .flags = &c_flags });
    reference.root_module.addCSourceFiles(.{ .root = b.path("reference"), .files = &reference_cpp_files, .flags = &cpp_flags });

    const differential = differentialTest(b, target, test_optimize, bcn_test_mod, test_filters, false);
    differential.root_module.linkLibrary(reference);
    test_step.dependOn(&b.addRunArtifact(differential).step);

    addCoverage(b, target, test_optimize, bcn_test_mod, test_filters);
}

const reference_include_dirs = [_][]const u8{ "reference/texcomp/include", "reference/texcomp/src" };

const reference_c_files = [_][]const u8{
    "shim/stb_dxt_impl.c",
    "shim/stb_dxt_bias.c",
    "shim/texcomp_stubs.c",
    "texcomp/src/texcomp.c",
    "texcomp/src/texcomp_bc1.c",
    "texcomp/src/texcomp_bc3.c",
    "texcomp/src/texcomp_bc5.c",
    "texcomp/src/texcomp_bc6h.c",
    "texcomp/src/texcomp_bc6h_decode.c",
    "texcomp/src/texcomp_bc7.c",
};

const reference_cpp_files = [_][]const u8{
    "shim/bc7e_shim.cpp",
    "bc7e/basisu_bc7e_scalar.cpp",
};

const c_flags = [_][]const u8{ "-std=c11", "-ffp-contract=off", "-fno-fast-math" };
const cpp_flags = [_][]const u8{ "-std=c++17", "-ffp-contract=off", "-fno-fast-math", "-fno-exceptions", "-fno-rtti", "-fno-threadsafe-statics" };

/// The original sources the coverage report covers: everything the ports
/// translate, and the decoders the Zig decoders are checked against.
const coverage_sources = [_][]const u8{
    "reference/stb/stb_dxt.h",
    "reference/bc7e/basisu_bc7e_scalar.cpp",
    "reference/texcomp/src/texcomp_bc6h.c",
    "reference/texcomp/src/texcomp_bc6h_decode.c",
    "reference/texcomp/src/texcomp_bc7.c",
    "reference/texcomp/src/texcomp_bc1.c",
    "reference/texcomp/src/texcomp_bc3.c",
    "reference/texcomp/src/texcomp_bc5.c",
};

fn differentialTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    test_optimize: std.lang.Optimize,
    bcn_test_mod: *std.Build.Module,
    test_filters: []const []const u8,
    coverage: bool,
) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption(bool, "coverage", coverage);
    return b.addTest(.{
        .name = if (coverage) "differential-coverage" else "differential",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/differential.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "bcn", .module = bcn_test_mod },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
        .filters = test_filters,
    });
}

/// `zig build coverage`: runs the differential tests against the reference
/// built by the system clang with source-based coverage, then reports which
/// lines and branches of the original sources the tests reached, also into
/// zig-out/coverage (report.txt, and per-line counts under show/). The
/// reference is a shared library linked by clang's driver, which brings in
/// the profile runtime matching that clang. Needs clang, clang++,
/// llvm-profdata and llvm-cov of one LLVM version on the PATH.
fn addCoverage(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    test_optimize: std.lang.Optimize,
    bcn_test_mod: *std.Build.Module,
    test_filters: []const []const u8,
) void {
    const coverage_step = b.step("coverage", "Report the differential tests' line and branch coverage of the original sources (needs clang and llvm-cov)");
    const instrument = [_][]const u8{ "-O1", "-fPIC", "-fprofile-instr-generate", "-fcoverage-mapping" };

    const link = b.addSystemCommand(&.{ "clang++", "-shared", "-fprofile-instr-generate", "-o" });
    const shared = link.addOutputFileArg("libbcn_reference_coverage.so");
    inline for (.{ reference_c_files, reference_cpp_files }, .{ "clang", "clang++" }, .{ c_flags, cpp_flags }) |files, compiler, flags| {
        for (files) |file| {
            const cc = b.addSystemCommand(&.{ compiler, "-c" });
            cc.addArgs(&flags);
            cc.addArgs(&instrument);
            // bc7e calls sqrt and floor unqualified on floats, meaning the
            // float overloads, which libc++ (the zig c++ reference) and MSVC
            // declare globally. The system clang++ uses libstdc++, whose
            // <cmath> does not, so sqrt would run in double and round
            // differently; its <math.h> brings the overloads in.
            if (std.mem.eql(u8, compiler, "clang++")) cc.addArgs(&.{ "-include", "math.h" });
            for (reference_include_dirs) |dir| cc.addPrefixedDirectoryArg("-I", b.path(dir));
            cc.addFileArg(b.path(b.pathJoin(&.{ "reference", file })));
            cc.addArg("-o");
            link.addFileArg(cc.addOutputFileArg(b.fmt("{s}.o", .{std.fs.path.basename(file)})));
        }
    }

    const differential = differentialTest(b, target, test_optimize, bcn_test_mod, test_filters, true);
    differential.root_module.addObjectFile(shared);
    differential.root_module.addRPath(shared.dirname());

    const run = b.addSystemCommand(&.{"sh"});
    run.addFileArg(b.path("tools/coverage.sh"));
    run.addArtifactArg(differential);
    run.addFileArg(shared);
    run.addFileArg(b.path("tools/coverage-required.txt"));
    const out = run.addOutputDirectoryArg("coverage");
    for (coverage_sources) |source| run.addFileArg(b.path(source));
    run.has_side_effects = true;
    run.stdio = .inherit;

    const install = b.addInstallDirectory(.{ .source_dir = out, .install_dir = .prefix, .install_subdir = "coverage" });
    coverage_step.dependOn(&install.step);
}
