//! `zig build bench`: every zig-bcn encoder and decoder against its
//! original, one feature per row, on one thread.
//!
//! Both sides work on the same blocks: every block of the test image set
//! (test/images.zig), 2,688 RGBA blocks and 1,536 HDR blocks. The originals
//! come from reference/, built at -O3 for the same CPU as the Zig, which is
//! ReleaseFast. Each sample times enough passes over the blocks to last at
//! least `sample_ns_min`, after warm-up samples, and the two sides' samples
//! alternate so both see the same load. Time is the benchmark thread's CPU
//! time: on an idle machine that is the wall time, and on a shared one it
//! leaves out the time other processes hold the core. Every pass's output
//! is kept behind a compiler barrier, so no pass can be optimized away, and
//! the two sides' outputs are compared: a row whose bytes differ says so.
//!
//!   zig build bench [-- --samples N --rounds N --filter TEXT]
//!
//! `--rounds` runs every row that many times, spread over the whole run,
//! and keeps each side's best median.

const std = @import("std");
const builtin = @import("builtin");
const bcn = @import("bcn");
const images = @import("images");

extern fn stb_compress_dxt_block(dest: [*]u8, src: [*]const u8, alpha: c_int, mode: c_int) void;
extern fn stb_compress_dxt_block_bias(
    dest: [*]u8,
    src: [*]const u8,
    alpha: c_int,
    mode: c_int,
) void;
extern fn stb_compress_bc4_block(dest: [*]u8, src: [*]const u8) void;
extern fn stb_compress_bc5_block(dest: [*]u8, src: [*]const u8) void;
extern fn ref_bc7e_init() void;
extern fn ref_bc7e_compress_blocks(
    num_blocks: c_uint,
    blocks: [*]u64,
    pixels: [*]const u32,
    params: *const anyopaque,
    used_lut: ?[*]u8,
) void;
extern fn ref_bc6h_block(is_signed: c_int, pix: *const [16][3]f32, out: *[16]u8) void;
extern fn tc_backend_force_mask(mask: u32) void;
extern fn tc_backend_name() [*:0]const u8;
extern fn tc_decode_bc4_block(in: [*]const u8, v: *[16]u8) void;
extern fn tc_bc1_decompress_rgba8(
    bc1: [*]const u8,
    width: u32,
    height: u32,
    stride: usize,
    out: [*]u8,
    out_size: usize,
) c_int;
extern fn tc_bc3_decompress_rgba8(
    bc3: [*]const u8,
    width: u32,
    height: u32,
    stride: usize,
    out: [*]u8,
    out_size: usize,
) c_int;
extern fn tc_bc5_decompress_rgba8(
    bc5: [*]const u8,
    width: u32,
    height: u32,
    snorm: c_int,
    stride: usize,
    out: [*]u8,
    out_size: usize,
) c_int;
extern fn tc_bc7_decompress_rgba8(
    bc7: [*]const u8,
    width: u32,
    height: u32,
    stride: usize,
    out: [*]u8,
    out_size: usize,
) c_int;
extern fn tc_bc7_decompress_rgbaf(
    bc7: [*]const u8,
    width: u32,
    height: u32,
    stride_bytes: usize,
    out: [*]f32,
    out_size: usize,
) c_int;
const TcBc5Options = extern struct { snorm: c_int };
extern fn tc_bc5_compress_rg8(
    rg: [*]const u8,
    width: u32,
    height: u32,
    stride: usize,
    opt: *const TcBc5Options,
    out: [*]u8,
    out_size: usize,
) c_int;
extern fn tc_bc6h_decompress_rgb16f(
    bc6h: [*]const u8,
    width: u32,
    height: u32,
    is_signed: c_int,
    stride_bytes: usize,
    out: [*]u16,
    out_size: usize,
) c_int;

/// texcomp's selector kernels: every one it has (AVX2 here), or scalar
/// only, the code zig-bcn translates.
const kernels_all: u32 = 0xffffffff;
const kernels_scalar: u32 = 0;

