#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace tungsten::detail {

struct Utf8CodePoint {
    std::uint32_t value;
    std::size_t offset;
    std::size_t length;
    bool valid;
};

Utf8CodePoint decode_utf8_code_point(
    std::string_view text, std::size_t offset) noexcept;

std::vector<std::size_t> utf8_code_point_boundaries(std::string_view text);

bool unicode_is_letter(std::uint32_t value) noexcept;
bool unicode_is_digit(std::uint32_t value) noexcept;
bool unicode_is_decimal(std::uint32_t value) noexcept;
std::optional<unsigned> unicode_decimal_value(std::uint32_t value) noexcept;
bool unicode_is_punctuation(std::uint32_t value) noexcept;
bool unicode_is_alphanumeric(std::uint32_t value) noexcept;
bool unicode_is_whitespace(std::uint32_t value) noexcept;
bool unicode_regex_case_equivalent(
    std::uint32_t left, std::uint32_t right) noexcept;
bool unicode_regex_case_matches_range(
    std::uint32_t value, std::uint32_t first, std::uint32_t last) noexcept;

std::string unicode_to_upper(std::string_view text);
std::string unicode_to_lower(std::string_view text);

} // namespace tungsten::detail
