#include "tungsten/parser_corpus.hpp"

#include "tungsten/notebook.hpp"
#include "tungsten/wolfram_processes.hpp"
#include "tungsten/wolfram_strings.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <fstream>
#include <limits>
#include <locale>
#include <sstream>
#include <thread>
#include <utility>

namespace tungsten {
namespace {

namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;

std::string path_text(const fs::path& path) { return path.u8string(); }

std::string whole_second_utc_now() {
    auto value = utc_now_string();
    const auto fraction = value.find('.');
    if (fraction != std::string::npos && !value.empty() && value.back() == 'Z')
        value.erase(fraction, value.size() - fraction - 1);
    return value;
}

fs::path absolute_path(const fs::path& path) {
    std::error_code error;
    auto canonical = fs::canonical(path, error);
    if (!error) return canonical;
    if (path.is_absolute()) return path.lexically_normal();
    auto absolute = fs::absolute(path, error);
    return error ? path.lexically_normal() : absolute.lexically_normal();
}

std::string slash_absolute(const fs::path& path) {
    auto value = path_text(absolute_path(path));
    std::replace(value.begin(), value.end(), '\\', '/');
    return value;
}

struct Utf8Character {
    std::uint32_t value;
    std::size_t length;
};

Utf8Character decode_utf8_character(
    const std::string& value, std::size_t position) noexcept {
    const auto lead = static_cast<unsigned char>(value[position]);
    if (lead < 0x80) return {lead, 1};
    std::size_t length = 0;
    std::uint32_t codepoint = 0;
    std::uint32_t minimum = 0;
    if (lead >= 0xc2 && lead <= 0xdf) {
        length = 2; codepoint = lead & 0x1f; minimum = 0x80;
    } else if (lead >= 0xe0 && lead <= 0xef) {
        length = 3; codepoint = lead & 0x0f; minimum = 0x800;
    } else if (lead >= 0xf0 && lead <= 0xf4) {
        length = 4; codepoint = lead & 0x07; minimum = 0x10000;
    } else {
        return {lead, 1};
    }
    if (position + length > value.size()) return {lead, 1};
    for (std::size_t index = 1; index < length; ++index) {
        const auto continuation = static_cast<unsigned char>(value[position + index]);
        if ((continuation & 0xc0) != 0x80) return {lead, 1};
        codepoint = (codepoint << 6) | (continuation & 0x3f);
    }
    if (codepoint < minimum || codepoint > 0x10ffff
        || (codepoint >= 0xd800 && codepoint <= 0xdfff)) return {lead, 1};
    return {codepoint, length};
}

struct UnicodeRange {
    std::uint32_t first;
    std::uint32_t last;
    std::uint32_t step;
    std::int32_t delta;
};

struct UnicodeMapping {
    std::uint32_t source;
    std::array<std::uint32_t, 3> targets;
    std::uint8_t size;
};

// Generated from the Unicode 15.1 mappings used by CPython 3.12.
static constexpr UnicodeRange unicode_lower_ranges[] = {
    {0x41U, 0x5aU, 1U, 32},
    {0xc0U, 0xd6U, 1U, 32},
    {0xd8U, 0xdeU, 1U, 32},
    {0x100U, 0x12eU, 2U, 1},
    {0x132U, 0x136U, 2U, 1},
    {0x139U, 0x147U, 2U, 1},
    {0x14aU, 0x176U, 2U, 1},
    {0x179U, 0x17dU, 2U, 1},
    {0x182U, 0x184U, 2U, 1},
    {0x189U, 0x18aU, 1U, 205},
    {0x1a0U, 0x1a4U, 2U, 1},
    {0x1b1U, 0x1b2U, 1U, 217},
    {0x1b3U, 0x1b5U, 2U, 1},
    {0x1cbU, 0x1dbU, 2U, 1},
    {0x1deU, 0x1eeU, 2U, 1},
    {0x1f2U, 0x1f4U, 2U, 1},
    {0x1f8U, 0x21eU, 2U, 1},
    {0x222U, 0x232U, 2U, 1},
    {0x246U, 0x24eU, 2U, 1},
    {0x370U, 0x372U, 2U, 1},
    {0x388U, 0x38aU, 1U, 37},
    {0x38eU, 0x38fU, 1U, 63},
    {0x391U, 0x3a1U, 1U, 32},
    {0x3a3U, 0x3abU, 1U, 32},
    {0x3d8U, 0x3eeU, 2U, 1},
    {0x3fdU, 0x3ffU, 1U, -130},
    {0x400U, 0x40fU, 1U, 80},
    {0x410U, 0x42fU, 1U, 32},
    {0x460U, 0x480U, 2U, 1},
    {0x48aU, 0x4beU, 2U, 1},
    {0x4c1U, 0x4cdU, 2U, 1},
    {0x4d0U, 0x52eU, 2U, 1},
    {0x531U, 0x556U, 1U, 48},
    {0x10a0U, 0x10c5U, 1U, 7264},
    {0x13a0U, 0x13efU, 1U, 38864},
    {0x13f0U, 0x13f5U, 1U, 8},
    {0x1c90U, 0x1cbaU, 1U, -3008},
    {0x1cbdU, 0x1cbfU, 1U, -3008},
    {0x1e00U, 0x1e94U, 2U, 1},
    {0x1ea0U, 0x1efeU, 2U, 1},
    {0x1f08U, 0x1f0fU, 1U, -8},
    {0x1f18U, 0x1f1dU, 1U, -8},
    {0x1f28U, 0x1f2fU, 1U, -8},
    {0x1f38U, 0x1f3fU, 1U, -8},
    {0x1f48U, 0x1f4dU, 1U, -8},
    {0x1f59U, 0x1f5fU, 2U, -8},
    {0x1f68U, 0x1f6fU, 1U, -8},
    {0x1f88U, 0x1f8fU, 1U, -8},
    {0x1f98U, 0x1f9fU, 1U, -8},
    {0x1fa8U, 0x1fafU, 1U, -8},
    {0x1fb8U, 0x1fb9U, 1U, -8},
    {0x1fbaU, 0x1fbbU, 1U, -74},
    {0x1fc8U, 0x1fcbU, 1U, -86},
    {0x1fd8U, 0x1fd9U, 1U, -8},
    {0x1fdaU, 0x1fdbU, 1U, -100},
    {0x1fe8U, 0x1fe9U, 1U, -8},
    {0x1feaU, 0x1febU, 1U, -112},
    {0x1ff8U, 0x1ff9U, 1U, -128},
    {0x1ffaU, 0x1ffbU, 1U, -126},
    {0x2160U, 0x216fU, 1U, 16},
    {0x24b6U, 0x24cfU, 1U, 26},
    {0x2c00U, 0x2c2fU, 1U, 48},
    {0x2c67U, 0x2c6bU, 2U, 1},
    {0x2c7eU, 0x2c7fU, 1U, -10815},
    {0x2c80U, 0x2ce2U, 2U, 1},
    {0x2cebU, 0x2cedU, 2U, 1},
    {0xa640U, 0xa66cU, 2U, 1},
    {0xa680U, 0xa69aU, 2U, 1},
    {0xa722U, 0xa72eU, 2U, 1},
    {0xa732U, 0xa76eU, 2U, 1},
    {0xa779U, 0xa77bU, 2U, 1},
    {0xa77eU, 0xa786U, 2U, 1},
    {0xa790U, 0xa792U, 2U, 1},
    {0xa796U, 0xa7a8U, 2U, 1},
    {0xa7b4U, 0xa7c2U, 2U, 1},
    {0xa7c7U, 0xa7c9U, 2U, 1},
    {0xa7d6U, 0xa7d8U, 2U, 1},
    {0xff21U, 0xff3aU, 1U, 32},
    {0x10400U, 0x10427U, 1U, 40},
    {0x104b0U, 0x104d3U, 1U, 40},
    {0x10570U, 0x1057aU, 1U, 39},
    {0x1057cU, 0x1058aU, 1U, 39},
    {0x1058cU, 0x10592U, 1U, 39},
    {0x10594U, 0x10595U, 1U, 39},
    {0x10c80U, 0x10cb2U, 1U, 64},
    {0x118a0U, 0x118bfU, 1U, 32},
    {0x16e40U, 0x16e5fU, 1U, 32},
    {0x1e900U, 0x1e921U, 1U, 34},
};

static constexpr UnicodeMapping unicode_lower_mappings[] = {
    {0x130U, {0x69U, 0x307U, 0x0U}, 2U},
    {0x178U, {0xffU, 0x0U, 0x0U}, 1U},
    {0x181U, {0x253U, 0x0U, 0x0U}, 1U},
    {0x186U, {0x254U, 0x0U, 0x0U}, 1U},
    {0x187U, {0x188U, 0x0U, 0x0U}, 1U},
    {0x18bU, {0x18cU, 0x0U, 0x0U}, 1U},
    {0x18eU, {0x1ddU, 0x0U, 0x0U}, 1U},
    {0x18fU, {0x259U, 0x0U, 0x0U}, 1U},
    {0x190U, {0x25bU, 0x0U, 0x0U}, 1U},
    {0x191U, {0x192U, 0x0U, 0x0U}, 1U},
    {0x193U, {0x260U, 0x0U, 0x0U}, 1U},
    {0x194U, {0x263U, 0x0U, 0x0U}, 1U},
    {0x196U, {0x269U, 0x0U, 0x0U}, 1U},
    {0x197U, {0x268U, 0x0U, 0x0U}, 1U},
    {0x198U, {0x199U, 0x0U, 0x0U}, 1U},
    {0x19cU, {0x26fU, 0x0U, 0x0U}, 1U},
    {0x19dU, {0x272U, 0x0U, 0x0U}, 1U},
    {0x19fU, {0x275U, 0x0U, 0x0U}, 1U},
    {0x1a6U, {0x280U, 0x0U, 0x0U}, 1U},
    {0x1a7U, {0x1a8U, 0x0U, 0x0U}, 1U},
    {0x1a9U, {0x283U, 0x0U, 0x0U}, 1U},
    {0x1acU, {0x1adU, 0x0U, 0x0U}, 1U},
    {0x1aeU, {0x288U, 0x0U, 0x0U}, 1U},
    {0x1afU, {0x1b0U, 0x0U, 0x0U}, 1U},
    {0x1b7U, {0x292U, 0x0U, 0x0U}, 1U},
    {0x1b8U, {0x1b9U, 0x0U, 0x0U}, 1U},
    {0x1bcU, {0x1bdU, 0x0U, 0x0U}, 1U},
    {0x1c4U, {0x1c6U, 0x0U, 0x0U}, 1U},
    {0x1c5U, {0x1c6U, 0x0U, 0x0U}, 1U},
    {0x1c7U, {0x1c9U, 0x0U, 0x0U}, 1U},
    {0x1c8U, {0x1c9U, 0x0U, 0x0U}, 1U},
    {0x1caU, {0x1ccU, 0x0U, 0x0U}, 1U},
    {0x1f1U, {0x1f3U, 0x0U, 0x0U}, 1U},
    {0x1f6U, {0x195U, 0x0U, 0x0U}, 1U},
    {0x1f7U, {0x1bfU, 0x0U, 0x0U}, 1U},
    {0x220U, {0x19eU, 0x0U, 0x0U}, 1U},
    {0x23aU, {0x2c65U, 0x0U, 0x0U}, 1U},
    {0x23bU, {0x23cU, 0x0U, 0x0U}, 1U},
    {0x23dU, {0x19aU, 0x0U, 0x0U}, 1U},
    {0x23eU, {0x2c66U, 0x0U, 0x0U}, 1U},
    {0x241U, {0x242U, 0x0U, 0x0U}, 1U},
    {0x243U, {0x180U, 0x0U, 0x0U}, 1U},
    {0x244U, {0x289U, 0x0U, 0x0U}, 1U},
    {0x245U, {0x28cU, 0x0U, 0x0U}, 1U},
    {0x376U, {0x377U, 0x0U, 0x0U}, 1U},
    {0x37fU, {0x3f3U, 0x0U, 0x0U}, 1U},
    {0x386U, {0x3acU, 0x0U, 0x0U}, 1U},
    {0x38cU, {0x3ccU, 0x0U, 0x0U}, 1U},
    {0x3cfU, {0x3d7U, 0x0U, 0x0U}, 1U},
    {0x3f4U, {0x3b8U, 0x0U, 0x0U}, 1U},
    {0x3f7U, {0x3f8U, 0x0U, 0x0U}, 1U},
    {0x3f9U, {0x3f2U, 0x0U, 0x0U}, 1U},
    {0x3faU, {0x3fbU, 0x0U, 0x0U}, 1U},
    {0x4c0U, {0x4cfU, 0x0U, 0x0U}, 1U},
    {0x10c7U, {0x2d27U, 0x0U, 0x0U}, 1U},
    {0x10cdU, {0x2d2dU, 0x0U, 0x0U}, 1U},
    {0x1e9eU, {0xdfU, 0x0U, 0x0U}, 1U},
    {0x1fbcU, {0x1fb3U, 0x0U, 0x0U}, 1U},
    {0x1fccU, {0x1fc3U, 0x0U, 0x0U}, 1U},
    {0x1fecU, {0x1fe5U, 0x0U, 0x0U}, 1U},
    {0x1ffcU, {0x1ff3U, 0x0U, 0x0U}, 1U},
    {0x2126U, {0x3c9U, 0x0U, 0x0U}, 1U},
    {0x212aU, {0x6bU, 0x0U, 0x0U}, 1U},
    {0x212bU, {0xe5U, 0x0U, 0x0U}, 1U},
    {0x2132U, {0x214eU, 0x0U, 0x0U}, 1U},
    {0x2183U, {0x2184U, 0x0U, 0x0U}, 1U},
    {0x2c60U, {0x2c61U, 0x0U, 0x0U}, 1U},
    {0x2c62U, {0x26bU, 0x0U, 0x0U}, 1U},
    {0x2c63U, {0x1d7dU, 0x0U, 0x0U}, 1U},
    {0x2c64U, {0x27dU, 0x0U, 0x0U}, 1U},
    {0x2c6dU, {0x251U, 0x0U, 0x0U}, 1U},
    {0x2c6eU, {0x271U, 0x0U, 0x0U}, 1U},
    {0x2c6fU, {0x250U, 0x0U, 0x0U}, 1U},
    {0x2c70U, {0x252U, 0x0U, 0x0U}, 1U},
    {0x2c72U, {0x2c73U, 0x0U, 0x0U}, 1U},
    {0x2c75U, {0x2c76U, 0x0U, 0x0U}, 1U},
    {0x2cf2U, {0x2cf3U, 0x0U, 0x0U}, 1U},
    {0xa77dU, {0x1d79U, 0x0U, 0x0U}, 1U},
    {0xa78bU, {0xa78cU, 0x0U, 0x0U}, 1U},
    {0xa78dU, {0x265U, 0x0U, 0x0U}, 1U},
    {0xa7aaU, {0x266U, 0x0U, 0x0U}, 1U},
    {0xa7abU, {0x25cU, 0x0U, 0x0U}, 1U},
    {0xa7acU, {0x261U, 0x0U, 0x0U}, 1U},
    {0xa7adU, {0x26cU, 0x0U, 0x0U}, 1U},
    {0xa7aeU, {0x26aU, 0x0U, 0x0U}, 1U},
    {0xa7b0U, {0x29eU, 0x0U, 0x0U}, 1U},
    {0xa7b1U, {0x287U, 0x0U, 0x0U}, 1U},
    {0xa7b2U, {0x29dU, 0x0U, 0x0U}, 1U},
    {0xa7b3U, {0xab53U, 0x0U, 0x0U}, 1U},
    {0xa7c4U, {0xa794U, 0x0U, 0x0U}, 1U},
    {0xa7c5U, {0x282U, 0x0U, 0x0U}, 1U},
    {0xa7c6U, {0x1d8eU, 0x0U, 0x0U}, 1U},
    {0xa7d0U, {0xa7d1U, 0x0U, 0x0U}, 1U},
    {0xa7f5U, {0xa7f6U, 0x0U, 0x0U}, 1U},
};

static constexpr UnicodeRange unicode_casefold_ranges[] = {
    {0x41U, 0x5aU, 1U, 32},
    {0xc0U, 0xd6U, 1U, 32},
    {0xd8U, 0xdeU, 1U, 32},
    {0x100U, 0x12eU, 2U, 1},
    {0x132U, 0x136U, 2U, 1},
    {0x139U, 0x147U, 2U, 1},
    {0x14aU, 0x176U, 2U, 1},
    {0x179U, 0x17dU, 2U, 1},
    {0x182U, 0x184U, 2U, 1},
    {0x189U, 0x18aU, 1U, 205},
    {0x1a0U, 0x1a4U, 2U, 1},
    {0x1b1U, 0x1b2U, 1U, 217},
    {0x1b3U, 0x1b5U, 2U, 1},
    {0x1cbU, 0x1dbU, 2U, 1},
    {0x1deU, 0x1eeU, 2U, 1},
    {0x1f2U, 0x1f4U, 2U, 1},
    {0x1f8U, 0x21eU, 2U, 1},
    {0x222U, 0x232U, 2U, 1},
    {0x246U, 0x24eU, 2U, 1},
    {0x370U, 0x372U, 2U, 1},
    {0x388U, 0x38aU, 1U, 37},
    {0x38eU, 0x38fU, 1U, 63},
    {0x391U, 0x3a1U, 1U, 32},
    {0x3a3U, 0x3abU, 1U, 32},
    {0x3d8U, 0x3eeU, 2U, 1},
    {0x3fdU, 0x3ffU, 1U, -130},
    {0x400U, 0x40fU, 1U, 80},
    {0x410U, 0x42fU, 1U, 32},
    {0x460U, 0x480U, 2U, 1},
    {0x48aU, 0x4beU, 2U, 1},
    {0x4c1U, 0x4cdU, 2U, 1},
    {0x4d0U, 0x52eU, 2U, 1},
    {0x531U, 0x556U, 1U, 48},
    {0x10a0U, 0x10c5U, 1U, 7264},
    {0x13f8U, 0x13fdU, 1U, -8},
    {0x1c83U, 0x1c84U, 1U, -6210},
    {0x1c90U, 0x1cbaU, 1U, -3008},
    {0x1cbdU, 0x1cbfU, 1U, -3008},
    {0x1e00U, 0x1e94U, 2U, 1},
    {0x1ea0U, 0x1efeU, 2U, 1},
    {0x1f08U, 0x1f0fU, 1U, -8},
    {0x1f18U, 0x1f1dU, 1U, -8},
    {0x1f28U, 0x1f2fU, 1U, -8},
    {0x1f38U, 0x1f3fU, 1U, -8},
    {0x1f48U, 0x1f4dU, 1U, -8},
    {0x1f59U, 0x1f5fU, 2U, -8},
    {0x1f68U, 0x1f6fU, 1U, -8},
    {0x1fb8U, 0x1fb9U, 1U, -8},
    {0x1fbaU, 0x1fbbU, 1U, -74},
    {0x1fc8U, 0x1fcbU, 1U, -86},
    {0x1fd8U, 0x1fd9U, 1U, -8},
    {0x1fdaU, 0x1fdbU, 1U, -100},
    {0x1fe8U, 0x1fe9U, 1U, -8},
    {0x1feaU, 0x1febU, 1U, -112},
    {0x1ff8U, 0x1ff9U, 1U, -128},
    {0x1ffaU, 0x1ffbU, 1U, -126},
    {0x2160U, 0x216fU, 1U, 16},
    {0x24b6U, 0x24cfU, 1U, 26},
    {0x2c00U, 0x2c2fU, 1U, 48},
    {0x2c67U, 0x2c6bU, 2U, 1},
    {0x2c7eU, 0x2c7fU, 1U, -10815},
    {0x2c80U, 0x2ce2U, 2U, 1},
    {0x2cebU, 0x2cedU, 2U, 1},
    {0xa640U, 0xa66cU, 2U, 1},
    {0xa680U, 0xa69aU, 2U, 1},
    {0xa722U, 0xa72eU, 2U, 1},
    {0xa732U, 0xa76eU, 2U, 1},
    {0xa779U, 0xa77bU, 2U, 1},
    {0xa77eU, 0xa786U, 2U, 1},
    {0xa790U, 0xa792U, 2U, 1},
    {0xa796U, 0xa7a8U, 2U, 1},
    {0xa7b4U, 0xa7c2U, 2U, 1},
    {0xa7c7U, 0xa7c9U, 2U, 1},
    {0xa7d6U, 0xa7d8U, 2U, 1},
    {0xab70U, 0xabbfU, 1U, -38864},
    {0xff21U, 0xff3aU, 1U, 32},
    {0x10400U, 0x10427U, 1U, 40},
    {0x104b0U, 0x104d3U, 1U, 40},
    {0x10570U, 0x1057aU, 1U, 39},
    {0x1057cU, 0x1058aU, 1U, 39},
    {0x1058cU, 0x10592U, 1U, 39},
    {0x10594U, 0x10595U, 1U, 39},
    {0x10c80U, 0x10cb2U, 1U, 64},
    {0x118a0U, 0x118bfU, 1U, 32},
    {0x16e40U, 0x16e5fU, 1U, 32},
    {0x1e900U, 0x1e921U, 1U, 34},
};

static constexpr UnicodeMapping unicode_casefold_mappings[] = {
    {0xb5U, {0x3bcU, 0x0U, 0x0U}, 1U},
    {0xdfU, {0x73U, 0x73U, 0x0U}, 2U},
    {0x130U, {0x69U, 0x307U, 0x0U}, 2U},
    {0x149U, {0x2bcU, 0x6eU, 0x0U}, 2U},
    {0x178U, {0xffU, 0x0U, 0x0U}, 1U},
    {0x17fU, {0x73U, 0x0U, 0x0U}, 1U},
    {0x181U, {0x253U, 0x0U, 0x0U}, 1U},
    {0x186U, {0x254U, 0x0U, 0x0U}, 1U},
    {0x187U, {0x188U, 0x0U, 0x0U}, 1U},
    {0x18bU, {0x18cU, 0x0U, 0x0U}, 1U},
    {0x18eU, {0x1ddU, 0x0U, 0x0U}, 1U},
    {0x18fU, {0x259U, 0x0U, 0x0U}, 1U},
    {0x190U, {0x25bU, 0x0U, 0x0U}, 1U},
    {0x191U, {0x192U, 0x0U, 0x0U}, 1U},
    {0x193U, {0x260U, 0x0U, 0x0U}, 1U},
    {0x194U, {0x263U, 0x0U, 0x0U}, 1U},
    {0x196U, {0x269U, 0x0U, 0x0U}, 1U},
    {0x197U, {0x268U, 0x0U, 0x0U}, 1U},
    {0x198U, {0x199U, 0x0U, 0x0U}, 1U},
    {0x19cU, {0x26fU, 0x0U, 0x0U}, 1U},
    {0x19dU, {0x272U, 0x0U, 0x0U}, 1U},
    {0x19fU, {0x275U, 0x0U, 0x0U}, 1U},
    {0x1a6U, {0x280U, 0x0U, 0x0U}, 1U},
    {0x1a7U, {0x1a8U, 0x0U, 0x0U}, 1U},
    {0x1a9U, {0x283U, 0x0U, 0x0U}, 1U},
    {0x1acU, {0x1adU, 0x0U, 0x0U}, 1U},
    {0x1aeU, {0x288U, 0x0U, 0x0U}, 1U},
    {0x1afU, {0x1b0U, 0x0U, 0x0U}, 1U},
    {0x1b7U, {0x292U, 0x0U, 0x0U}, 1U},
    {0x1b8U, {0x1b9U, 0x0U, 0x0U}, 1U},
    {0x1bcU, {0x1bdU, 0x0U, 0x0U}, 1U},
    {0x1c4U, {0x1c6U, 0x0U, 0x0U}, 1U},
    {0x1c5U, {0x1c6U, 0x0U, 0x0U}, 1U},
    {0x1c7U, {0x1c9U, 0x0U, 0x0U}, 1U},
    {0x1c8U, {0x1c9U, 0x0U, 0x0U}, 1U},
    {0x1caU, {0x1ccU, 0x0U, 0x0U}, 1U},
    {0x1f0U, {0x6aU, 0x30cU, 0x0U}, 2U},
    {0x1f1U, {0x1f3U, 0x0U, 0x0U}, 1U},
    {0x1f6U, {0x195U, 0x0U, 0x0U}, 1U},
    {0x1f7U, {0x1bfU, 0x0U, 0x0U}, 1U},
    {0x220U, {0x19eU, 0x0U, 0x0U}, 1U},
    {0x23aU, {0x2c65U, 0x0U, 0x0U}, 1U},
    {0x23bU, {0x23cU, 0x0U, 0x0U}, 1U},
    {0x23dU, {0x19aU, 0x0U, 0x0U}, 1U},
    {0x23eU, {0x2c66U, 0x0U, 0x0U}, 1U},
    {0x241U, {0x242U, 0x0U, 0x0U}, 1U},
    {0x243U, {0x180U, 0x0U, 0x0U}, 1U},
    {0x244U, {0x289U, 0x0U, 0x0U}, 1U},
    {0x245U, {0x28cU, 0x0U, 0x0U}, 1U},
    {0x345U, {0x3b9U, 0x0U, 0x0U}, 1U},
    {0x376U, {0x377U, 0x0U, 0x0U}, 1U},
    {0x37fU, {0x3f3U, 0x0U, 0x0U}, 1U},
    {0x386U, {0x3acU, 0x0U, 0x0U}, 1U},
    {0x38cU, {0x3ccU, 0x0U, 0x0U}, 1U},
    {0x390U, {0x3b9U, 0x308U, 0x301U}, 3U},
    {0x3b0U, {0x3c5U, 0x308U, 0x301U}, 3U},
    {0x3c2U, {0x3c3U, 0x0U, 0x0U}, 1U},
    {0x3cfU, {0x3d7U, 0x0U, 0x0U}, 1U},
    {0x3d0U, {0x3b2U, 0x0U, 0x0U}, 1U},
    {0x3d1U, {0x3b8U, 0x0U, 0x0U}, 1U},
    {0x3d5U, {0x3c6U, 0x0U, 0x0U}, 1U},
    {0x3d6U, {0x3c0U, 0x0U, 0x0U}, 1U},
    {0x3f0U, {0x3baU, 0x0U, 0x0U}, 1U},
    {0x3f1U, {0x3c1U, 0x0U, 0x0U}, 1U},
    {0x3f4U, {0x3b8U, 0x0U, 0x0U}, 1U},
    {0x3f5U, {0x3b5U, 0x0U, 0x0U}, 1U},
    {0x3f7U, {0x3f8U, 0x0U, 0x0U}, 1U},
    {0x3f9U, {0x3f2U, 0x0U, 0x0U}, 1U},
    {0x3faU, {0x3fbU, 0x0U, 0x0U}, 1U},
    {0x4c0U, {0x4cfU, 0x0U, 0x0U}, 1U},
    {0x587U, {0x565U, 0x582U, 0x0U}, 2U},
    {0x10c7U, {0x2d27U, 0x0U, 0x0U}, 1U},
    {0x10cdU, {0x2d2dU, 0x0U, 0x0U}, 1U},
    {0x1c80U, {0x432U, 0x0U, 0x0U}, 1U},
    {0x1c81U, {0x434U, 0x0U, 0x0U}, 1U},
    {0x1c82U, {0x43eU, 0x0U, 0x0U}, 1U},
    {0x1c85U, {0x442U, 0x0U, 0x0U}, 1U},
    {0x1c86U, {0x44aU, 0x0U, 0x0U}, 1U},
    {0x1c87U, {0x463U, 0x0U, 0x0U}, 1U},
    {0x1c88U, {0xa64bU, 0x0U, 0x0U}, 1U},
    {0x1e96U, {0x68U, 0x331U, 0x0U}, 2U},
    {0x1e97U, {0x74U, 0x308U, 0x0U}, 2U},
    {0x1e98U, {0x77U, 0x30aU, 0x0U}, 2U},
    {0x1e99U, {0x79U, 0x30aU, 0x0U}, 2U},
    {0x1e9aU, {0x61U, 0x2beU, 0x0U}, 2U},
    {0x1e9bU, {0x1e61U, 0x0U, 0x0U}, 1U},
    {0x1e9eU, {0x73U, 0x73U, 0x0U}, 2U},
    {0x1f50U, {0x3c5U, 0x313U, 0x0U}, 2U},
    {0x1f52U, {0x3c5U, 0x313U, 0x300U}, 3U},
    {0x1f54U, {0x3c5U, 0x313U, 0x301U}, 3U},
    {0x1f56U, {0x3c5U, 0x313U, 0x342U}, 3U},
    {0x1f80U, {0x1f00U, 0x3b9U, 0x0U}, 2U},
    {0x1f81U, {0x1f01U, 0x3b9U, 0x0U}, 2U},
    {0x1f82U, {0x1f02U, 0x3b9U, 0x0U}, 2U},
    {0x1f83U, {0x1f03U, 0x3b9U, 0x0U}, 2U},
    {0x1f84U, {0x1f04U, 0x3b9U, 0x0U}, 2U},
    {0x1f85U, {0x1f05U, 0x3b9U, 0x0U}, 2U},
    {0x1f86U, {0x1f06U, 0x3b9U, 0x0U}, 2U},
    {0x1f87U, {0x1f07U, 0x3b9U, 0x0U}, 2U},
    {0x1f88U, {0x1f00U, 0x3b9U, 0x0U}, 2U},
    {0x1f89U, {0x1f01U, 0x3b9U, 0x0U}, 2U},
    {0x1f8aU, {0x1f02U, 0x3b9U, 0x0U}, 2U},
    {0x1f8bU, {0x1f03U, 0x3b9U, 0x0U}, 2U},
    {0x1f8cU, {0x1f04U, 0x3b9U, 0x0U}, 2U},
    {0x1f8dU, {0x1f05U, 0x3b9U, 0x0U}, 2U},
    {0x1f8eU, {0x1f06U, 0x3b9U, 0x0U}, 2U},
    {0x1f8fU, {0x1f07U, 0x3b9U, 0x0U}, 2U},
    {0x1f90U, {0x1f20U, 0x3b9U, 0x0U}, 2U},
    {0x1f91U, {0x1f21U, 0x3b9U, 0x0U}, 2U},
    {0x1f92U, {0x1f22U, 0x3b9U, 0x0U}, 2U},
    {0x1f93U, {0x1f23U, 0x3b9U, 0x0U}, 2U},
    {0x1f94U, {0x1f24U, 0x3b9U, 0x0U}, 2U},
    {0x1f95U, {0x1f25U, 0x3b9U, 0x0U}, 2U},
    {0x1f96U, {0x1f26U, 0x3b9U, 0x0U}, 2U},
    {0x1f97U, {0x1f27U, 0x3b9U, 0x0U}, 2U},
    {0x1f98U, {0x1f20U, 0x3b9U, 0x0U}, 2U},
    {0x1f99U, {0x1f21U, 0x3b9U, 0x0U}, 2U},
    {0x1f9aU, {0x1f22U, 0x3b9U, 0x0U}, 2U},
    {0x1f9bU, {0x1f23U, 0x3b9U, 0x0U}, 2U},
    {0x1f9cU, {0x1f24U, 0x3b9U, 0x0U}, 2U},
    {0x1f9dU, {0x1f25U, 0x3b9U, 0x0U}, 2U},
    {0x1f9eU, {0x1f26U, 0x3b9U, 0x0U}, 2U},
    {0x1f9fU, {0x1f27U, 0x3b9U, 0x0U}, 2U},
    {0x1fa0U, {0x1f60U, 0x3b9U, 0x0U}, 2U},
    {0x1fa1U, {0x1f61U, 0x3b9U, 0x0U}, 2U},
    {0x1fa2U, {0x1f62U, 0x3b9U, 0x0U}, 2U},
    {0x1fa3U, {0x1f63U, 0x3b9U, 0x0U}, 2U},
    {0x1fa4U, {0x1f64U, 0x3b9U, 0x0U}, 2U},
    {0x1fa5U, {0x1f65U, 0x3b9U, 0x0U}, 2U},
    {0x1fa6U, {0x1f66U, 0x3b9U, 0x0U}, 2U},
    {0x1fa7U, {0x1f67U, 0x3b9U, 0x0U}, 2U},
    {0x1fa8U, {0x1f60U, 0x3b9U, 0x0U}, 2U},
    {0x1fa9U, {0x1f61U, 0x3b9U, 0x0U}, 2U},
    {0x1faaU, {0x1f62U, 0x3b9U, 0x0U}, 2U},
    {0x1fabU, {0x1f63U, 0x3b9U, 0x0U}, 2U},
    {0x1facU, {0x1f64U, 0x3b9U, 0x0U}, 2U},
    {0x1fadU, {0x1f65U, 0x3b9U, 0x0U}, 2U},
    {0x1faeU, {0x1f66U, 0x3b9U, 0x0U}, 2U},
    {0x1fafU, {0x1f67U, 0x3b9U, 0x0U}, 2U},
    {0x1fb2U, {0x1f70U, 0x3b9U, 0x0U}, 2U},
    {0x1fb3U, {0x3b1U, 0x3b9U, 0x0U}, 2U},
    {0x1fb4U, {0x3acU, 0x3b9U, 0x0U}, 2U},
    {0x1fb6U, {0x3b1U, 0x342U, 0x0U}, 2U},
    {0x1fb7U, {0x3b1U, 0x342U, 0x3b9U}, 3U},
    {0x1fbcU, {0x3b1U, 0x3b9U, 0x0U}, 2U},
    {0x1fbeU, {0x3b9U, 0x0U, 0x0U}, 1U},
    {0x1fc2U, {0x1f74U, 0x3b9U, 0x0U}, 2U},
    {0x1fc3U, {0x3b7U, 0x3b9U, 0x0U}, 2U},
    {0x1fc4U, {0x3aeU, 0x3b9U, 0x0U}, 2U},
    {0x1fc6U, {0x3b7U, 0x342U, 0x0U}, 2U},
    {0x1fc7U, {0x3b7U, 0x342U, 0x3b9U}, 3U},
    {0x1fccU, {0x3b7U, 0x3b9U, 0x0U}, 2U},
    {0x1fd2U, {0x3b9U, 0x308U, 0x300U}, 3U},
    {0x1fd3U, {0x3b9U, 0x308U, 0x301U}, 3U},
    {0x1fd6U, {0x3b9U, 0x342U, 0x0U}, 2U},
    {0x1fd7U, {0x3b9U, 0x308U, 0x342U}, 3U},
    {0x1fe2U, {0x3c5U, 0x308U, 0x300U}, 3U},
    {0x1fe3U, {0x3c5U, 0x308U, 0x301U}, 3U},
    {0x1fe4U, {0x3c1U, 0x313U, 0x0U}, 2U},
    {0x1fe6U, {0x3c5U, 0x342U, 0x0U}, 2U},
    {0x1fe7U, {0x3c5U, 0x308U, 0x342U}, 3U},
    {0x1fecU, {0x1fe5U, 0x0U, 0x0U}, 1U},
    {0x1ff2U, {0x1f7cU, 0x3b9U, 0x0U}, 2U},
    {0x1ff3U, {0x3c9U, 0x3b9U, 0x0U}, 2U},
    {0x1ff4U, {0x3ceU, 0x3b9U, 0x0U}, 2U},
    {0x1ff6U, {0x3c9U, 0x342U, 0x0U}, 2U},
    {0x1ff7U, {0x3c9U, 0x342U, 0x3b9U}, 3U},
    {0x1ffcU, {0x3c9U, 0x3b9U, 0x0U}, 2U},
    {0x2126U, {0x3c9U, 0x0U, 0x0U}, 1U},
    {0x212aU, {0x6bU, 0x0U, 0x0U}, 1U},
    {0x212bU, {0xe5U, 0x0U, 0x0U}, 1U},
    {0x2132U, {0x214eU, 0x0U, 0x0U}, 1U},
    {0x2183U, {0x2184U, 0x0U, 0x0U}, 1U},
    {0x2c60U, {0x2c61U, 0x0U, 0x0U}, 1U},
    {0x2c62U, {0x26bU, 0x0U, 0x0U}, 1U},
    {0x2c63U, {0x1d7dU, 0x0U, 0x0U}, 1U},
    {0x2c64U, {0x27dU, 0x0U, 0x0U}, 1U},
    {0x2c6dU, {0x251U, 0x0U, 0x0U}, 1U},
    {0x2c6eU, {0x271U, 0x0U, 0x0U}, 1U},
    {0x2c6fU, {0x250U, 0x0U, 0x0U}, 1U},
    {0x2c70U, {0x252U, 0x0U, 0x0U}, 1U},
    {0x2c72U, {0x2c73U, 0x0U, 0x0U}, 1U},
    {0x2c75U, {0x2c76U, 0x0U, 0x0U}, 1U},
    {0x2cf2U, {0x2cf3U, 0x0U, 0x0U}, 1U},
    {0xa77dU, {0x1d79U, 0x0U, 0x0U}, 1U},
    {0xa78bU, {0xa78cU, 0x0U, 0x0U}, 1U},
    {0xa78dU, {0x265U, 0x0U, 0x0U}, 1U},
    {0xa7aaU, {0x266U, 0x0U, 0x0U}, 1U},
    {0xa7abU, {0x25cU, 0x0U, 0x0U}, 1U},
    {0xa7acU, {0x261U, 0x0U, 0x0U}, 1U},
    {0xa7adU, {0x26cU, 0x0U, 0x0U}, 1U},
    {0xa7aeU, {0x26aU, 0x0U, 0x0U}, 1U},
    {0xa7b0U, {0x29eU, 0x0U, 0x0U}, 1U},
    {0xa7b1U, {0x287U, 0x0U, 0x0U}, 1U},
    {0xa7b2U, {0x29dU, 0x0U, 0x0U}, 1U},
    {0xa7b3U, {0xab53U, 0x0U, 0x0U}, 1U},
    {0xa7c4U, {0xa794U, 0x0U, 0x0U}, 1U},
    {0xa7c5U, {0x282U, 0x0U, 0x0U}, 1U},
    {0xa7c6U, {0x1d8eU, 0x0U, 0x0U}, 1U},
    {0xa7d0U, {0xa7d1U, 0x0U, 0x0U}, 1U},
    {0xa7f5U, {0xa7f6U, 0x0U, 0x0U}, 1U},
    {0xfb00U, {0x66U, 0x66U, 0x0U}, 2U},
    {0xfb01U, {0x66U, 0x69U, 0x0U}, 2U},
    {0xfb02U, {0x66U, 0x6cU, 0x0U}, 2U},
    {0xfb03U, {0x66U, 0x66U, 0x69U}, 3U},
    {0xfb04U, {0x66U, 0x66U, 0x6cU}, 3U},
    {0xfb05U, {0x73U, 0x74U, 0x0U}, 2U},
    {0xfb06U, {0x73U, 0x74U, 0x0U}, 2U},
    {0xfb13U, {0x574U, 0x576U, 0x0U}, 2U},
    {0xfb14U, {0x574U, 0x565U, 0x0U}, 2U},
    {0xfb15U, {0x574U, 0x56bU, 0x0U}, 2U},
    {0xfb16U, {0x57eU, 0x576U, 0x0U}, 2U},
    {0xfb17U, {0x574U, 0x56dU, 0x0U}, 2U},
};

struct UnicodePropertyRange {
    std::uint32_t first;
    std::uint32_t last;
};

static constexpr UnicodePropertyRange unicode_cased_ranges[] = {
    {0x41U, 0x5aU},
    {0x61U, 0x7aU},
    {0xaaU, 0xaaU},
    {0xb5U, 0xb5U},
    {0xbaU, 0xbaU},
    {0xc0U, 0xd6U},
    {0xd8U, 0xf6U},
    {0xf8U, 0x1baU},
    {0x1bcU, 0x1bfU},
    {0x1c4U, 0x293U},
    {0x295U, 0x2afU},
    {0x370U, 0x373U},
    {0x376U, 0x377U},
    {0x37bU, 0x37dU},
    {0x37fU, 0x37fU},
    {0x386U, 0x386U},
    {0x388U, 0x38aU},
    {0x38cU, 0x38cU},
    {0x38eU, 0x3a1U},
    {0x3a3U, 0x3f5U},
    {0x3f7U, 0x481U},
    {0x48aU, 0x52fU},
    {0x531U, 0x556U},
    {0x560U, 0x588U},
    {0x10a0U, 0x10c5U},
    {0x10c7U, 0x10c7U},
    {0x10cdU, 0x10cdU},
    {0x10d0U, 0x10faU},
    {0x10fdU, 0x10ffU},
    {0x13a0U, 0x13f5U},
    {0x13f8U, 0x13fdU},
    {0x1c80U, 0x1c88U},
    {0x1c90U, 0x1cbaU},
    {0x1cbdU, 0x1cbfU},
    {0x1d00U, 0x1d2bU},
    {0x1d6bU, 0x1d77U},
    {0x1d79U, 0x1d9aU},
    {0x1e00U, 0x1f15U},
    {0x1f18U, 0x1f1dU},
    {0x1f20U, 0x1f45U},
    {0x1f48U, 0x1f4dU},
    {0x1f50U, 0x1f57U},
    {0x1f59U, 0x1f59U},
    {0x1f5bU, 0x1f5bU},
    {0x1f5dU, 0x1f5dU},
    {0x1f5fU, 0x1f7dU},
    {0x1f80U, 0x1fb4U},
    {0x1fb6U, 0x1fbcU},
    {0x1fbeU, 0x1fbeU},
    {0x1fc2U, 0x1fc4U},
    {0x1fc6U, 0x1fccU},
    {0x1fd0U, 0x1fd3U},
    {0x1fd6U, 0x1fdbU},
    {0x1fe0U, 0x1fecU},
    {0x1ff2U, 0x1ff4U},
    {0x1ff6U, 0x1ffcU},
    {0x2102U, 0x2102U},
    {0x2107U, 0x2107U},
    {0x210aU, 0x2113U},
    {0x2115U, 0x2115U},
    {0x2119U, 0x211dU},
    {0x2124U, 0x2124U},
    {0x2126U, 0x2126U},
    {0x2128U, 0x2128U},
    {0x212aU, 0x212dU},
    {0x212fU, 0x2134U},
    {0x2139U, 0x2139U},
    {0x213cU, 0x213fU},
    {0x2145U, 0x2149U},
    {0x214eU, 0x214eU},
    {0x2160U, 0x217fU},
    {0x2183U, 0x2184U},
    {0x24b6U, 0x24e9U},
    {0x2c00U, 0x2c7bU},
    {0x2c7eU, 0x2ce4U},
    {0x2cebU, 0x2ceeU},
    {0x2cf2U, 0x2cf3U},
    {0x2d00U, 0x2d25U},
    {0x2d27U, 0x2d27U},
    {0x2d2dU, 0x2d2dU},
    {0xa640U, 0xa66dU},
    {0xa680U, 0xa69bU},
    {0xa722U, 0xa76fU},
    {0xa771U, 0xa787U},
    {0xa78bU, 0xa78eU},
    {0xa790U, 0xa7caU},
    {0xa7d0U, 0xa7d1U},
    {0xa7d3U, 0xa7d3U},
    {0xa7d5U, 0xa7d9U},
    {0xa7f5U, 0xa7f6U},
    {0xa7faU, 0xa7faU},
    {0xab30U, 0xab5aU},
    {0xab60U, 0xab68U},
    {0xab70U, 0xabbfU},
    {0xfb00U, 0xfb06U},
    {0xfb13U, 0xfb17U},
    {0xff21U, 0xff3aU},
    {0xff41U, 0xff5aU},
    {0x10400U, 0x1044fU},
    {0x104b0U, 0x104d3U},
    {0x104d8U, 0x104fbU},
    {0x10570U, 0x1057aU},
    {0x1057cU, 0x1058aU},
    {0x1058cU, 0x10592U},
    {0x10594U, 0x10595U},
    {0x10597U, 0x105a1U},
    {0x105a3U, 0x105b1U},
    {0x105b3U, 0x105b9U},
    {0x105bbU, 0x105bcU},
    {0x10c80U, 0x10cb2U},
    {0x10cc0U, 0x10cf2U},
    {0x118a0U, 0x118dfU},
    {0x16e40U, 0x16e7fU},
    {0x1d400U, 0x1d454U},
    {0x1d456U, 0x1d49cU},
    {0x1d49eU, 0x1d49fU},
    {0x1d4a2U, 0x1d4a2U},
    {0x1d4a5U, 0x1d4a6U},
    {0x1d4a9U, 0x1d4acU},
    {0x1d4aeU, 0x1d4b9U},
    {0x1d4bbU, 0x1d4bbU},
    {0x1d4bdU, 0x1d4c3U},
    {0x1d4c5U, 0x1d505U},
    {0x1d507U, 0x1d50aU},
    {0x1d50dU, 0x1d514U},
    {0x1d516U, 0x1d51cU},
    {0x1d51eU, 0x1d539U},
    {0x1d53bU, 0x1d53eU},
    {0x1d540U, 0x1d544U},
    {0x1d546U, 0x1d546U},
    {0x1d54aU, 0x1d550U},
    {0x1d552U, 0x1d6a5U},
    {0x1d6a8U, 0x1d6c0U},
    {0x1d6c2U, 0x1d6daU},
    {0x1d6dcU, 0x1d6faU},
    {0x1d6fcU, 0x1d714U},
    {0x1d716U, 0x1d734U},
    {0x1d736U, 0x1d74eU},
    {0x1d750U, 0x1d76eU},
    {0x1d770U, 0x1d788U},
    {0x1d78aU, 0x1d7a8U},
    {0x1d7aaU, 0x1d7c2U},
    {0x1d7c4U, 0x1d7cbU},
    {0x1df00U, 0x1df09U},
    {0x1df0bU, 0x1df1eU},
    {0x1df25U, 0x1df2aU},
    {0x1e900U, 0x1e943U},
    {0x1f130U, 0x1f149U},
    {0x1f150U, 0x1f169U},
    {0x1f170U, 0x1f189U},
};

static constexpr UnicodePropertyRange unicode_case_ignorable_ranges[] = {
    {0x27U, 0x27U},
    {0x2eU, 0x2eU},
    {0x3aU, 0x3aU},
    {0x5eU, 0x5eU},
    {0x60U, 0x60U},
    {0xa8U, 0xa8U},
    {0xadU, 0xadU},
    {0xafU, 0xafU},
    {0xb4U, 0xb4U},
    {0xb7U, 0xb8U},
    {0x2b0U, 0x36fU},
    {0x374U, 0x375U},
    {0x37aU, 0x37aU},
    {0x384U, 0x385U},
    {0x387U, 0x387U},
    {0x483U, 0x489U},
    {0x559U, 0x559U},
    {0x55fU, 0x55fU},
    {0x591U, 0x5bdU},
    {0x5bfU, 0x5bfU},
    {0x5c1U, 0x5c2U},
    {0x5c4U, 0x5c5U},
    {0x5c7U, 0x5c7U},
    {0x5f4U, 0x5f4U},
    {0x600U, 0x605U},
    {0x610U, 0x61aU},
    {0x61cU, 0x61cU},
    {0x640U, 0x640U},
    {0x64bU, 0x65fU},
    {0x670U, 0x670U},
    {0x6d6U, 0x6ddU},
    {0x6dfU, 0x6e8U},
    {0x6eaU, 0x6edU},
    {0x70fU, 0x70fU},
    {0x711U, 0x711U},
    {0x730U, 0x74aU},
    {0x7a6U, 0x7b0U},
    {0x7ebU, 0x7f5U},
    {0x7faU, 0x7faU},
    {0x7fdU, 0x7fdU},
    {0x816U, 0x82dU},
    {0x859U, 0x85bU},
    {0x888U, 0x888U},
    {0x890U, 0x891U},
    {0x898U, 0x89fU},
    {0x8c9U, 0x902U},
    {0x93aU, 0x93aU},
    {0x93cU, 0x93cU},
    {0x941U, 0x948U},
    {0x94dU, 0x94dU},
    {0x951U, 0x957U},
    {0x962U, 0x963U},
    {0x971U, 0x971U},
    {0x981U, 0x981U},
    {0x9bcU, 0x9bcU},
    {0x9c1U, 0x9c4U},
    {0x9cdU, 0x9cdU},
    {0x9e2U, 0x9e3U},
    {0x9feU, 0x9feU},
    {0xa01U, 0xa02U},
    {0xa3cU, 0xa3cU},
    {0xa41U, 0xa42U},
    {0xa47U, 0xa48U},
    {0xa4bU, 0xa4dU},
    {0xa51U, 0xa51U},
    {0xa70U, 0xa71U},
    {0xa75U, 0xa75U},
    {0xa81U, 0xa82U},
    {0xabcU, 0xabcU},
    {0xac1U, 0xac5U},
    {0xac7U, 0xac8U},
    {0xacdU, 0xacdU},
    {0xae2U, 0xae3U},
    {0xafaU, 0xaffU},
    {0xb01U, 0xb01U},
    {0xb3cU, 0xb3cU},
    {0xb3fU, 0xb3fU},
    {0xb41U, 0xb44U},
    {0xb4dU, 0xb4dU},
    {0xb55U, 0xb56U},
    {0xb62U, 0xb63U},
    {0xb82U, 0xb82U},
    {0xbc0U, 0xbc0U},
    {0xbcdU, 0xbcdU},
    {0xc00U, 0xc00U},
    {0xc04U, 0xc04U},
    {0xc3cU, 0xc3cU},
    {0xc3eU, 0xc40U},
    {0xc46U, 0xc48U},
    {0xc4aU, 0xc4dU},
    {0xc55U, 0xc56U},
    {0xc62U, 0xc63U},
    {0xc81U, 0xc81U},
    {0xcbcU, 0xcbcU},
    {0xcbfU, 0xcbfU},
    {0xcc6U, 0xcc6U},
    {0xcccU, 0xccdU},
    {0xce2U, 0xce3U},
    {0xd00U, 0xd01U},
    {0xd3bU, 0xd3cU},
    {0xd41U, 0xd44U},
    {0xd4dU, 0xd4dU},
    {0xd62U, 0xd63U},
    {0xd81U, 0xd81U},
    {0xdcaU, 0xdcaU},
    {0xdd2U, 0xdd4U},
    {0xdd6U, 0xdd6U},
    {0xe31U, 0xe31U},
    {0xe34U, 0xe3aU},
    {0xe46U, 0xe4eU},
    {0xeb1U, 0xeb1U},
    {0xeb4U, 0xebcU},
    {0xec6U, 0xec6U},
    {0xec8U, 0xeceU},
    {0xf18U, 0xf19U},
    {0xf35U, 0xf35U},
    {0xf37U, 0xf37U},
    {0xf39U, 0xf39U},
    {0xf71U, 0xf7eU},
    {0xf80U, 0xf84U},
    {0xf86U, 0xf87U},
    {0xf8dU, 0xf97U},
    {0xf99U, 0xfbcU},
    {0xfc6U, 0xfc6U},
    {0x102dU, 0x1030U},
    {0x1032U, 0x1037U},
    {0x1039U, 0x103aU},
    {0x103dU, 0x103eU},
    {0x1058U, 0x1059U},
    {0x105eU, 0x1060U},
    {0x1071U, 0x1074U},
    {0x1082U, 0x1082U},
    {0x1085U, 0x1086U},
    {0x108dU, 0x108dU},
    {0x109dU, 0x109dU},
    {0x10fcU, 0x10fcU},
    {0x135dU, 0x135fU},
    {0x1712U, 0x1714U},
    {0x1732U, 0x1733U},
    {0x1752U, 0x1753U},
    {0x1772U, 0x1773U},
    {0x17b4U, 0x17b5U},
    {0x17b7U, 0x17bdU},
    {0x17c6U, 0x17c6U},
    {0x17c9U, 0x17d3U},
    {0x17d7U, 0x17d7U},
    {0x17ddU, 0x17ddU},
    {0x180bU, 0x180fU},
    {0x1843U, 0x1843U},
    {0x1885U, 0x1886U},
    {0x18a9U, 0x18a9U},
    {0x1920U, 0x1922U},
    {0x1927U, 0x1928U},
    {0x1932U, 0x1932U},
    {0x1939U, 0x193bU},
    {0x1a17U, 0x1a18U},
    {0x1a1bU, 0x1a1bU},
    {0x1a56U, 0x1a56U},
    {0x1a58U, 0x1a5eU},
    {0x1a60U, 0x1a60U},
    {0x1a62U, 0x1a62U},
    {0x1a65U, 0x1a6cU},
    {0x1a73U, 0x1a7cU},
    {0x1a7fU, 0x1a7fU},
    {0x1aa7U, 0x1aa7U},
    {0x1ab0U, 0x1aceU},
    {0x1b00U, 0x1b03U},
    {0x1b34U, 0x1b34U},
    {0x1b36U, 0x1b3aU},
    {0x1b3cU, 0x1b3cU},
    {0x1b42U, 0x1b42U},
    {0x1b6bU, 0x1b73U},
    {0x1b80U, 0x1b81U},
    {0x1ba2U, 0x1ba5U},
    {0x1ba8U, 0x1ba9U},
    {0x1babU, 0x1badU},
    {0x1be6U, 0x1be6U},
    {0x1be8U, 0x1be9U},
    {0x1bedU, 0x1bedU},
    {0x1befU, 0x1bf1U},
    {0x1c2cU, 0x1c33U},
    {0x1c36U, 0x1c37U},
    {0x1c78U, 0x1c7dU},
    {0x1cd0U, 0x1cd2U},
    {0x1cd4U, 0x1ce0U},
    {0x1ce2U, 0x1ce8U},
    {0x1cedU, 0x1cedU},
    {0x1cf4U, 0x1cf4U},
    {0x1cf8U, 0x1cf9U},
    {0x1d2cU, 0x1d6aU},
    {0x1d78U, 0x1d78U},
    {0x1d9bU, 0x1dffU},
    {0x1fbdU, 0x1fbdU},
    {0x1fbfU, 0x1fc1U},
    {0x1fcdU, 0x1fcfU},
    {0x1fddU, 0x1fdfU},
    {0x1fedU, 0x1fefU},
    {0x1ffdU, 0x1ffeU},
    {0x200bU, 0x200fU},
    {0x2018U, 0x2019U},
    {0x2024U, 0x2024U},
    {0x2027U, 0x2027U},
    {0x202aU, 0x202eU},
    {0x2060U, 0x2064U},
    {0x2066U, 0x206fU},
    {0x2071U, 0x2071U},
    {0x207fU, 0x207fU},
    {0x2090U, 0x209cU},
    {0x20d0U, 0x20f0U},
    {0x2c7cU, 0x2c7dU},
    {0x2cefU, 0x2cf1U},
    {0x2d6fU, 0x2d6fU},
    {0x2d7fU, 0x2d7fU},
    {0x2de0U, 0x2dffU},
    {0x2e2fU, 0x2e2fU},
    {0x3005U, 0x3005U},
    {0x302aU, 0x302dU},
    {0x3031U, 0x3035U},
    {0x303bU, 0x303bU},
    {0x3099U, 0x309eU},
    {0x30fcU, 0x30feU},
    {0xa015U, 0xa015U},
    {0xa4f8U, 0xa4fdU},
    {0xa60cU, 0xa60cU},
    {0xa66fU, 0xa672U},
    {0xa674U, 0xa67dU},
    {0xa67fU, 0xa67fU},
    {0xa69cU, 0xa69fU},
    {0xa6f0U, 0xa6f1U},
    {0xa700U, 0xa721U},
    {0xa770U, 0xa770U},
    {0xa788U, 0xa78aU},
    {0xa7f2U, 0xa7f4U},
    {0xa7f8U, 0xa7f9U},
    {0xa802U, 0xa802U},
    {0xa806U, 0xa806U},
    {0xa80bU, 0xa80bU},
    {0xa825U, 0xa826U},
    {0xa82cU, 0xa82cU},
    {0xa8c4U, 0xa8c5U},
    {0xa8e0U, 0xa8f1U},
    {0xa8ffU, 0xa8ffU},
    {0xa926U, 0xa92dU},
    {0xa947U, 0xa951U},
    {0xa980U, 0xa982U},
    {0xa9b3U, 0xa9b3U},
    {0xa9b6U, 0xa9b9U},
    {0xa9bcU, 0xa9bdU},
    {0xa9cfU, 0xa9cfU},
    {0xa9e5U, 0xa9e6U},
    {0xaa29U, 0xaa2eU},
    {0xaa31U, 0xaa32U},
    {0xaa35U, 0xaa36U},
    {0xaa43U, 0xaa43U},
    {0xaa4cU, 0xaa4cU},
    {0xaa70U, 0xaa70U},
    {0xaa7cU, 0xaa7cU},
    {0xaab0U, 0xaab0U},
    {0xaab2U, 0xaab4U},
    {0xaab7U, 0xaab8U},
    {0xaabeU, 0xaabfU},
    {0xaac1U, 0xaac1U},
    {0xaaddU, 0xaaddU},
    {0xaaecU, 0xaaedU},
    {0xaaf3U, 0xaaf4U},
    {0xaaf6U, 0xaaf6U},
    {0xab5bU, 0xab5fU},
    {0xab69U, 0xab6bU},
    {0xabe5U, 0xabe5U},
    {0xabe8U, 0xabe8U},
    {0xabedU, 0xabedU},
    {0xfb1eU, 0xfb1eU},
    {0xfbb2U, 0xfbc2U},
    {0xfe00U, 0xfe0fU},
    {0xfe13U, 0xfe13U},
    {0xfe20U, 0xfe2fU},
    {0xfe52U, 0xfe52U},
    {0xfe55U, 0xfe55U},
    {0xfeffU, 0xfeffU},
    {0xff07U, 0xff07U},
    {0xff0eU, 0xff0eU},
    {0xff1aU, 0xff1aU},
    {0xff3eU, 0xff3eU},
    {0xff40U, 0xff40U},
    {0xff70U, 0xff70U},
    {0xff9eU, 0xff9fU},
    {0xffe3U, 0xffe3U},
    {0xfff9U, 0xfffbU},
    {0x101fdU, 0x101fdU},
    {0x102e0U, 0x102e0U},
    {0x10376U, 0x1037aU},
    {0x10780U, 0x10785U},
    {0x10787U, 0x107b0U},
    {0x107b2U, 0x107baU},
    {0x10a01U, 0x10a03U},
    {0x10a05U, 0x10a06U},
    {0x10a0cU, 0x10a0fU},
    {0x10a38U, 0x10a3aU},
    {0x10a3fU, 0x10a3fU},
    {0x10ae5U, 0x10ae6U},
    {0x10d24U, 0x10d27U},
    {0x10eabU, 0x10eacU},
    {0x10efdU, 0x10effU},
    {0x10f46U, 0x10f50U},
    {0x10f82U, 0x10f85U},
    {0x11001U, 0x11001U},
    {0x11038U, 0x11046U},
    {0x11070U, 0x11070U},
    {0x11073U, 0x11074U},
    {0x1107fU, 0x11081U},
    {0x110b3U, 0x110b6U},
    {0x110b9U, 0x110baU},
    {0x110bdU, 0x110bdU},
    {0x110c2U, 0x110c2U},
    {0x110cdU, 0x110cdU},
    {0x11100U, 0x11102U},
    {0x11127U, 0x1112bU},
    {0x1112dU, 0x11134U},
    {0x11173U, 0x11173U},
    {0x11180U, 0x11181U},
    {0x111b6U, 0x111beU},
    {0x111c9U, 0x111ccU},
    {0x111cfU, 0x111cfU},
    {0x1122fU, 0x11231U},
    {0x11234U, 0x11234U},
    {0x11236U, 0x11237U},
    {0x1123eU, 0x1123eU},
    {0x11241U, 0x11241U},
    {0x112dfU, 0x112dfU},
    {0x112e3U, 0x112eaU},
    {0x11300U, 0x11301U},
    {0x1133bU, 0x1133cU},
    {0x11340U, 0x11340U},
    {0x11366U, 0x1136cU},
    {0x11370U, 0x11374U},
    {0x11438U, 0x1143fU},
    {0x11442U, 0x11444U},
    {0x11446U, 0x11446U},
    {0x1145eU, 0x1145eU},
    {0x114b3U, 0x114b8U},
    {0x114baU, 0x114baU},
    {0x114bfU, 0x114c0U},
    {0x114c2U, 0x114c3U},
    {0x115b2U, 0x115b5U},
    {0x115bcU, 0x115bdU},
    {0x115bfU, 0x115c0U},
    {0x115dcU, 0x115ddU},
    {0x11633U, 0x1163aU},
    {0x1163dU, 0x1163dU},
    {0x1163fU, 0x11640U},
    {0x116abU, 0x116abU},
    {0x116adU, 0x116adU},
    {0x116b0U, 0x116b5U},
    {0x116b7U, 0x116b7U},
    {0x1171dU, 0x1171fU},
    {0x11722U, 0x11725U},
    {0x11727U, 0x1172bU},
    {0x1182fU, 0x11837U},
    {0x11839U, 0x1183aU},
    {0x1193bU, 0x1193cU},
    {0x1193eU, 0x1193eU},
    {0x11943U, 0x11943U},
    {0x119d4U, 0x119d7U},
    {0x119daU, 0x119dbU},
    {0x119e0U, 0x119e0U},
    {0x11a01U, 0x11a0aU},
    {0x11a33U, 0x11a38U},
    {0x11a3bU, 0x11a3eU},
    {0x11a47U, 0x11a47U},
    {0x11a51U, 0x11a56U},
    {0x11a59U, 0x11a5bU},
    {0x11a8aU, 0x11a96U},
    {0x11a98U, 0x11a99U},
    {0x11c30U, 0x11c36U},
    {0x11c38U, 0x11c3dU},
    {0x11c3fU, 0x11c3fU},
    {0x11c92U, 0x11ca7U},
    {0x11caaU, 0x11cb0U},
    {0x11cb2U, 0x11cb3U},
    {0x11cb5U, 0x11cb6U},
    {0x11d31U, 0x11d36U},
    {0x11d3aU, 0x11d3aU},
    {0x11d3cU, 0x11d3dU},
    {0x11d3fU, 0x11d45U},
    {0x11d47U, 0x11d47U},
    {0x11d90U, 0x11d91U},
    {0x11d95U, 0x11d95U},
    {0x11d97U, 0x11d97U},
    {0x11ef3U, 0x11ef4U},
    {0x11f00U, 0x11f01U},
    {0x11f36U, 0x11f3aU},
    {0x11f40U, 0x11f40U},
    {0x11f42U, 0x11f42U},
    {0x13430U, 0x13440U},
    {0x13447U, 0x13455U},
    {0x16af0U, 0x16af4U},
    {0x16b30U, 0x16b36U},
    {0x16b40U, 0x16b43U},
    {0x16f4fU, 0x16f4fU},
    {0x16f8fU, 0x16f9fU},
    {0x16fe0U, 0x16fe1U},
    {0x16fe3U, 0x16fe4U},
    {0x1aff0U, 0x1aff3U},
    {0x1aff5U, 0x1affbU},
    {0x1affdU, 0x1affeU},
    {0x1bc9dU, 0x1bc9eU},
    {0x1bca0U, 0x1bca3U},
    {0x1cf00U, 0x1cf2dU},
    {0x1cf30U, 0x1cf46U},
    {0x1d167U, 0x1d169U},
    {0x1d173U, 0x1d182U},
    {0x1d185U, 0x1d18bU},
    {0x1d1aaU, 0x1d1adU},
    {0x1d242U, 0x1d244U},
    {0x1da00U, 0x1da36U},
    {0x1da3bU, 0x1da6cU},
    {0x1da75U, 0x1da75U},
    {0x1da84U, 0x1da84U},
    {0x1da9bU, 0x1da9fU},
    {0x1daa1U, 0x1daafU},
    {0x1e000U, 0x1e006U},
    {0x1e008U, 0x1e018U},
    {0x1e01bU, 0x1e021U},
    {0x1e023U, 0x1e024U},
    {0x1e026U, 0x1e02aU},
    {0x1e030U, 0x1e06dU},
    {0x1e08fU, 0x1e08fU},
    {0x1e130U, 0x1e13dU},
    {0x1e2aeU, 0x1e2aeU},
    {0x1e2ecU, 0x1e2efU},
    {0x1e4ebU, 0x1e4efU},
    {0x1e8d0U, 0x1e8d6U},
    {0x1e944U, 0x1e94bU},
    {0x1f3fbU, 0x1f3ffU},
    {0xe0001U, 0xe0001U},
    {0xe0020U, 0xe007fU},
    {0xe0100U, 0xe01efU},
};

template <std::size_t Count>
bool has_unicode_property(
    std::uint32_t codepoint, const UnicodePropertyRange (&ranges)[Count]) {
    const auto found = std::lower_bound(std::begin(ranges), std::end(ranges),
        codepoint, [](const UnicodePropertyRange& range, std::uint32_t target) {
            return range.last < target;
        });
    return found != std::end(ranges) && found->first <= codepoint;
}

void append_utf8(std::string& output, std::uint32_t codepoint) {
    if (codepoint <= 0x7fU) {
        output.push_back(static_cast<char>(codepoint));
    } else if (codepoint <= 0x7ffU) {
        output.push_back(static_cast<char>(0xc0U | (codepoint >> 6U)));
        output.push_back(static_cast<char>(0x80U | (codepoint & 0x3fU)));
    } else if (codepoint <= 0xffffU) {
        output.push_back(static_cast<char>(0xe0U | (codepoint >> 12U)));
        output.push_back(static_cast<char>(0x80U | ((codepoint >> 6U) & 0x3fU)));
        output.push_back(static_cast<char>(0x80U | (codepoint & 0x3fU)));
    } else {
        output.push_back(static_cast<char>(0xf0U | (codepoint >> 18U)));
        output.push_back(static_cast<char>(0x80U | ((codepoint >> 12U) & 0x3fU)));
        output.push_back(static_cast<char>(0x80U | ((codepoint >> 6U) & 0x3fU)));
        output.push_back(static_cast<char>(0x80U | (codepoint & 0x3fU)));
    }
}

template <std::size_t RangeCount, std::size_t MappingCount>
void append_unicode_mapping(
    std::string& output,
    std::uint32_t codepoint,
    const UnicodeRange (&ranges)[RangeCount],
    const UnicodeMapping (&mappings)[MappingCount]) {
    for (const auto& range : ranges) {
        if (codepoint >= range.first && codepoint <= range.last
            && (codepoint - range.first) % range.step == 0) {
            append_utf8(output, static_cast<std::uint32_t>(
                static_cast<std::int64_t>(codepoint) + range.delta));
            return;
        }
    }
    const auto found = std::lower_bound(std::begin(mappings), std::end(mappings),
        codepoint, [](const UnicodeMapping& mapping, std::uint32_t target) {
            return mapping.source < target;
        });
    if (found == std::end(mappings) || found->source != codepoint) {
        append_utf8(output, codepoint);
        return;
    }
    for (std::size_t index = 0; index < found->size; ++index)
        append_utf8(output, found->targets[index]);
}

template <std::size_t RangeCount, std::size_t MappingCount>
std::string unicode_transform(
    const std::string& value,
    const UnicodeRange (&ranges)[RangeCount],
    const UnicodeMapping (&mappings)[MappingCount]) {
    std::string output;
    output.reserve(value.size());
    for (std::size_t position = 0; position < value.size();) {
        const auto character = decode_utf8_character(value, position);
        const auto lead = static_cast<unsigned char>(value[position]);
        if (character.length == 1 && lead >= 0x80U)
            output.push_back(value[position]);
        else
            append_unicode_mapping(output, character.value, ranges, mappings);
        position += character.length;
    }
    return output;
}

std::string python_lower(const std::string& value) {
    struct Decoded {
        std::uint32_t codepoint;
        std::size_t offset;
        std::size_t length;
        bool valid;
    };
    std::vector<Decoded> decoded;
    for (std::size_t position = 0; position < value.size();) {
        const auto character = decode_utf8_character(value, position);
        const auto lead = static_cast<unsigned char>(value[position]);
        decoded.push_back({character.value, position, character.length,
            !(character.length == 1 && lead >= 0x80U)});
        position += character.length;
    }
    std::string output;
    output.reserve(value.size());
    for (std::size_t index = 0; index < decoded.size(); ++index) {
        const auto& character = decoded[index];
        if (!character.valid) {
            output.append(value, character.offset, character.length);
            continue;
        }
        if (character.codepoint == 0x3a3U) {
            bool preceded_by_cased = false;
            for (auto previous = index; previous != 0;) {
                const auto codepoint = decoded[--previous].codepoint;
                if (has_unicode_property(
                        codepoint, unicode_case_ignorable_ranges))
                    continue;
                preceded_by_cased = has_unicode_property(
                    codepoint, unicode_cased_ranges);
                break;
            }
            bool followed_by_cased = false;
            for (auto next = index + 1; next < decoded.size(); ++next) {
                const auto codepoint = decoded[next].codepoint;
                if (has_unicode_property(
                        codepoint, unicode_case_ignorable_ranges))
                    continue;
                followed_by_cased = has_unicode_property(
                    codepoint, unicode_cased_ranges);
                break;
            }
            if (preceded_by_cased && !followed_by_cased) {
                append_utf8(output, 0x3c2U);
                continue;
            }
        }
        append_unicode_mapping(output, character.codepoint,
            unicode_lower_ranges, unicode_lower_mappings);
    }
    return output;
}

std::string python_casefold(const std::string& value) {
    return unicode_transform(value, unicode_casefold_ranges, unicode_casefold_mappings);
}

bool python_whitespace(std::uint32_t value) noexcept {
    return (value >= 0x09 && value <= 0x0d)
        || (value >= 0x1c && value <= 0x20)
        || value == 0x85 || value == 0xa0 || value == 0x1680
        || (value >= 0x2000 && value <= 0x200a)
        || value == 0x2028 || value == 0x2029 || value == 0x202f
        || value == 0x205f || value == 0x3000;
}

std::string trim_copy(const std::string& value) {
    std::size_t begin = 0;
    while (begin < value.size()) {
        const auto character = decode_utf8_character(value, begin);
        if (!python_whitespace(character.value)) break;
        begin += character.length;
    }
    std::size_t position = begin;
    std::size_t last_non_space = begin;
    while (position < value.size()) {
        const auto character = decode_utf8_character(value, position);
        position += character.length;
        if (!python_whitespace(character.value)) last_non_space = position;
    }
    return value.substr(begin, last_non_space - begin);
}

std::string rtrim_copy(const std::string& value) {
    std::size_t position = 0;
    std::size_t last_non_space = 0;
    while (position < value.size()) {
        const auto character = decode_utf8_character(value, position);
        position += character.length;
        if (!python_whitespace(character.value)) last_non_space = position;
    }
    return value.substr(0, last_non_space);
}

std::string collapse_python_whitespace(const std::string& value) {
    std::string output;
    bool pending_space = false;
    for (std::size_t position = 0; position < value.size();) {
        const auto character = decode_utf8_character(value, position);
        if (python_whitespace(character.value)) {
            pending_space = !output.empty();
        } else {
            if (pending_space) output.push_back(' ');
            pending_space = false;
            output.append(value, position, character.length);
        }
        position += character.length;
    }
    return output;
}

std::vector<std::string> normalize_extensions(const std::vector<std::string>& extensions) {
    std::vector<std::string> result;
    for (const auto& raw_extension : extensions) {
        auto extension = python_lower(trim_copy(raw_extension));
        if (extension.empty()) continue;
        if (extension.front() != '.') extension.insert(extension.begin(), '.');
        if (std::find(result.begin(), result.end(), extension) == result.end())
            result.push_back(std::move(extension));
    }
    return result;
}

std::vector<std::string> normalize_globs(const std::vector<std::string>& patterns) {
    std::vector<std::string> result;
    for (const auto& raw_pattern : patterns) {
        if (trim_copy(raw_pattern).empty()) continue;
        auto pattern = raw_pattern;
        std::replace(pattern.begin(), pattern.end(), '\\', '/');
        result.push_back(std::move(pattern));
    }
    return result;
}

std::vector<std::uint32_t> utf8_codepoints(const std::string& value) {
    std::vector<std::uint32_t> output;
    for (std::size_t position = 0; position < value.size();) {
        const auto character = decode_utf8_character(value, position);
        output.push_back(character.value);
        position += character.length;
    }
    return output;
}

struct GlobClassResult {
    bool valid = false;
    bool matched = false;
    std::size_t next_pattern_index = 0;
};

GlobClassResult glob_character_class(
    const std::vector<std::uint32_t>& pattern,
    std::size_t opening_index,
    std::uint32_t character) {
    const auto begin = opening_index + 1;
    auto close = begin;
    if (close < pattern.size() && pattern[close] == '!') ++close;
    if (close < pattern.size() && pattern[close] == ']') ++close;
    while (close < pattern.size() && pattern[close] != ']') ++close;
    if (close >= pattern.size()) return {};

    std::vector<std::vector<std::uint32_t>> chunks;
    const auto hyphen = std::find(
        pattern.begin() + static_cast<std::ptrdiff_t>(begin),
        pattern.begin() + static_cast<std::ptrdiff_t>(close), '-');
    if (hyphen == pattern.begin() + static_cast<std::ptrdiff_t>(close)) {
        chunks.emplace_back(
            pattern.begin() + static_cast<std::ptrdiff_t>(begin),
            pattern.begin() + static_cast<std::ptrdiff_t>(close));
    } else {
        auto chunk_begin = begin;
        auto search = begin
            + ((begin < close && pattern[begin] == '!') ? 2U : 1U);
        while (search < close) {
            const auto found = std::find(
                pattern.begin() + static_cast<std::ptrdiff_t>(search),
                pattern.begin() + static_cast<std::ptrdiff_t>(close), '-');
            if (found == pattern.begin() + static_cast<std::ptrdiff_t>(close)) break;
            const auto index = static_cast<std::size_t>(found - pattern.begin());
            chunks.emplace_back(
                pattern.begin() + static_cast<std::ptrdiff_t>(chunk_begin), found);
            chunk_begin = index + 1;
            search = index + 3;
        }
        if (chunk_begin < close) {
            chunks.emplace_back(
                pattern.begin() + static_cast<std::ptrdiff_t>(chunk_begin),
                pattern.begin() + static_cast<std::ptrdiff_t>(close));
        } else if (!chunks.empty()) {
            chunks.back().push_back('-');
        }

        for (auto index = chunks.size(); index > 1; --index) {
            auto& left = chunks[index - 2];
            auto& right = chunks[index - 1];
            if (!left.empty() && !right.empty() && left.back() > right.front()) {
                left.pop_back();
                left.insert(left.end(), right.begin() + 1, right.end());
                chunks.erase(chunks.begin() + static_cast<std::ptrdiff_t>(index - 1));
            }
        }
    }

    std::vector<std::uint32_t> translated;
    for (std::size_t index = 0; index < chunks.size(); ++index) {
        if (index != 0) translated.push_back('-');
        translated.insert(translated.end(), chunks[index].begin(), chunks[index].end());
    }
    if (translated.empty()) return {true, false, close + 1};
    if (translated.size() == 1 && translated.front() == '!')
        return {true, true, close + 1};

    const bool negate = translated.front() == '!';
    if (negate && !chunks.empty() && !chunks.front().empty())
        chunks.front().erase(chunks.front().begin());
    bool matched = false;
    for (const auto& chunk : chunks) {
        matched = matched || std::find(chunk.begin(), chunk.end(), character) != chunk.end();
    }
    for (std::size_t index = 1; index < chunks.size(); ++index) {
        if (!chunks[index - 1].empty() && !chunks[index].empty()) {
            const auto first = chunks[index - 1].back();
            const auto last = chunks[index].front();
            matched = matched || (first <= character && character <= last);
        }
    }
    return {true, negate ? !matched : matched, close + 1};
}

bool glob_match(const std::string& path_text, const std::string& pattern_text) {
    const auto path = utf8_codepoints(path_text);
    const auto pattern = utf8_codepoints(pattern_text);
    const auto width = pattern.size() + 1;
    std::vector<signed char> memo((path.size() + 1) * width, -1);
    std::function<bool(std::size_t, std::size_t)> match =
        [&](std::size_t path_index, std::size_t pattern_index) {
            auto& cached = memo[path_index * width + pattern_index];
            if (cached >= 0) return cached != 0;
            bool result = false;
            if (pattern_index == pattern.size()) {
                result = path_index == path.size();
            } else if (pattern[pattern_index] == '*') {
                auto next = pattern_index + 1;
                while (next < pattern.size() && pattern[next] == '*') ++next;
                for (auto index = path_index; index <= path.size(); ++index) {
                    if (match(index, next)) {
                        result = true;
                        break;
                    }
                }
            } else if (path_index < path.size()) {
                if (pattern[pattern_index] == '?') {
                    result = match(path_index + 1, pattern_index + 1);
                } else if (pattern[pattern_index] == '[') {
                    const auto character_class = glob_character_class(
                        pattern, pattern_index, path[path_index]);
                    if (character_class.valid) {
                        result = character_class.matched
                            && match(path_index + 1,
                                character_class.next_pattern_index);
                    } else {
                        result = path[path_index] == '['
                            && match(path_index + 1, pattern_index + 1);
                    }
                } else {
                    result = path[path_index] == pattern[pattern_index]
                        && match(path_index + 1, pattern_index + 1);
                }
            }
            cached = static_cast<signed char>(result ? 1 : 0);
            return result;
        };
    return match(0, 0);
}

bool matches_any(const std::string& path, const std::vector<std::string>& patterns) {
    return std::any_of(patterns.begin(), patterns.end(), [&](const std::string& pattern) {
        return glob_match(path, pattern);
    });
}

std::string source_from_relative_path(const std::string& relative_path) {
    const auto slash = relative_path.find('/');
    const auto first = relative_path.substr(0, slash);
    if ((first == "github" || first == "notebookarchive") && slash != std::string::npos) {
        const auto second_slash = relative_path.find('/', slash + 1);
        return relative_path.substr(0, second_slash);
    }
    return first;
}

// CPython's random.Random is deliberately reproduced here instead of using
// std::mt19937: the engines share the MT19937 recurrence, but their integer
// seeding and bounded-integer sampling contracts are different.  Corpus
// sampling is persisted in validation reports, so the order is part of the
// compatibility surface.
class PythonRandom {
public:
    explicit PythonRandom(const mpz_class& seed) { seed_integer(seed); }