const sample_ns_min = 25 * std.time.ns_per_ms;
const warm_up_samples = 2;

const images_blocks_wide = bcn.image.blocksWide(images.width);
const blocks_per_image = images_blocks_wide * bcn.image.blocksHigh(images.height);
const ldr_blocks = images.ldr_names.len * blocks_per_image;
const hdr_blocks = images.hdr_names.len * blocks_per_image;

/// The decoders see the blocks as one image this many blocks wide.
const grid_blocks_wide = 48;
comptime {
    std.debug.assert(ldr_blocks % grid_blocks_wide == 0 and hdr_blocks % grid_blocks_wide == 0);
}
const grid_width = grid_blocks_wide * 4;
const ldr_height = ldr_blocks / grid_blocks_wide * 4;
const hdr_height = hdr_blocks / grid_blocks_wide * 4;

const Inputs = struct {
    rgba: []align(64) const [16][4]u8,
    /// The RGBA blocks made opaque, as `bc1.encodeImage` passes them.
    rgb: []align(64) const [16][4]u8,
    red: []const [16]u8,
    red_green: []const [16][2]u8,
    hdr: []const [16][3]f32,
    // Encoded streams, the decoders' inputs.
    bc1: []const u8,
    bc3: []const u8,
    bc4: []const u8,
    bc5: []const u8,
    /// texcomp's SNORM encoding of `red_green`; zig-bcn has no SNORM encoder.
    bc5_snorm: []const u8,
    bc7: []const u8,
    bc6h_unsigned: []const u8,
    bc6h_signed: []const u8,
};

const Side = *const fn (case: *const Case, in: *const Inputs, out: []align(64) u8) void;

const Case = struct {
    name: []const u8,
    blocks: usize,
    out_len: usize,
    zig: Side,
    /// Null where zig-bcn's code has no original.
    original: ?Side,
    stb: bcn.bc1.Settings = .{},
    level: bcn.bc7.Level = .basic,
    perceptual: bool = true,
    format: bcn.bc6h.Format = .unsigned,
    kernels: u32 = kernels_scalar,
    /// Bytes the Zig side never writes start as the original writes them.
    rgba_fill: bool = false,
};

// --- Encoders -------------------------------------------------------------------

fn stbMode(case: *const Case) c_int {
    return switch (case.stb.quality) {
        .normal => 0,
        .high => 2,
    };
}

fn stbDxt(case: *const Case, dest: [*]u8, src: [*]const u8, alpha: c_int) void {
    switch (case.stb.rounding) {
        .spec => stb_compress_dxt_block(dest, src, alpha, stbMode(case)),
        .biased => stb_compress_dxt_block_bias(dest, src, alpha, stbMode(case)),
    }
}

fn bc1Zig(case: *const Case, in: *const Inputs, out: []align(64) u8) void {
    for (in.rgb, 0..) |*px, i| out[i * 8 ..][0..8].* = bcn.bc1.encodeBlock(px, case.stb);
}

fn bc1Stb(case: *const Case, in: *const Inputs, out: []align(64) u8) void {
    for (in.rgb, 0..) |*px, i| stbDxt(case, out[i * 8 ..].ptr, @ptrCast(px), 0);
}

fn bc3Zig(case: *const Case, in: *const Inputs, out: []align(64) u8) void {
    for (in.rgba, 0..) |*px, i| out[i * 16 ..][0..16].* = bcn.bc3.encodeBlock(px, case.stb);
}

fn bc3Stb(case: *const Case, in: *const Inputs, out: []align(64) u8) void {
    for (in.rgba, 0..) |*px, i| stbDxt(case, out[i * 16 ..].ptr, @ptrCast(px), 1);
}

fn bc4Zig(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    for (in.red, 0..) |*v, i| out[i * 8 ..][0..8].* = bcn.bc4.encodeBlock(v);
}

