// BC6H quality and speed: texcomp's encoder (which zig-bcn's port matches
// byte for byte) against DirectXTex's BC6H encoder, the D3DX-derived
// reference. Not part of `zig build test`; see doc/bc6h-quality.md and
// build.sh.
//
//   quality [--dump <dir>] <image>...   (.exr, or .rgbf from dump_images.zig)
//
// --dump writes each loaded image as <dir>/<basename>.rgbf, for speed.zig.

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "BC.h"
#include "tinyexr.h"
extern "C" {
#include "texcomp.h"
}

using namespace DirectX;

struct Image {
    std::string name;
    int width = 0, height = 0;
    std::vector<float> rgb;  // width * height * 3
};

static bool load(const char *path, Image &img) {
    img.name = path;
    std::string p = path;
    if (p.size() > 4 && p.substr(p.size() - 4) == ".exr") {
        float *rgba = nullptr;
        const char *err = nullptr;
        if (LoadEXR(&rgba, &img.width, &img.height, path, &err) != TINYEXR_SUCCESS) {
            std::fprintf(stderr, "%s: %s\n", path, err ? err : "load failed");
            return false;
        }
        img.rgb.resize(size_t(img.width) * img.height * 3);
        for (size_t i = 0; i < size_t(img.width) * img.height; ++i)
            for (int c = 0; c < 3; ++c) img.rgb[i * 3 + c] = rgba[i * 4 + c];
        free(rgba);
        return true;
    }
    FILE *f = std::fopen(path, "rb");
    if (!f) return false;
    char magic[4];
    uint32_t wh[2];
    bool ok = std::fread(magic, 1, 4, f) == 4 && std::memcmp(magic, "RGBF", 4) == 0 && std::fread(wh, 4, 2, f) == 2;
    if (ok) {
        img.width = int(wh[0]);
        img.height = int(wh[1]);
        img.rgb.resize(size_t(img.width) * img.height * 3);
        ok = std::fread(img.rgb.data(), 4, img.rgb.size(), f) == img.rgb.size();
    }
    std::fclose(f);
    return ok;
}

// What the format can hold: unsigned clamps negatives and NaN to 0, both
// clamp magnitudes to the largest half.
static double representable(float x, bool is_signed) {
    if (std::isnan(x)) return 0;
    double lo = is_signed ? -65504.0 : 0.0;
    return std::fmin(std::fmax(double(x), lo), 65504.0);
}

struct Metrics {
    double log_rmse;  // RMSE of sign(x) * log2(1 + |x|)
    double mpsnr;     // multi-exposure PSNR, exposures -6..+6 stops
};

static Metrics measure(const Image &img, const std::vector<float> &rgba, bool is_signed) {
    double sum = 0, sum_t = 0;
    size_t n = 0, n_t = 0;
    for (size_t i = 0; i < size_t(img.width) * img.height; ++i)
        for (int c = 0; c < 3; ++c) {
            double want = representable(img.rgb[i * 3 + c], is_signed);
            double got = rgba[i * 4 + c];
            double lw = std::copysign(std::log2(1 + std::fabs(want)), want);
            double lg = std::copysign(std::log2(1 + std::fabs(got)), got);
            sum += (lw - lg) * (lw - lg);
            ++n;
            // Tone map the magnitude at each exposure to 8-bit gamma 2.2.
            for (int e = -6; e <= 6; ++e) {
                auto tm = [&](double v) {
                    double t = std::pow(std::fabs(v) * std::ldexp(1.0, e), 1.0 / 2.2) * 255.0;
                    return std::fmin(std::round(t), 255.0);
                };
                double d = tm(want) - tm(got);
                sum_t += d * d;
                ++n_t;
            }
        }
    double mse_t = sum_t / double(n_t);
    return {std::sqrt(sum / double(n)), mse_t > 0 ? 10 * std::log10(255.0 * 255.0 / mse_t) : 99.0};
}

static int mode_of(const uint8_t *b) {
    static const int codes[32] = {
        //   0   1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
        0, 1, 2, 10, 0, 1, 3, 11, 0, 1, 4, 12, 0, 1, 5, 13,
        0, 1, 6, -1, 0, 1, 7, -1, 0, 1, 8, -1, 0, 1, 9, -1};
    return codes[b[0] & 0x1f];
}

static double seconds_since(std::chrono::steady_clock::time_point t0) {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
}