    std::uint64_t randbelow(std::uint64_t bound) {
        if (bound == 0) return 0;
        unsigned bits = 0;
        for (auto value = bound; value != 0; value >>= 1U) ++bits;
        while (true) {
            const auto value = getrandbits(bits);
            if (value < bound) return value;
        }
    }

private:
    static constexpr std::size_t state_size = 624;
    static constexpr std::size_t state_period = 397;
    std::array<std::uint32_t, state_size> state_{};
    std::size_t index_ = state_size;

    void init_genrand(std::uint32_t seed) {
        state_[0] = seed;
        for (std::size_t index = 1; index < state_size; ++index) {
            state_[index] = 1812433253U
                    * (state_[index - 1] ^ (state_[index - 1] >> 30U))
                + static_cast<std::uint32_t>(index);
        }
        index_ = state_size;
    }

    void seed_integer(const mpz_class& seed) {
        auto magnitude = seed < 0 ? -seed : seed;
        std::vector<std::uint32_t> key;
        do {
            key.push_back(static_cast<std::uint32_t>(magnitude.get_ui()));
            magnitude >>= 32;
        } while (magnitude != 0);
        const auto key_size = key.size();
        init_genrand(19650218U);
        std::size_t state_index = 1;
        std::size_t key_index = 0;
        for (std::size_t remaining = std::max(state_size, key_size);
             remaining != 0; --remaining) {
            state_[state_index] =
                (state_[state_index]
                    ^ ((state_[state_index - 1]
                           ^ (state_[state_index - 1] >> 30U))
                        * 1664525U))
                + key[key_index] + static_cast<std::uint32_t>(key_index);
            ++state_index;
            ++key_index;
            if (state_index >= state_size) {
                state_[0] = state_[state_size - 1];
                state_index = 1;
            }
            if (key_index >= key_size) key_index = 0;
        }
        for (std::size_t remaining = state_size - 1; remaining != 0; --remaining) {
            state_[state_index] =
                (state_[state_index]
                    ^ ((state_[state_index - 1]
                           ^ (state_[state_index - 1] >> 30U))
                        * 1566083941U))
                - static_cast<std::uint32_t>(state_index);
            ++state_index;
            if (state_index >= state_size) {
                state_[0] = state_[state_size - 1];
                state_index = 1;
            }
        }
        state_[0] = 0x80000000U;
        index_ = state_size;
    }