fn bc4Stb(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    for (in.red, 0..) |*v, i| stb_compress_bc4_block(out[i * 8 ..].ptr, v);
}

fn bc5Zig(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    for (in.red_green, 0..) |*px, i| out[i * 16 ..][0..16].* = bcn.bc5.encodeBlock(px);
}

fn bc5Stb(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    for (in.red_green, 0..) |*px, i| stb_compress_bc5_block(out[i * 16 ..].ptr, @ptrCast(px));
}

fn bc7Zig(case: *const Case, in: *const Inputs, out: []align(64) u8) void {
    const params = bcn.bc7.Params.init(case.level, case.perceptual);
    for (in.rgba, 0..) |*px, i| out[i * 16 ..][0..16].* = bcn.bc7.encodeBlock(px, &params);
}

fn bc7Bc7e(case: *const Case, in: *const Inputs, out: []align(64) u8) void {
    const params = bcn.bc7.Params.init(case.level, case.perceptual);
    const blocks: [*]u64 = @ptrCast(out.ptr);
    const pixels: [*]const u32 = @ptrCast(in.rgba.ptr);
    ref_bc7e_compress_blocks(@intCast(in.rgba.len), blocks, pixels, &params, null);
}

fn bc6hZig(case: *const Case, in: *const Inputs, out: []align(64) u8) void {
    for (in.hdr, 0..) |*px, i| out[i * 16 ..][0..16].* = bcn.bc6h.encodeBlock(px, case.format);
}

fn bc6hHighZig(case: *const Case, in: *const Inputs, out: []align(64) u8) void {
    for (in.hdr, 0..) |*px, i| {
        out[i * 16 ..][0..16].* = bcn.bc6h.encodeBlockQuality(px, case.format, .high);
    }
}

fn bc6hTexcomp(case: *const Case, in: *const Inputs, out: []align(64) u8) void {
    tc_backend_force_mask(case.kernels);
    const signed: c_int = @intFromBool(case.format == .signed);
    for (in.hdr, 0..) |*px, i| ref_bc6h_block(signed, px, out[i * 16 ..][0..16]);
}

// --- Decoders -------------------------------------------------------------------

fn ldrImage(out: []align(64) u8) bcn.ImageMut(u8) {
    return bcn.ImageMut(u8).init(out, grid_width, ldr_height, 4);
}

fn bc1DecodeZig(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    bcn.bc1.decodeImage(in.bc1, ldrImage(out));
}

fn bc1DecodeTexcomp(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    const stride = grid_width * 4;
    const r = tc_bc1_decompress_rgba8(in.bc1.ptr, grid_width, ldr_height, stride, out.ptr, out.len);
    std.debug.assert(r == 0);
}

fn bc3DecodeZig(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    bcn.bc3.decodeImage(in.bc3, ldrImage(out));
}

fn bc3DecodeTexcomp(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    const stride = grid_width * 4;
    const r = tc_bc3_decompress_rgba8(in.bc3.ptr, grid_width, ldr_height, stride, out.ptr, out.len);
    std.debug.assert(r == 0);
}

fn bc4DecodeZig(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    for (0..ldr_blocks) |i| {
        out[i * 16 ..][0..16].* = bcn.bc4.decodeBlock(in.bc4[i * 8 ..][0..8]);
    }
}

fn bc4DecodeTexcomp(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    for (0..ldr_blocks) |i| tc_decode_bc4_block(in.bc4[i * 8 ..].ptr, out[i * 16 ..][0..16]);
}

/// Writes red and green only: blue and alpha keep what `rgba_fill` put
/// there, which is what texcomp writes.
fn bc5DecodeZig(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    bcn.bc5.decodeImage(in.bc5, ldrImage(out));
}

fn bc5DecodeTexcomp(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    const stride = grid_width * 4;
    const unorm = 0;
    const r = tc_bc5_decompress_rgba8(
        in.bc5.ptr,
        grid_width,
        ldr_height,
        unorm,
        stride,
        out.ptr,
        out.len,
    );
    std.debug.assert(r == 0);
}

