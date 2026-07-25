#include "tungsten/detail/unicode.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <iterator>

namespace tungsten::detail {
namespace {

struct UnicodeDeltaRange {
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

struct UnicodePropertyRange {
    std::uint32_t first;
    std::uint32_t last;
};

struct UnicodeRegexCaseClass {
    std::uint32_t canonical;
    std::array<std::uint32_t, 4> members;
    std::uint8_t size;
};

#include "unicode_data.inc"

void append_utf8(std::string& output, std::uint32_t value) {
    if (value <= 0x7fU) {
        output.push_back(static_cast<char>(value));
    } else if (value <= 0x7ffU) {
        output.push_back(static_cast<char>(0xc0U | (value >> 6U)));
        output.push_back(static_cast<char>(0x80U | (value & 0x3fU)));
    } else if (value <= 0xffffU) {
        output.push_back(static_cast<char>(0xe0U | (value >> 12U)));
        output.push_back(static_cast<char>(0x80U | ((value >> 6U) & 0x3fU)));
        output.push_back(static_cast<char>(0x80U | (value & 0x3fU)));
    } else if (value <= 0x10ffffU) {
        output.push_back(static_cast<char>(0xf0U | (value >> 18U)));
        output.push_back(static_cast<char>(0x80U | ((value >> 12U) & 0x3fU)));
        output.push_back(static_cast<char>(0x80U | ((value >> 6U) & 0x3fU)));
        output.push_back(static_cast<char>(0x80U | (value & 0x3fU)));
    }
}

template<std::size_t Count>
bool has_unicode_property(
    std::uint32_t value,
    const UnicodePropertyRange (&ranges)[Count]) noexcept {
    const auto found = std::lower_bound(std::begin(ranges), std::end(ranges),
        value, [](const UnicodePropertyRange& range, std::uint32_t target) {
            return range.last < target;
        });
    return found != std::end(ranges) && found->first <= value;
}

template<std::size_t RangeCount, std::size_t MappingCount>
void append_unicode_mapping(
    std::string& output,
    std::uint32_t value,
    const UnicodeDeltaRange (&ranges)[RangeCount],
    const UnicodeMapping (&mappings)[MappingCount]) {
    for (const auto& range : ranges) {
        if (value >= range.first && value <= range.last
            && (value - range.first) % range.step == 0) {
            append_utf8(output, static_cast<std::uint32_t>(
                static_cast<std::int64_t>(value) + range.delta));
            return;
        }
    }
    const auto found = std::lower_bound(
        std::begin(mappings), std::end(mappings), value,
        [](const UnicodeMapping& mapping, std::uint32_t target) {
            return mapping.source < target;
        });
    if (found == std::end(mappings) || found->source != value) {
        append_utf8(output, value);
        return;
    }
    for (std::size_t index = 0; index < found->size; ++index)
        append_utf8(output, found->targets[index]);
}

template<std::size_t RangeCount, std::size_t MappingCount>
std::uint32_t unicode_single_mapping(
    std::uint32_t value,
    const UnicodeDeltaRange (&ranges)[RangeCount],
    const UnicodeMapping (&mappings)[MappingCount]) noexcept {
    for (const auto& range : ranges) {
        if (value >= range.first && value <= range.last
            && (value - range.first) % range.step == 0) {
            return static_cast<std::uint32_t>(
                static_cast<std::int64_t>(value) + range.delta);
        }
    }
    const auto found = std::lower_bound(
        std::begin(mappings), std::end(mappings), value,
        [](const UnicodeMapping& mapping, std::uint32_t target) {
            return mapping.source < target;
        });
    return found != std::end(mappings) && found->source == value
        && found->size == 1 ? found->targets[0] : value;
}

std::uint32_t unicode_regex_case_canonical(std::uint32_t value) noexcept {
    return unicode_single_mapping(value, unicode_regex_case_ranges,
        unicode_regex_case_mappings);
}

template<std::size_t RangeCount, std::size_t MappingCount>
std::string transform_utf8(
    std::string_view text,
    const UnicodeDeltaRange (&ranges)[RangeCount],
    const UnicodeMapping (&mappings)[MappingCount]) {
    std::string output;
    output.reserve(text.size());
    for (std::size_t offset = 0; offset < text.size();) {
        const auto decoded = decode_utf8_code_point(text, offset);
        if (!decoded.valid) {
            output.append(text.substr(offset, decoded.length));
        } else {
            append_unicode_mapping(output, decoded.value, ranges, mappings);
        }
        offset += decoded.length;
    }
    return output;
}

} // namespace

Utf8CodePoint decode_utf8_code_point(
    std::string_view text, std::size_t offset) noexcept {
    if (offset >= text.size()) return {0, offset, 0, false};
    const auto lead = static_cast<unsigned char>(text[offset]);
    if (lead < 0x80U) return {lead, offset, 1, true};

    std::size_t length = 0;
    std::uint32_t value = 0;
    std::uint32_t minimum = 0;
    if (lead >= 0xc2U && lead <= 0xdfU) {
        length = 2; value = lead & 0x1fU; minimum = 0x80U;
    } else if (lead >= 0xe0U && lead <= 0xefU) {
        length = 3; value = lead & 0x0fU; minimum = 0x800U;
    } else if (lead >= 0xf0U && lead <= 0xf4U) {
        length = 4; value = lead & 0x07U; minimum = 0x10000U;
    } else {
        return {lead, offset, 1, false};
    }
    if (offset + length > text.size()) return {lead, offset, 1, false};
    for (std::size_t index = 1; index < length; ++index) {
        const auto continuation = static_cast<unsigned char>(text[offset + index]);
        if ((continuation & 0xc0U) != 0x80U)
            return {lead, offset, 1, false};
        value = (value << 6U) | (continuation & 0x3fU);
    }
    if (value < minimum || value > 0x10ffffU
        || (value >= 0xd800U && value <= 0xdfffU))
        return {lead, offset, 1, false};
    return {value, offset, length, true};
}

std::vector<std::size_t> utf8_code_point_boundaries(std::string_view text) {
    std::vector<std::size_t> result{0};
    for (std::size_t offset = 0; offset < text.size();) {
        const auto decoded = decode_utf8_code_point(text, offset);
        offset += decoded.length == 0 ? 1 : decoded.length;
        result.push_back(offset);
    }
    return result;
}

bool unicode_is_letter(std::uint32_t value) noexcept {
    return has_unicode_property(value, unicode_alphabetic_ranges);
}

bool unicode_is_digit(std::uint32_t value) noexcept {
    return has_unicode_property(value, unicode_digit_ranges);
}

bool unicode_is_decimal(std::uint32_t value) noexcept {
    return has_unicode_property(value, unicode_decimal_ranges);
}

bool unicode_is_punctuation(std::uint32_t value) noexcept {
    return has_unicode_property(value, unicode_punctuation_ranges);
}

bool unicode_is_alphanumeric(std::uint32_t value) noexcept {
    return has_unicode_property(value, unicode_alphanumeric_ranges);
}

bool unicode_is_whitespace(std::uint32_t value) noexcept {
    // Python's Unicode whitespace set is stable data rather than a process
    // locale property, keeping default StringSplit deterministic.
    return (value >= 0x09U && value <= 0x0dU)
        || (value >= 0x1cU && value <= 0x20U)
        || value == 0x85U || value == 0xa0U || value == 0x1680U
        || (value >= 0x2000U && value <= 0x200aU)
        || value == 0x2028U || value == 0x2029U || value == 0x202fU
        || value == 0x205fU || value == 0x3000U;
}

bool unicode_regex_case_equivalent(
    std::uint32_t left, std::uint32_t right) noexcept {
    return unicode_regex_case_canonical(left)
        == unicode_regex_case_canonical(right);
}

bool unicode_regex_case_matches_range(
    std::uint32_t value, std::uint32_t first, std::uint32_t last) noexcept {
    if (value >= first && value <= last) return true;
    const auto canonical = unicode_regex_case_canonical(value);
    const auto found = std::lower_bound(
        std::begin(unicode_regex_case_classes),
        std::end(unicode_regex_case_classes), canonical,
        [](const UnicodeRegexCaseClass& value_class, std::uint32_t target) {
            return value_class.canonical < target;
        });
    if (found == std::end(unicode_regex_case_classes)
        || found->canonical != canonical) return false;
    return std::any_of(found->members.begin(),
        found->members.begin() + found->size,
        [&](std::uint32_t member) {
            return member >= first && member <= last;
        });
}

std::string unicode_to_upper(std::string_view text) {
    return transform_utf8(text, unicode_upper_ranges, unicode_upper_mappings);
}

std::string unicode_to_lower(std::string_view text) {
    std::vector<Utf8CodePoint> decoded;
    for (std::size_t offset = 0; offset < text.size();) {
        decoded.push_back(decode_utf8_code_point(text, offset));
        offset += decoded.back().length;
    }

    std::string output;
    output.reserve(text.size());
    for (std::size_t index = 0; index < decoded.size(); ++index) {
        const auto& character = decoded[index];
        if (!character.valid) {
            output.append(text.substr(character.offset, character.length));
            continue;
        }
        if (character.value == 0x03a3U) {
            bool preceded_by_cased = false;
            for (auto previous = index; previous != 0;) {
                const auto value = decoded[--previous].value;
                if (has_unicode_property(
                        value, unicode_case_ignorable_ranges))
                    continue;
                preceded_by_cased = has_unicode_property(
                    value, unicode_cased_ranges);
                break;
            }
            bool followed_by_cased = false;
            for (auto next = index + 1; next < decoded.size(); ++next) {
                const auto value = decoded[next].value;
                if (has_unicode_property(
                        value, unicode_case_ignorable_ranges))
                    continue;
                followed_by_cased = has_unicode_property(
                    value, unicode_cased_ranges);
                break;
            }
            if (preceded_by_cased && !followed_by_cased) {
                append_utf8(output, 0x03c2U);
                continue;
            }
        }
        append_unicode_mapping(output, character.value,
            unicode_lower_ranges, unicode_lower_mappings);
    }
    return output;
}

} // namespace tungsten::detail