    std::uint32_t next_uint32() {
        if (index_ >= state_size) {
            constexpr std::uint32_t upper_mask = 0x80000000U;
            constexpr std::uint32_t lower_mask = 0x7fffffffU;
            constexpr std::uint32_t matrix_a = 0x9908b0dfU;
            for (std::size_t index = 0; index < state_size; ++index) {
                const auto value = (state_[index] & upper_mask)
                    | (state_[(index + 1) % state_size] & lower_mask);
                state_[index] = state_[(index + state_period) % state_size]
                    ^ (value >> 1U) ^ ((value & 1U) != 0 ? matrix_a : 0U);
            }
            index_ = 0;
        }
        auto value = state_[index_++];
        value ^= value >> 11U;
        value ^= (value << 7U) & 0x9d2c5680U;
        value ^= (value << 15U) & 0xefc60000U;
        value ^= value >> 18U;
        return value;
    }

    std::uint64_t getrandbits(unsigned bits) {
        if (bits == 0) return 0;
        if (bits <= 32)
            return static_cast<std::uint64_t>(next_uint32() >> (32U - bits));
        const auto low = static_cast<std::uint64_t>(next_uint32());
        const auto high_bits = bits - 32U;
        const auto high = static_cast<std::uint64_t>(
            next_uint32() >> (32U - high_bits));
        return low | (high << 32U);
    }
};

void deterministic_shuffle(std::vector<CorpusFile>& files, const mpz_class& seed) {
    PythonRandom generator(seed);
    for (auto index = files.size(); index > 1; --index) {
        const auto target = static_cast<std::size_t>(
            generator.randbelow(static_cast<std::uint64_t>(index)));
        std::swap(files[index - 1], files[target]);
    }
}

std::string read_utf8_lossy(const fs::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) throw std::runtime_error("Could not open file: " + path_text(path));
    const std::string bytes{
        std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
    if (stream.bad()) throw std::runtime_error("Could not read file: " + path_text(path));
    return decode_utf8_lossy(bytes);
}

std::vector<std::size_t> utf8_boundaries(const std::string& value) {
    std::vector<std::size_t> result{0};
    for (std::size_t index = 0; index < value.size();) {
        const auto lead = static_cast<unsigned char>(value[index]);
        const auto width = lead < 0x80 ? 1U : lead < 0xe0 ? 2U : lead < 0xf0 ? 3U : 4U;
        index += std::min<std::size_t>(width, value.size() - index);
        result.push_back(index);
    }
    return result;
}

std::string truncate_text(const std::string& value, std::size_t limit) {
    const auto boundaries = utf8_boundaries(value);
    if (limit == 0 || boundaries.size() - 1 <= limit) return value;
    const auto keep = limit > 3 ? limit - 3 : 0;
    return rtrim_copy(value.substr(0, boundaries[keep])) + "...";
}

std::string one_line(const std::string& value, std::size_t limit) {
    return truncate_text(collapse_python_whitespace(value), limit);
}

double round_three(double value) { return std::round(value * 1000.0) / 1000.0; }

double elapsed_ms(Clock::time_point start) {
    return round_three(std::chrono::duration<double, std::milli>(Clock::now() - start).count());
}

JsonValue rate(std::size_t count, double milliseconds) {
    if (milliseconds <= 0.0) return nullptr;
    return round_three(static_cast<double>(count) / (milliseconds / 1000.0));
}

const char* form_label(ParseForm form) {
    switch (form) {
    case ParseForm::Input: return "input";
    case ParseForm::Full: return "fullform";
    case ParseForm::Standard: return "standard";
    }
    return "input";
}

JsonValue string_array(const std::vector<std::string>& values) {
    JsonValue::Array output;
    for (const auto& value : values) output.emplace_back(value);
    return output;
}

JsonValue optional_size(std::optional<std::size_t> value) {
    return value ? JsonValue(static_cast<unsigned long long>(*value)) : JsonValue(nullptr);
}

JsonValue optional_integer(const std::optional<mpz_class>& value) {
    return value ? JsonValue::number(value->get_str()) : JsonValue(nullptr);
}

mpz_class byte_count_integer(std::uintmax_t value) {
    return mpz_class(std::to_string(value), 10);
}

JsonValue counts(const std::vector<std::string>& values) {
    std::map<std::string, std::size_t> totals;
    for (const auto& value : values) ++totals[value];
    JsonValue::Object output;
    for (const auto& [key, value] : totals)
        output.emplace(key, static_cast<unsigned long long>(value));
    return output;
}

ParserAttempt failed_attempt(
    const std::string& parser,
    Clock::time_point start,
    const std::string& error_type,
    const std::string& error,
    std::size_t preview_chars) {
    return ParserAttempt::failure(
        parser, error_type, truncate_text(error, preview_chars), elapsed_ms(start));
}

std::map<std::string, ParserAttempt> parse_files_with_tungsten(
    const std::vector<CorpusFile>& files,
    ParseForm form,
    std::optional<mpz_class> max_bytes,
    std::size_t preview_chars,
    std::size_t workers) {
    std::vector<ParserAttempt> attempts(files.size());
    const auto worker_count = std::min(files.size(), std::max<std::size_t>(1, workers));
    if (worker_count <= 1) {
        for (std::size_t index = 0; index < files.size(); ++index)
            attempts[index] = parse_file_with_tungsten(
                files[index], form, max_bytes, preview_chars);
    } else {
        std::atomic<std::size_t> next{0};
        std::vector<std::thread> threads;
        threads.reserve(worker_count);
        try {
            for (std::size_t worker = 0; worker < worker_count; ++worker) {
                threads.emplace_back([&] {
                    while (true) {
                        const auto index = next.fetch_add(1);
                        if (index >= files.size()) break;
                        attempts[index] = parse_file_with_tungsten(
                            files[index], form, max_bytes, preview_chars);
                    }
                });
            }
        } catch (...) {
            for (auto& thread : threads) thread.join();
            throw;
        }
        for (auto& thread : threads) thread.join();
    }
    std::map<std::string, ParserAttempt> output;
    for (std::size_t index = 0; index < files.size(); ++index)
        output.emplace(files[index].relative_path, std::move(attempts[index]));
    return output;
}

JsonValue decode_kernel_json_string(const std::string& value) {
    auto text = trim_copy(value);
    if (text.size() >= 2 && text.front() == '"' && text.back() == '"')
        text = parse_wl_string_literal(text);
    return JsonValue::parse(text);
}

std::optional<std::string> optional_json_string(const JsonValue* value) {
    if (value == nullptr || value->is_null()) return std::nullopt;
    return value->is_string() ? std::optional<std::string>(value->as_string())
                              : std::optional<std::string>(value->dump());
}

ParserAttempt attempt_from_wolfram_payload(
    const JsonValue::Object& payload, std::size_t preview_chars) {
    const auto find = [&](const std::string& key) -> const JsonValue* {
        const auto value = payload.find(key);
        return value == payload.end() ? nullptr : &value->second;
    };
    ParserAttempt attempt;
    attempt.parser = "wolfram";
    const auto* status = find("status");
    attempt.status = status == nullptr || status->is_null()
        ? "failure" : status->is_string() ? status->as_string() : status->dump();
    const auto* elapsed = find("elapsed_ms");
    if (elapsed != nullptr) attempt.elapsed_ms = elapsed->as_double();
    attempt.error_type = optional_json_string(find("error_type"));
    if (const auto error = optional_json_string(find("error"))) {
        const auto truncated = truncate_text(*error, preview_chars);
        if (!truncated.empty()) attempt.error = truncated;
    }
    const auto* summary = find("summary");
    attempt.summary = summary != nullptr && summary->is_object()
        ? *summary : JsonValue::Object{};
    return attempt;
}

JsonValue build_run_summary(
    const fs::path& corpus_root,
    const std::vector<CorpusFile>& files,
    const std::vector<ParserCorpusResult>& results,
    const ParserCorpusOptions& options,
    double discovery_elapsed,
    double tungsten_elapsed,
    double wolfram_elapsed) {
    std::vector<std::string> extensions;
    std::vector<std::string> kinds;
    std::vector<std::string> sources;
    std::vector<std::string> outcomes;
    std::vector<std::string> tungsten_statuses;
    std::vector<std::string> wolfram_statuses;
    std::vector<std::string> tungsten_failures;
    std::vector<std::string> wolfram_failures;
    mpz_class total_bytes = 0;
    double tungsten_attempt_elapsed = 0.0;
    double wolfram_attempt_elapsed = 0.0;
    std::size_t wolfram_attempt_count = 0;
    for (const auto& file : files) {
        extensions.push_back(file.extension);
        kinds.push_back(file.kind);
        sources.push_back(file.source);
        total_bytes += byte_count_integer(file.size_bytes);
    }
    for (const auto& result : results) {
        outcomes.push_back(result.outcome);
        tungsten_statuses.push_back(result.tungsten.status);
        wolfram_statuses.push_back(result.wolfram.status);
        if (result.tungsten.status != "skipped")
            tungsten_attempt_elapsed += result.tungsten.elapsed_ms.value_or(0.0);
        if (result.wolfram.status != "skipped") {
            ++wolfram_attempt_count;
            wolfram_attempt_elapsed += result.wolfram.elapsed_ms.value_or(0.0);
        }
        if (result.tungsten.status == "failure")
            tungsten_failures.push_back(result.tungsten.error_type.value_or("Unknown"));
        if (result.wolfram.status == "failure")
            wolfram_failures.push_back(result.wolfram.error_type.value_or("Unknown"));
    }

    JsonValue::Object option_payload{
        {"extensions", string_array(normalize_extensions(options.discovery.extensions.empty()
            ? default_parser_corpus_extensions() : options.discovery.extensions))},
        {"include_globs", string_array(options.discovery.include_globs)},
        {"exclude_globs", string_array(options.discovery.exclude_globs)},
        {"max_files", optional_size(options.discovery.max_files)},
        {"max_bytes", optional_integer(options.max_bytes)},
        {"source_form", form_label(options.source_form)},
        {"compare_wolfram", options.compare_wolfram},
        {"kernel_batch_size", static_cast<unsigned long long>(options.kernel_batch_size)},
        {"tungsten_workers", static_cast<unsigned long long>(options.tungsten_workers)},
        {"preview_chars", static_cast<unsigned long long>(options.preview_chars)},
        {"shuffle", options.discovery.shuffle},
        {"seed", JsonValue::number(options.discovery.seed.get_str())},
    };
    JsonValue::Object timings{
        {"discovery_elapsed_ms", discovery_elapsed},
        {"tungsten_wall_elapsed_ms", tungsten_elapsed},
        {"wolfram_wall_elapsed_ms", wolfram_elapsed},
        {"tungsten_attempt_elapsed_ms", round_three(tungsten_attempt_elapsed)},
        {"wolfram_attempt_elapsed_ms", round_three(wolfram_attempt_elapsed)},
        {"tungsten_files_per_second_wall", rate(results.size(), tungsten_elapsed)},
        {"wolfram_files_per_second_wall", rate(wolfram_attempt_count, wolfram_elapsed)},
    };
    return JsonValue::Object{
        {"generated_utc", whole_second_utc_now()},
        {"corpus_root", path_text(absolute_path(corpus_root))},
        {"options", std::move(option_payload)},
        {"timings", std::move(timings)},
        {"file_count", static_cast<unsigned long long>(files.size())},
        {"total_bytes", JsonValue::number(total_bytes.get_str())},
        {"by_extension", counts(extensions)},
        {"by_kind", counts(kinds)},
        {"by_source", counts(sources)},
        {"outcomes", counts(outcomes)},
        {"tungsten_statuses", counts(tungsten_statuses)},
        {"wolfram_statuses", counts(wolfram_statuses)},
        {"tungsten_failure_types", counts(tungsten_failures)},
        {"wolfram_failure_types", counts(wolfram_failures)},
    };
}

std::string json_display(const JsonValue& value) {
    return value.is_string() ? value.as_string() : value.dump();
}

void append_map_lines(
    std::vector<std::string>& lines,
    const JsonValue* value,
    bool none_if_empty,
    const std::vector<std::string>* selected_keys = nullptr) {
    if (value == nullptr || !value->is_object()) {
        if (none_if_empty) lines.push_back("- None");
        return;
    }
    const auto& object = value->as_object();
    if (object.empty() && none_if_empty) {
        lines.push_back("- None");
        return;
    }
    if (selected_keys != nullptr) {
        for (const auto& key : *selected_keys) {
            const auto found = object.find(key);
            if (found != object.end())
                lines.push_back("- `" + key + "`: `" + json_display(found->second) + "`");
        }
        return;
    }
    for (const auto& [key, item] : object)
        lines.push_back("- `" + key + "`: `" + json_display(item) + "`");
}

std::string render_markdown_report(
    const JsonValue& summary, const std::vector<ParserCorpusResult>& results) {
    const auto field = [&](const std::string& key) -> const JsonValue* {
        return summary.is_object() ? summary.find(key) : nullptr;
    };
    const auto display_field = [&](const std::string& key) {
        const auto* value = field(key);
        return value == nullptr ? std::string("null") : json_display(*value);
    };
    std::vector<std::string> lines{
        "# Tungsten Parser Corpus Comparison", "",
        "- Generated UTC: `" + display_field("generated_utc") + "`",
        "- Corpus root: `" + display_field("corpus_root") + "`",
        "- Files considered: `" + display_field("file_count") + "`",
        "- Total bytes considered: `" + display_field("total_bytes") + "`",
        "", "## Outcomes", "",
    };
    append_map_lines(lines, field("outcomes"), false);
    lines.insert(lines.end(), {"", "## Tungsten Failure Types", ""});
    append_map_lines(lines, field("tungsten_failure_types"), true);
    lines.insert(lines.end(), {"", "## Timings", ""});
    const std::vector<std::string> timing_keys{
        "total_elapsed_ms", "discovery_elapsed_ms", "tungsten_wall_elapsed_ms",
        "wolfram_wall_elapsed_ms", "output_write_elapsed_ms",
        "tungsten_files_per_second_wall", "wolfram_files_per_second_wall",
    };
    append_map_lines(lines, field("timings"), true, &timing_keys);

    const auto append_results = [&](const std::string& heading,
                                    const std::string& outcome,
                                    bool use_tungsten) {
        lines.insert(lines.end(), {"", "## " + heading, ""});
        std::size_t count = 0;
        for (const auto& result : results) {
            if (result.outcome != outcome || count >= 50) continue;
            ++count;
            const auto& attempt = use_tungsten ? result.tungsten : result.wolfram;
            lines.push_back("- `" + result.file.relative_path + "` ("
                + result.file.extension + ", " + std::to_string(result.file.size_bytes)
                + " bytes): " + attempt.error_type.value_or(attempt.status));
            if (attempt.error)
                lines.push_back(std::string("  ") + (use_tungsten ? "Tungsten" : "Wolfram")
                    + ": `" + one_line(*attempt.error, 180) + "`");
        }
        if (count == 0) lines.push_back("- None in this run.");
    };
    append_results("First Wolfram-Accepted Tungsten Gaps", "tungsten_gap", true);
    append_results("First Tungsten-Accepted Wolfram Rejections",
        "tungsten_only_success", false);
    lines.push_back("");
    std::ostringstream output;
    for (std::size_t index = 0; index < lines.size(); ++index) {
        if (index != 0) output << '\n';
        output << lines[index];
    }
    return output.str();
}

void write_text(const fs::path& path, const std::string& text) {
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    if (!stream) throw ParserCorpusError(
        ParserCorpusErrorKind::Io, "Could not create output file: " + path_text(path), path);
    stream.write(text.data(), static_cast<std::streamsize>(text.size()));
    if (!stream) throw ParserCorpusError(
        ParserCorpusErrorKind::Io, "Could not write output file: " + path_text(path), path);
}

} // namespace

const std::vector<std::string>& default_parser_corpus_extensions() {
    static const std::vector<std::string> values{
        ".wl", ".m", ".wls", ".mt", ".wlt", ".nb", ".nbp"};
    return values;
}

const std::vector<std::string>& parser_corpus_notebook_extensions() {
    static const std::vector<std::string> values{".nb", ".nbp"};
    return values;
}

ParserCorpusError::ParserCorpusError(
    ParserCorpusErrorKind kind,
    std::string message,
    std::optional<fs::path> path)
    : std::runtime_error(std::move(message)), kind_(kind), path_(std::move(path)) {}

JsonValue CorpusFile::to_json_value() const {
    return JsonValue::Object{
        {"path", path_text(path)},
        {"relative_path", relative_path},
        {"extension", extension},
        {"kind", kind},
        {"source", source},
        {"size_bytes", static_cast<unsigned long long>(size_bytes)},
    };
}

ParserAttempt ParserAttempt::success(
    std::string parser, double elapsed_ms, JsonValue summary) {
    return {std::move(parser), "success", elapsed_ms, std::nullopt,
        std::nullopt, std::move(summary)};
}

ParserAttempt ParserAttempt::failure(
    std::string parser,
    std::string error_type,
    std::string error,
    std::optional<double> elapsed_ms,
    JsonValue summary) {
    return {std::move(parser), "failure", elapsed_ms, std::move(error_type),
        std::move(error), std::move(summary)};
}

ParserAttempt ParserAttempt::skipped(
    std::string parser, std::string reason, std::string message) {
    return {std::move(parser), "skipped", std::nullopt, std::move(reason),
        std::move(message), JsonValue::Object{}};
}

JsonValue ParserAttempt::to_json_value() const {
    JsonValue::Object payload{
        {"parser", parser}, {"status", status}, {"summary", summary}};
    if (elapsed_ms) payload.emplace("elapsed_ms", *elapsed_ms);
    if (error_type) payload.emplace("error_type", *error_type);
    if (error) payload.emplace("error", *error);
    return payload;
}

JsonValue ParserCorpusResult::to_json_value() const {
    return JsonValue::Object{
        {"file", file.to_json_value()},
        {"tungsten", tungsten.to_json_value()},
        {"wolfram", wolfram.to_json_value()},
        {"outcome", outcome},
    };
}

JsonValue ParserCorpusRun::to_json_value(bool include_results) const {
    JsonValue::Object outputs;
    for (const auto& [key, value] : output_files) outputs.emplace(key, value);
    JsonValue::Object payload{{"summary", summary}, {"output_files", std::move(outputs)}};
    if (include_results) {
        JsonValue::Array values;
        for (const auto& result : results) values.push_back(result.to_json_value());
        payload.emplace("results", std::move(values));
    }
    return payload;
}

std::vector<CorpusFile> discover_corpus_files(
    const fs::path& corpus_root, const CorpusDiscoveryOptions& options) {
    const auto root = absolute_path(corpus_root);
    std::error_code error;
    const auto exists = fs::exists(root, error);
    if (error) throw ParserCorpusError(ParserCorpusErrorKind::Io,
        "Could not inspect parser corpus root: " + error.message(), root);
    if (!exists)
        throw ParserCorpusError(ParserCorpusErrorKind::RootMissing,
            "Parser corpus root does not exist: " + path_text(root), root);
    const auto directory = fs::is_directory(root, error);
    if (error) throw ParserCorpusError(ParserCorpusErrorKind::Io,
        "Could not inspect parser corpus root: " + error.message(), root);
    if (!directory)
        throw ParserCorpusError(ParserCorpusErrorKind::RootNotDirectory,
            "Parser corpus root is not a directory: " + path_text(root), root);

    const auto extensions = normalize_extensions(options.extensions.empty()
        ? default_parser_corpus_extensions() : options.extensions);
    const auto includes = normalize_globs(options.include_globs);
    const auto excludes = normalize_globs(options.exclude_globs);
    std::vector<CorpusFile> files;
    fs::recursive_directory_iterator iterator(
        root, fs::directory_options::skip_permission_denied, error);
    if (error) throw ParserCorpusError(ParserCorpusErrorKind::Io,
        "Could not enumerate parser corpus root: " + error.message(), root);
    const fs::recursive_directory_iterator end;
    while (!error && iterator != end) {
        const auto path = iterator->path();
        std::error_code item_error;
        const auto regular = iterator->is_regular_file(item_error);
        iterator.increment(error);
        if (error) error.clear();
        if (item_error || !regular) continue;
        auto extension = python_lower(path_text(path.extension()));
        if (std::find(extensions.begin(), extensions.end(), extension) == extensions.end())
            continue;
        auto relative = path.lexically_relative(root).generic_u8string();
        if (!includes.empty() && !matches_any(relative, includes)) continue;
        if (!excludes.empty() && matches_any(relative, excludes)) continue;
        const auto size = fs::file_size(path, item_error);
        if (item_error) continue;
        const auto notebook = std::find(parser_corpus_notebook_extensions().begin(),
            parser_corpus_notebook_extensions().end(), extension)
            != parser_corpus_notebook_extensions().end();
        files.push_back({path, relative, extension, notebook ? "notebook" : "source",
            source_from_relative_path(relative), size});
    }
    std::vector<std::string> sort_keys;
    std::vector<std::size_t> sort_order;
    sort_keys.reserve(files.size());
    sort_order.reserve(files.size());
    for (std::size_t index = 0; index < files.size(); ++index) {
        sort_keys.push_back(python_casefold(files[index].relative_path));
        sort_order.push_back(index);
    }
    std::stable_sort(sort_order.begin(), sort_order.end(),
        [&](std::size_t left, std::size_t right) {
            return sort_keys[left] < sort_keys[right];
        });
    std::vector<CorpusFile> sorted_files;
    sorted_files.reserve(files.size());
    for (const auto index : sort_order)
        sorted_files.push_back(std::move(files[index]));
    files = std::move(sorted_files);
    if (options.shuffle) deterministic_shuffle(files, options.seed);
    if (options.max_files && files.size() > *options.max_files)
        files.resize(*options.max_files);
    return files;
}

JsonValue summarize_discovery(
    const std::vector<CorpusFile>& files, const fs::path& corpus_root) {
    std::vector<std::string> extensions;
    std::vector<std::string> kinds;
    std::vector<std::string> sources;
    mpz_class total = 0;
    for (const auto& file : files) {
        extensions.push_back(file.extension);
        kinds.push_back(file.kind);
        sources.push_back(file.source);
        total += byte_count_integer(file.size_bytes);
    }
    return JsonValue::Object{
        {"corpus_root", path_text(absolute_path(corpus_root))},
        {"file_count", static_cast<unsigned long long>(files.size())},
        {"total_bytes", JsonValue::number(total.get_str())},
        {"by_extension", counts(extensions)},
        {"by_kind", counts(kinds)},
        {"by_source", counts(sources)},
    };
}

ParserAttempt parse_file_with_tungsten(
    const CorpusFile& file,
    ParseForm source_form,
    std::optional<mpz_class> max_bytes,
    std::size_t preview_chars) {
    if (max_bytes && byte_count_integer(file.size_bytes) > *max_bytes) {
        return ParserAttempt::skipped("tungsten", "FileTooLarge",
            "File is " + std::to_string(file.size_bytes) + " bytes; max_bytes is "
                + max_bytes->get_str() + ".");
    }
    const auto start = Clock::now();
    std::string text;
    try {
        text = read_utf8_lossy(file.path);
    } catch (const std::exception& exception) {
        return failed_attempt("tungsten", start, "OSError", exception.what(), preview_chars);
    }
    if (file.kind == "notebook") {
        try {
            const auto document = NotebookDocument::from_text(text, file.path);
            const auto summary = document.summary();
            return ParserAttempt::success("tungsten", elapsed_ms(start), JsonValue::Object{
                {"title", summary.title ? JsonValue(*summary.title) : JsonValue(nullptr)},
                {"cell_count", static_cast<unsigned long long>(summary.cell_count)},
                {"group_count", static_cast<unsigned long long>(summary.group_count)},
                {"option_count", static_cast<unsigned long long>(summary.option_count)},
            });
        } catch (const std::exception& exception) {
            return failed_attempt(
                "tungsten", start, "ValueError", exception.what(), preview_chars);
        }
    }
    try {
        const auto expression = parse_expression(text, source_form);
        return ParserAttempt::success("tungsten", elapsed_ms(start), JsonValue::Object{
            {"form", form_label(source_form)},
            {"input_form_preview", truncate_text(expression.to_input_form(), preview_chars)},
            {"full_form_preview", truncate_text(expression.to_full_form(), preview_chars)},
            {"depth", static_cast<unsigned long long>(expression.depth())},
            {"length", static_cast<unsigned long long>(expression.length())},
        });
    } catch (const ParseError& exception) {
        return failed_attempt(
            "tungsten", start, "WolframSyntaxError", exception.what(), preview_chars);
    } catch (const std::exception& exception) {
        return failed_attempt(
            "tungsten", start, "WolframSyntaxError", exception.what(), preview_chars);
    }
}

std::map<std::string, ParserAttempt> parse_files_with_wolfram_kernel(
    const std::vector<CorpusFile>& files,
    const WolframKernelRunner* runner,
    std::size_t preview_chars) {
    if (files.empty()) return {};
    std::optional<WolframKernelRunner> default_runner;
    if (runner == nullptr) default_runner.emplace();
    const auto& active_runner = runner == nullptr ? *default_runner : *runner;
    KernelEvaluationResult result;
    try {
        result = active_runner.evaluate_text(
            build_wolfram_parse_batch_script(files, preview_chars));
    } catch (const std::exception& exception) {
        throw ParserCorpusError(
            ParserCorpusErrorKind::Kernel, exception.what());
    }
    std::map<std::string, ParserAttempt> attempts;
    if (!result.evaluation_available) {
        const auto reason = result.failure_type && !result.failure_type->empty()
            ? *result.failure_type : std::string("KernelUnavailable");
        const auto message = result.stderr_text.empty()
            ? "Wolfram kernel did not produce a structured result." : result.stderr_text;
        for (const auto& file : files)
            attempts.emplace(file.relative_path,
                ParserAttempt::skipped("wolfram", reason, message));
        return attempts;
    }
    if (!result.result) {
        for (const auto& file : files)
            attempts.emplace(file.relative_path, ParserAttempt::failure("wolfram",
                "MissingKernelResult",
                "Wolfram kernel evaluation completed without a result string."));
        return attempts;
    }

    JsonValue payload;
    try {
        payload = decode_kernel_json_string(*result.result);
    } catch (const std::exception& exception) {
        JsonValue::Array messages;
        for (const auto& message : result.messages) messages.emplace_back(message);
        JsonValue::Object details{
            {"kernel_success", result.success ? JsonValue(*result.success) : JsonValue(nullptr)},
            {"kernel_failure_type", result.failure_type
                ? JsonValue(*result.failure_type) : JsonValue(nullptr)},
            {"kernel_messages", std::move(messages)},
            {"kernel_result_preview", truncate_text(*result.result, preview_chars)},
        };
        for (const auto& file : files)
            attempts.emplace(file.relative_path, ParserAttempt::failure("wolfram",
                "JSONDecodeError",
                truncate_text("Could not decode Wolfram parser batch payload: "
                    + std::string(exception.what()), preview_chars),
                std::nullopt, details));
        return attempts;
    }
    if (!payload.is_array()) {
        for (const auto& file : files)
            attempts.emplace(file.relative_path, ParserAttempt::failure("wolfram",
                "InvalidKernelPayload",
                "Wolfram parser batch payload was not a JSON array."));
        return attempts;
    }

    std::map<std::string, const CorpusFile*> files_by_path;
    for (const auto& file : files) files_by_path.emplace(slash_absolute(file.path), &file);
    for (const auto& item : payload.as_array()) {
        if (!item.is_object()) continue;
        const auto* raw_path = item.find("path");
        const auto* raw_attempt = item.find("attempt");
        if (raw_path == nullptr || !raw_path->is_string()
            || raw_attempt == nullptr || !raw_attempt->is_object()) continue;
        const auto found = files_by_path.find(raw_path->as_string());
        if (found == files_by_path.end()) continue;
        attempts[found->second->relative_path] =
            attempt_from_wolfram_payload(raw_attempt->as_object(), preview_chars);
    }
    for (const auto& file : files) {
        if (attempts.find(file.relative_path) == attempts.end())
            attempts.emplace(file.relative_path, ParserAttempt::failure("wolfram",
                "MissingFileResult",
                "Wolfram parser batch did not include this file in its JSON payload."));
    }
    return attempts;
}

std::string classify_parser_corpus_outcome(
    const ParserAttempt& tungsten, const ParserAttempt& wolfram) {
    if (tungsten.status == "skipped" || wolfram.status == "skipped") return "skipped";
    if (tungsten.status == "success" && wolfram.status == "success") return "both_success";
    if (tungsten.status == "failure" && wolfram.status == "success") return "tungsten_gap";
    if (tungsten.status == "success" && wolfram.status == "failure")
        return "tungsten_only_success";
    if (tungsten.status == "failure" && wolfram.status == "failure") return "both_fail";
    return tungsten.status + "_vs_" + wolfram.status;
}

ParserCorpusRun compare_parser_corpus(
    const fs::path& corpus_root,
    const ParserCorpusOptions& options,
    const WolframKernelRunner* runner,
    const WolframBatchParser& batch_parser) {
    const auto total_start = Clock::now();
    const auto discovery_start = Clock::now();
    const auto files = discover_corpus_files(corpus_root, options.discovery);
    const auto discovery_elapsed = elapsed_ms(discovery_start);
    const auto tungsten_start = Clock::now();
    auto tungsten_attempts = parse_files_with_tungsten(files, options.source_form,
        options.max_bytes, options.preview_chars, options.tungsten_workers);
    const auto tungsten_elapsed = elapsed_ms(tungsten_start);

    std::map<std::string, ParserAttempt> wolfram_attempts;
    double wolfram_elapsed = 0.0;
    if (options.compare_wolfram) {
        const auto start = Clock::now();
        std::vector<CorpusFile> eligible;
        for (const auto& file : files)
            if (!options.max_bytes
                || byte_count_integer(file.size_bytes) <= *options.max_bytes)
                eligible.push_back(file);
        const auto batch_size = std::max<std::size_t>(1, options.kernel_batch_size);
        for (std::size_t offset = 0; offset < eligible.size(); offset += batch_size) {
            const auto end = std::min(eligible.size(), offset + batch_size);
            const std::vector<CorpusFile> batch(eligible.begin() + offset, eligible.begin() + end);
            auto attempts = batch_parser
                ? batch_parser(batch)
                : parse_files_with_wolfram_kernel(batch, runner, options.preview_chars);
            for (auto& [path, attempt] : attempts)
                wolfram_attempts[path] = std::move(attempt);
        }
        wolfram_elapsed = elapsed_ms(start);
    }
    for (const auto& file : files) {
        if (wolfram_attempts.find(file.relative_path) != wolfram_attempts.end()) continue;
        if (options.compare_wolfram) {
            const auto limit = options.max_bytes
                ? options.max_bytes->get_str() : std::string("None");
            wolfram_attempts.emplace(file.relative_path, ParserAttempt::skipped("wolfram",
                "FileTooLarge", "File is " + std::to_string(file.size_bytes)
                    + " bytes; max_bytes is " + limit + "."));
        } else {
            wolfram_attempts.emplace(file.relative_path, ParserAttempt::skipped("wolfram",
                "WolframComparisonDisabled",
                "Wolfram kernel comparison was disabled for this run."));
        }
    }

    std::vector<ParserCorpusResult> results;
    results.reserve(files.size());
    for (const auto& file : files) {
        auto tungsten = tungsten_attempts.at(file.relative_path);
        auto wolfram = wolfram_attempts.at(file.relative_path);
        const auto outcome = classify_parser_corpus_outcome(tungsten, wolfram);
        results.push_back({file, std::move(tungsten), std::move(wolfram), outcome});
    }
    auto summary = build_run_summary(corpus_root, files, results, options,
        discovery_elapsed, tungsten_elapsed, wolfram_elapsed);
    const auto output_directory = options.out_dir
        ? options.out_dir
        : options.write_outputs
            ? std::optional<fs::path>(corpus_root / default_parser_corpus_output_directory)
            : std::nullopt;
    std::map<std::string, std::string> output_files;
    double output_elapsed = 0.0;
    if (options.write_outputs && output_directory) {
        const auto start = Clock::now();
        output_files = write_parser_corpus_outputs(*output_directory, summary, results);
        output_elapsed = elapsed_ms(start);
        JsonValue::Object values;
        for (const auto& [key, value] : output_files) values.emplace(key, value);
        summary["output_files"] = std::move(values);
    }
    summary["timings"]["output_write_elapsed_ms"] = output_elapsed;
    summary["timings"]["total_elapsed_ms"] = elapsed_ms(total_start);
    if (const auto found = output_files.find("summary"); found != output_files.end())
        write_text(found->second, summary.dump_pretty(2) + "\n");
    if (const auto found = output_files.find("report"); found != output_files.end())
        write_text(found->second, render_markdown_report(summary, results));
    return {std::move(summary), std::move(results), std::move(output_files)};
}

std::map<std::string, std::string> write_parser_corpus_outputs(
    const fs::path& output_directory,
    const JsonValue& summary,
    const std::vector<ParserCorpusResult>& results) {
    std::error_code error;
    fs::create_directories(output_directory, error);
    if (error) throw ParserCorpusError(ParserCorpusErrorKind::Io,
        "Could not create parser corpus output directory: " + error.message(),
        output_directory);
    const auto summary_path = output_directory / "parser-corpus-summary.json";
    const auto results_path = output_directory / "parser-corpus-results.jsonl";
    const auto report_path = output_directory / "parser-corpus-report.md";
    write_text(summary_path, summary.dump_pretty(2) + "\n");
    std::ostringstream json_lines;
    for (const auto& result : results) json_lines << result.to_json_value().dump() << '\n';
    write_text(results_path, json_lines.str());
    write_text(report_path, render_markdown_report(summary, results));
    return {
        {"summary", path_text(summary_path)},
        {"results_jsonl", path_text(results_path)},
        {"report", path_text(report_path)},
    };
}

std::string build_wolfram_parse_batch_script(
    const std::vector<CorpusFile>& files, std::size_t preview_chars) {
    JsonValue::Array paths;
    for (const auto& file : files) paths.emplace_back(slash_absolute(file.path));
    const auto paths_literal = wl_string(JsonValue(std::move(paths)).dump());
    std::ostringstream script;
    script.imbue(std::locale::classic());
    script << "tungstenParserCorpusFiles = ImportString[" << paths_literal
           << ", \"RawJSON\"];\n"
           << "tungstenParserCorpusPreviewChars = " << preview_chars << ";\n\n"
           << R"WL(ClearAll[tungstenParserCorpusShortString, tungstenParserCorpusParseOne];
tungstenParserCorpusShortString[text_] := If[
    StringQ[text] && StringLength[text] > tungstenParserCorpusPreviewChars,
    StringTake[text, tungstenParserCorpusPreviewChars] <> "...",
    text
];

tungstenParserCorpusParseOne[path_String] := Module[
    {started, text, held, normalized, rendered, fullRendered},
    started = AbsoluteTime[];
    text = Quiet @ Check[Import[path, "Text", CharacterEncoding -> "UTF-8"], $Failed];
    If[
        text === $Failed,
        Return @ <|
            "parser" -> "wolfram",
            "status" -> "failure",
            "elapsed_ms" -> N[1000 * (AbsoluteTime[] - started)],
            "error_type" -> "ImportFailure",
            "error" -> "Import[path, Text] returned $Failed."
        |>
    ];

    held = Quiet @ Check[ToExpression[text, InputForm, HoldComplete], $Failed];
    If[
        held === $Failed,
        Return @ <|
            "parser" -> "wolfram",
            "status" -> "failure",
            "elapsed_ms" -> N[1000 * (AbsoluteTime[] - started)],
            "error_type" -> "ParseFailure",
            "error" -> "ToExpression[text, InputForm, HoldComplete] returned $Failed."
        |>
    ];

    normalized = Replace[held, HoldComplete[exprs__] :> HoldComplete[CompoundExpression[exprs]]];
    rendered = Quiet @ Check[ToString[normalized, InputForm, PageWidth -> Infinity], "$Failed"];
    fullRendered = Quiet @ Check[ToString[FullForm[normalized], OutputForm, PageWidth -> Infinity], "$Failed"];
    <|
        "parser" -> "wolfram",
        "status" -> "success",
        "elapsed_ms" -> N[1000 * (AbsoluteTime[] - started)],
        "summary" -> <|
            "held_head" -> Quiet @ Check[ToString[Head[normalized], InputForm], "$Failed"],
            "leaf_count" -> Quiet @ Check[LeafCount[normalized], Null],
            "byte_count" -> Quiet @ Check[ByteCount[normalized], Null],
            "input_form_preview" -> tungstenParserCorpusShortString[rendered],
            "full_form_preview" -> tungstenParserCorpusShortString[fullRendered]
        |>
    |>
];

ExportString[
    Map[<|"path" -> #, "attempt" -> tungstenParserCorpusParseOne[#]|> &, tungstenParserCorpusFiles],
    "RawJSON"
])WL";
    return script.str();
}

} // namespace tungsten