/// Writes red and green only, as `bc5DecodeZig`.
fn bc5DecodeSnormZig(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    bcn.bc5.decodeImageSnorm(in.bc5_snorm, ldrImage(out));
}

fn bc5DecodeSnormTexcomp(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    const stride = grid_width * 4;
    const snorm = 1;
    const r = tc_bc5_decompress_rgba8(
        in.bc5_snorm.ptr,
        grid_width,
        ldr_height,
        snorm,
        stride,
        out.ptr,
        out.len,
    );
    std.debug.assert(r == 0);
}

fn bc7DecodeZig(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    bcn.bc7.decodeImage(in.bc7, ldrImage(out));
}

fn bc7DecodeTexcomp(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    const stride = grid_width * 4;
    const r = tc_bc7_decompress_rgba8(in.bc7.ptr, grid_width, ldr_height, stride, out.ptr, out.len);
    std.debug.assert(r == 0);
}

fn bc7DecodeF32Zig(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    const floats: []f32 = std.mem.bytesAsSlice(f32, out);
    bcn.bc7.decodeImageF32(in.bc7, .init(floats, grid_width, ldr_height, 4));
}

/// texcomp decodes to bytes in a buffer it allocates, then converts them.
fn bc7DecodeF32Texcomp(_: *const Case, in: *const Inputs, out: []align(64) u8) void {
    const floats: []f32 = std.mem.bytesAsSlice(f32, out);
    const stride_bytes = grid_width * 16;
    const r = tc_bc7_decompress_rgbaf(
        in.bc7.ptr,
        grid_width,
        ldr_height,
        stride_bytes,
        floats.ptr,
        out.len,
    );
    std.debug.assert(r == 0);
}

fn bc6hStream(case: *const Case, in: *const Inputs) []const u8 {
    return switch (case.format) {
        .unsigned => in.bc6h_unsigned,
        .signed => in.bc6h_signed,
    };
}

fn bc6hDecodeZig(case: *const Case, in: *const Inputs, out: []align(64) u8) void {
    const halves = std.mem.bytesAsSlice(u16, out);
    const dst = bcn.ImageMut(u16).init(halves, grid_width, hdr_height, 3);
    bcn.bc6h.decodeImage(bc6hStream(case, in), dst, case.format);
}

fn bc6hDecodeTexcomp(case: *const Case, in: *const Inputs, out: []align(64) u8) void {
    const halves = std.mem.bytesAsSlice(u16, out);
    const signed: c_int = @intFromBool(case.format == .signed);
    const stride = grid_width * 3 * 2;
    const src = bc6hStream(case, in);
    const r = tc_bc6h_decompress_rgb16f(
        src.ptr,
        grid_width,
        hdr_height,
        signed,
        stride,
        halves.ptr,
        out.len,
    );
    std.debug.assert(r == 0);
}

// --- Cases ----------------------------------------------------------------------

/// Settings a row runs with, beyond its sides.
const Variant = struct {
    stb: bcn.bc1.Settings = .{},
    level: bcn.bc7.Level = .basic,
    perceptual: bool = true,
    format: bcn.bc6h.Format = .unsigned,
    kernels: u32 = kernels_scalar,
    rgba_fill: bool = false,
};

/// A row over the RGBA blocks whose output takes `bytes` per block.
fn ldrCase(name: []const u8, bytes: usize, zig: Side, original: ?Side, v: Variant) Case {
    return withVariant(name, ldr_blocks, bytes, zig, original, v);
}

/// A row over the HDR blocks whose output takes `bytes` per block.
fn hdrCase(name: []const u8, bytes: usize, zig: Side, original: ?Side, v: Variant) Case {
    return withVariant(name, hdr_blocks, bytes, zig, original, v);
}