static void encode_dxtex(const Image &img, bool is_signed, std::vector<uint8_t> &out) {
    const int bw = (img.width + 3) / 4, bh = (img.height + 3) / 4;
    out.assign(size_t(bw) * bh * 16, 0);
    for (int by = 0; by < bh; ++by)
        for (int bx = 0; bx < bw; ++bx) {
            XMVECTOR px[16];
            for (int i = 0; i < 16; ++i) {
                int x = std::min(bx * 4 + i % 4, img.width - 1), y = std::min(by * 4 + i / 4, img.height - 1);
                const float *s = &img.rgb[(size_t(y) * img.width + x) * 3];
                px[i] = XMVectorSet(s[0], s[1], s[2], 1.0f);
            }
            uint8_t *dst = &out[(size_t(by) * bw + bx) * 16];
            if (is_signed) D3DXEncodeBC6HS(dst, px, BC_FLAGS_NONE);
            else D3DXEncodeBC6HU(dst, px, BC_FLAGS_NONE);
        }
}

static void report(const Image &img, bool is_signed, const char *encoder, const std::vector<uint8_t> &blocks, double secs) {
    std::vector<float> rgba(size_t(img.width) * img.height * 4);
    tc_bc6h_decompress_rgbaf(blocks.data(), img.width, img.height, is_signed, size_t(img.width) * 16, rgba.data(), rgba.size() * 4);
    Metrics m = measure(img, rgba, is_signed);
    int modes[15] = {0};
    for (size_t i = 0; i < blocks.size(); i += 16) {
        int md = mode_of(&blocks[i]);
        modes[md < 0 ? 14 : md]++;
    }
    std::printf("| %s | %s | %s | %.4f | %.2f | %.2f |", img.name.c_str(), is_signed ? "sf16" : "uf16", encoder, m.log_rmse, m.mpsnr,
                double(img.width) * img.height / secs / 1e6);
    for (int i = 0; i < 15; ++i)
        if (modes[i]) std::printf(" %d:%d", i, modes[i]);
    std::printf(" |\n");

    // Cross-check the two decoders on this stream.
    size_t differ = 0;
    for (size_t i = 0; i < blocks.size(); i += 16) {
        XMVECTOR px[16];
        if (is_signed) D3DXDecodeBC6HS(px, &blocks[i]);
        else D3DXDecodeBC6HU(px, &blocks[i]);
        size_t b = i / 16;
        int bw = (img.width + 3) / 4, bx = int(b % bw), by = int(b / bw);
        for (int t = 0; t < 16; ++t) {
            int x = bx * 4 + t % 4, y = by * 4 + t / 4;
            if (x >= img.width || y >= img.height) continue;
            XMFLOAT4 f;
            XMStoreFloat4(&f, px[t]);
            const float *g = &rgba[(size_t(y) * img.width + x) * 4];
            if (f.x != g[0] || f.y != g[1] || f.z != g[2]) { ++differ; break; }
        }
    }
    if (differ) std::printf("|  | | %s: DirectXTex and texcomp decoders disagree on %zu blocks | | | | |\n", encoder, differ);
}

int main(int argc, char **argv) {
    std::printf("| image | format | encoder | log2 RMSE | mPSNR dB | Mpixel/s | modes chosen (mode:blocks) |\n|---|---|---|---|---|---|---|\n");
    const char *dump = nullptr;
    int first = 1;
    if (argc > 2 && std::strcmp(argv[1], "--dump") == 0) {
        dump = argv[2];
        first = 3;
    }
    for (int a = first; a < argc; ++a) {
        Image img;
        if (!load(argv[a], img)) return 1;
        if (dump) {
            std::string base = img.name.substr(img.name.find_last_of('/') + 1);
            std::string out = std::string(dump) + "/" + base.substr(0, base.find_last_of('.')) + ".rgbf";
            FILE *f = std::fopen(out.c_str(), "wb");
            uint32_t wh[2] = {uint32_t(img.width), uint32_t(img.height)};
            std::fwrite("RGBF", 1, 4, f);
            std::fwrite(wh, 4, 2, f);
            std::fwrite(img.rgb.data(), 4, img.rgb.size(), f);
            std::fclose(f);
        }
        for (int s = 0; s < 2; ++s) {
            const bool is_signed = s == 1;
            std::vector<uint8_t> tc(tc_bc6h_compressed_size(img.width, img.height)), dx;
            tc_bc6h_options opt;
            tc_bc6h_options_init(&opt);
            opt.signed_float = is_signed;
            auto t0 = std::chrono::steady_clock::now();
            tc_bc6h_compress_rgb32f(img.rgb.data(), img.width, img.height, size_t(img.width) * 12, &opt, tc.data(), tc.size());
            double t_tc = seconds_since(t0);
            t0 = std::chrono::steady_clock::now();
            encode_dxtex(img, is_signed, dx);
            double t_dx = seconds_since(t0);
            report(img, is_signed, "texcomp", tc, t_tc);
            report(img, is_signed, "DirectXTex", dx, t_dx);
        }
    }
    return 0;
}