fn withVariant(
    name: []const u8,
    blocks: usize,
    bytes: usize,
    zig: Side,
    original: ?Side,
    v: Variant,
) Case {
    return .{
        .name = name,
        .blocks = blocks,
        .out_len = blocks * bytes,
        .zig = zig,
        .original = original,
        .stb = v.stb,
        .level = v.level,
        .perceptual = v.perceptual,
        .format = v.format,
        .kernels = v.kernels,
        .rgba_fill = v.rgba_fill,
    };
}

fn bc7Case(comptime name: []const u8, level: bcn.bc7.Level, perceptual: bool) Case {
    const v: Variant = .{ .level = level, .perceptual = perceptual };
    return ldrCase("bc7 encode " ++ name, 16, bc7Zig, bc7Bc7e, v);
}

const signed_format: Variant = .{ .format = .signed };

const cases = [_]Case{
    ldrCase("bc1 encode normal", 8, bc1Zig, bc1Stb, .{}),
    ldrCase("bc1 encode high", 8, bc1Zig, bc1Stb, .{ .stb = .{ .quality = .high } }),
    ldrCase("bc1 encode normal biased", 8, bc1Zig, bc1Stb, .{ .stb = .{ .rounding = .biased } }),
    ldrCase("bc3 encode normal", 16, bc3Zig, bc3Stb, .{}),
    ldrCase("bc3 encode high", 16, bc3Zig, bc3Stb, .{ .stb = .{ .quality = .high } }),
    ldrCase("bc4 encode", 8, bc4Zig, bc4Stb, .{}),
    ldrCase("bc5 encode", 16, bc5Zig, bc5Stb, .{}),
    bc7Case("ultrafast", .ultrafast, true),
    bc7Case("veryfast", .veryfast, true),
    bc7Case("fast", .fast, true),
    bc7Case("basic", .basic, true),
    bc7Case("basic linear", .basic, false),
    bc7Case("slow", .slow, true),
    bc7Case("veryslow", .veryslow, true),
    bc7Case("slowest", .slowest, true),
    hdrCase("bc6h encode unsigned", 16, bc6hZig, bc6hTexcomp, .{}),
    hdrCase("bc6h encode signed", 16, bc6hZig, bc6hTexcomp, signed_format),
    hdrCase("bc6h encode unsigned, texcomp simd", 16, bc6hZig, bc6hTexcomp, .{
        .kernels = kernels_all,
    }),
    hdrCase("bc6h encode signed, texcomp simd", 16, bc6hZig, bc6hTexcomp, .{
        .format = .signed,
        .kernels = kernels_all,
    }),
    hdrCase("bc6h encode high unsigned", 16, bc6hHighZig, null, .{}),
    hdrCase("bc6h encode high signed", 16, bc6hHighZig, null, signed_format),
    ldrCase("bc1 decode", 64, bc1DecodeZig, bc1DecodeTexcomp, .{}),
    ldrCase("bc3 decode", 64, bc3DecodeZig, bc3DecodeTexcomp, .{}),
    ldrCase("bc4 decode", 16, bc4DecodeZig, bc4DecodeTexcomp, .{}),
    ldrCase("bc5 decode", 64, bc5DecodeZig, bc5DecodeTexcomp, .{ .rgba_fill = true }),
    ldrCase("bc5 decode snorm", 64, bc5DecodeSnormZig, bc5DecodeSnormTexcomp, .{
        .rgba_fill = true,
    }),
    ldrCase("bc7 decode", 64, bc7DecodeZig, bc7DecodeTexcomp, .{}),
    ldrCase("bc7 decode f32", 256, bc7DecodeF32Zig, bc7DecodeF32Texcomp, .{}),
    hdrCase("bc6h decode unsigned", 96, bc6hDecodeZig, bc6hDecodeTexcomp, .{}),
    hdrCase("bc6h decode signed", 96, bc6hDecodeZig, bc6hDecodeTexcomp, signed_format),
};

// --- Measurement ----------------------------------------------------------------

/// Nanoseconds of thread CPU time for `reps` passes.
fn timePasses(
    io: std.Io,
    side: Side,
    case: *const Case,
    in: *const Inputs,
    out: []align(64) u8,
    reps: u32,
) u64 {
    const start = std.Io.Clock.cpu_thread.now(io);
    for (0..reps) |_| {
        // The barriers make every pass read its inputs and write its output.
        std.mem.doNotOptimizeAway(in);
        side(case, in, out);
        std.mem.doNotOptimizeAway(out.ptr);
    }
    const end = std.Io.Clock.cpu_thread.now(io);
    return @intCast(start.durationTo(end).nanoseconds);
}

/// Passes per sample so that a sample lasts at least `sample_ns_min`.
fn passesPerSample(
    io: std.Io,
    side: Side,
    case: *const Case,
    in: *const Inputs,
    out: []align(64) u8,
) u32 {
    const once = @max(timePasses(io, side, case, in, out, 1), 1);
    return @intCast(@max(1, std.math.divCeil(u64, sample_ns_min, once) catch unreachable));
}

const Timing = struct {
    /// Median nanoseconds per pass.
    median_ns: f64,
    /// (slowest - fastest) / median, over the samples.
    range: f64,

    fn of(pass_ns: []f64) Timing {
        std.mem.sort(f64, pass_ns, {}, std.sort.asc(f64));
        const mid = pass_ns.len / 2;
        const median = if (pass_ns.len % 2 == 1)
            pass_ns[mid]
        else
            (pass_ns[mid - 1] + pass_ns[mid]) / 2;
        return .{ .median_ns = median, .range = (pass_ns[pass_ns.len - 1] - pass_ns[0]) / median };
    }

    fn better(a: ?Timing, b: Timing) Timing {
        const old = a orelse return b;
        return if (b.median_ns < old.median_ns) b else old;
    }
};

const Result = struct {
    zig: ?Timing = null,
    original: ?Timing = null,
    same_bytes: bool = true,
};

fn measure(
    io: std.Io,
    case: *const Case,
    in: *const Inputs,
    zig_out: []align(64) u8,
    original_out: []align(64) u8,
    samples: u32,
    scratch: []f64,
) struct { zig: Timing, original: ?Timing, same_bytes: bool } {
    const zig_reps = passesPerSample(io, case.zig, case, in, zig_out);
    const original_reps = if (case.original) |o|
        passesPerSample(io, o, case, in, original_out)
    else
        0;
    const zig_ns = scratch[0..samples];
    const original_ns = scratch[samples..][0..samples];
    for (0..warm_up_samples + samples) |k| {
        // Alternating which side goes first evens out any advantage of
        // running second, such as caches the other side warmed.
        for (0..2) |turn| {
            const zig_turn = (turn == 0) == (k % 2 == 0);
            if (zig_turn) {
                const ns = timePasses(io, case.zig, case, in, zig_out, zig_reps);
                if (k >= warm_up_samples) zig_ns[k - warm_up_samples] = perPass(ns, zig_reps);
            } else if (case.original) |o| {
                const ns = timePasses(io, o, case, in, original_out, original_reps);
                if (k >= warm_up_samples) {
                    original_ns[k - warm_up_samples] = perPass(ns, original_reps);
                }
            }
        }
    }
    const same = case.original == null or std.mem.eql(u8, zig_out, original_out);
    return .{
        .zig = Timing.of(zig_ns),
        .original = if (case.original != null) Timing.of(original_ns) else null,
        .same_bytes = same,
    };
}

fn perPass(ns: u64, reps: u32) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(reps));
}

fn mpixPerSecond(case: *const Case, t: Timing) f64 {
    return @as(f64, @floatFromInt(case.blocks * 16)) / t.median_ns * 1e3;
}

// --- Setup ----------------------------------------------------------------------

fn prepare(gpa: std.mem.Allocator) !Inputs {
    const rgba = try gpa.alignedAlloc([16][4]u8, .@"64", ldr_blocks);
    const rgb = try gpa.alignedAlloc([16][4]u8, .@"64", ldr_blocks);
    const red = try gpa.alloc([16]u8, ldr_blocks);
    const red_green = try gpa.alloc([16][2]u8, ldr_blocks);
    const hdr = try gpa.alloc([16][3]f32, hdr_blocks);

    for (0..images.ldr_names.len) |index| {
        const img = images.ldr(index);
        const bytes = std.mem.sliceAsBytes(&img.pixels);
        const view = bcn.Image(u8).init(bytes, images.width, images.height, 4);
        for (0..blocks_per_image) |b| {
            const bx: u32 = @intCast(b % images_blocks_wide);
            const by: u32 = @intCast(b / images_blocks_wide);
            const i = index * blocks_per_image + b;
            rgba[i] = view.block(4, bx, by);
            for (rgba[i], &rgb[i], &red[i], &red_green[i]) |p, *o, *r, *rg| {
                o.* = .{ p[0], p[1], p[2], 255 };
                r.* = p[0];
                rg.* = .{ p[0], p[1] };
            }
        }
    }
    for (0..images.hdr_names.len) |index| {
        const img = images.hdr(index);
        const floats: []const f32 = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(&img.pixels));
        const view = bcn.Image(f32).init(floats, images.width, images.height, 3);
        for (0..blocks_per_image) |b| {
            const bx: u32 = @intCast(b % images_blocks_wide);
            const by: u32 = @intCast(b / images_blocks_wide);
            hdr[index * blocks_per_image + b] = view.block(3, bx, by);
        }
    }

    const bc1 = try gpa.alloc(u8, ldr_blocks * 8);
    const bc3 = try gpa.alloc(u8, ldr_blocks * 16);
    const bc4 = try gpa.alloc(u8, ldr_blocks * 8);
    const bc5 = try gpa.alloc(u8, ldr_blocks * 16);
    const bc5_snorm = try gpa.alloc(u8, ldr_blocks * 16);
    const bc7 = try gpa.alloc(u8, ldr_blocks * 16);
    const bc7_params = bcn.bc7.Params.init(.basic, true);
    const snorm: TcBc5Options = .{ .snorm = 1 };
    for (0..ldr_blocks) |i| {
        bc1[i * 8 ..][0..8].* = bcn.bc1.encodeBlock(&rgb[i], .{});
        bc3[i * 16 ..][0..16].* = bcn.bc3.encodeBlock(&rgba[i], .{});
        bc4[i * 8 ..][0..8].* = bcn.bc4.encodeBlock(&red[i]);
        bc5[i * 16 ..][0..16].* = bcn.bc5.encodeBlock(&red_green[i]);
        const rg: [*]const u8 = @ptrCast(&red_green[i]);
        const r = tc_bc5_compress_rg8(rg, 4, 4, 8, &snorm, bc5_snorm[i * 16 ..].ptr, 16);
        std.debug.assert(r == 0);
        bc7[i * 16 ..][0..16].* = bcn.bc7.encodeBlock(&rgba[i], &bc7_params);
    }
    const bc6h_unsigned = try gpa.alloc(u8, hdr_blocks * 16);
    const bc6h_signed = try gpa.alloc(u8, hdr_blocks * 16);
    for (0..hdr_blocks) |i| {
        bc6h_unsigned[i * 16 ..][0..16].* = bcn.bc6h.encodeBlock(&hdr[i], .unsigned);
        bc6h_signed[i * 16 ..][0..16].* = bcn.bc6h.encodeBlock(&hdr[i], .signed);
    }
    return .{
        .rgba = rgba,
        .rgb = rgb,
        .red = red,
        .red_green = red_green,
        .hdr = hdr,
        .bc1 = bc1,
        .bc3 = bc3,
        .bc4 = bc4,
        .bc5 = bc5,
        .bc5_snorm = bc5_snorm,
        .bc7 = bc7,
        .bc6h_unsigned = bc6h_unsigned,
        .bc6h_signed = bc6h_signed,
    };
}

const Options = struct {
    samples: u32 = 11,
    rounds: u32 = 1,
    filter: ?[]const u8 = null,
};

fn parseOptions(args: []const [:0]const u8) !Options {
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (i + 1 >= args.len) return error.MissingValue;
        const value = args[i + 1];
        if (std.mem.eql(u8, arg, "--samples")) {
            options.samples = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--rounds")) {
            options.rounds = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--filter")) {
            options.filter = value;
        } else {
            return error.UnknownOption;
        }
        i += 1;
    }
    if (options.samples == 0 or options.rounds == 0) return error.ZeroCount;
    return options;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const options = try parseOptions(try init.minimal.args.toSlice(gpa));

    ref_bc7e_init();
    const in = try prepare(gpa);
    var out_len_max: usize = 0;
    for (cases) |c| out_len_max = @max(out_len_max, c.out_len);
    const zig_buffer = try gpa.alignedAlloc(u8, .@"64", out_len_max);
    const original_buffer = try gpa.alignedAlloc(u8, .@"64", out_len_max);
    const scratch = try gpa.alloc(f64, 2 * options.samples);

    var results: [cases.len]Result = @splat(.{});
    for (0..options.rounds) |_| {
        for (&cases, &results) |*case, *result| {
            if (options.filter) |f| if (std.mem.find(u8, case.name, f) == null) continue;
            const zig_out = zig_buffer[0..case.out_len];
            const original_out = original_buffer[0..case.out_len];
            if (case.rgba_fill) {
                for (std.mem.bytesAsSlice([4]u8, zig_out)) |*p| p.* = .{ 0, 0, 0, 255 };
            }
            const m = measure(io, case, &in, zig_out, original_out, options.samples, scratch);
            result.zig = Timing.better(result.zig, m.zig);
            if (m.original) |o| result.original = Timing.better(result.original, o);
            result.same_bytes = result.same_bytes and m.same_bytes;
        }
    }
    tc_backend_force_mask(kernels_all);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;
    try w.print(
        \\zig-bcn benchmark: {s} {s}, {s}, Zig {s}, one thread
        \\{d} RGBA and {d} HDR blocks per pass; median of {d} samples of at least {d} ms
        \\after {d} warm-ups, best of {d} round(s); thread CPU time
        \\texcomp selector kernels: scalar, and {s} in the simd rows
        \\
        \\| feature | zig-bcn Mpix/s | range | original Mpix/s | range | zig-bcn / original |
        \\| --- | ---: | ---: | ---: | ---: | ---: |
        \\
    , .{
        @tagName(builtin.cpu.arch), builtin.cpu.model.name,             @tagName(builtin.os.tag),
        builtin.zig_version_string, ldr_blocks,                         hdr_blocks,
        options.samples,            sample_ns_min / std.time.ns_per_ms, warm_up_samples,
        options.rounds,             tc_backend_name(),
    });
    for (&cases, &results) |*case, result| {
        const zig = result.zig orelse continue;
        const zig_mpix = mpixPerSecond(case, zig);
        try w.print("| {s} | {d:.2} | {d:.1}% |", .{ case.name, zig_mpix, zig.range * 100 });
        if (result.original) |o| {
            const ratio = o.median_ns / zig.median_ns;
            const o_mpix = mpixPerSecond(case, o);
            try w.print(" {d:.2} | {d:.1}% | {d:.2} |", .{ o_mpix, o.range * 100, ratio });
        } else {
            try w.print(" no original | | |", .{});
        }
        if (!result.same_bytes) try w.print(" OUTPUT DIFFERS", .{});
        try w.print("\n", .{});
    }
    try w.flush();
}
