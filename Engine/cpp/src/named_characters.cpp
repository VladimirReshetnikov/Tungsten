#include "tungsten/bundled_data.hpp"
#include "tungsten/wolfram_strings.hpp"

#include <cstdint>
#include <iomanip>
#include <locale>
#include <map>
#include <sstream>
#include <stdexcept>

namespace tungsten {
namespace {

std::string encode_utf8(std::uint32_t codepoint) {
    if (codepoint > 0x10ffff) return {};
    std::string output;
    if (codepoint <= 0x7f) {
        output.push_back(static_cast<char>(codepoint));
    } else if (codepoint <= 0x7ff) {
        output.push_back(static_cast<char>(0xc0 | (codepoint >> 6)));
        output.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
    } else if (codepoint <= 0xffff) {
        output.push_back(static_cast<char>(0xe0 | (codepoint >> 12)));
        output.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
    } else {
        output.push_back(static_cast<char>(0xf0 | (codepoint >> 18)));
        output.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
    }
    return output;
}

bool continuation(unsigned char value) { return (value & 0xc0) == 0x80; }

struct DecodedUtf8 {
    std::uint32_t codepoint;
    std::size_t end;
    bool valid;
};

DecodedUtf8 decode_utf8(
    const std::string& value, std::size_t index) {
    const auto first = static_cast<unsigned char>(value[index]);
    if (first < 0x80) return {first, index + 1, true};
    if (first >= 0xc2 && first <= 0xdf && index + 1 < value.size()) {
        const auto second = static_cast<unsigned char>(value[index + 1]);
        if (continuation(second)) {
            return {static_cast<std::uint32_t>(
                ((first & 0x1f) << 6) | (second & 0x3f)), index + 2, true};
        }
    }
    if (first >= 0xe0 && first <= 0xef && index + 2 < value.size()) {
        const auto second = static_cast<unsigned char>(value[index + 1]);
        const auto third = static_cast<unsigned char>(value[index + 2]);
        const bool shortest = first != 0xe0 || second >= 0xa0;
        // Accept WTF-8 surrogate encodings as an internal representation for
        // Python string values containing isolated surrogate codepoints.
        if (continuation(second) && continuation(third) && shortest) {
            return {static_cast<std::uint32_t>(((first & 0x0f) << 12)
                | ((second & 0x3f) << 6) | (third & 0x3f)), index + 3, true};
        }
    }
    if (first >= 0xf0 && first <= 0xf4 && index + 3 < value.size()) {
        const auto second = static_cast<unsigned char>(value[index + 1]);
        const auto third = static_cast<unsigned char>(value[index + 2]);
        const auto fourth = static_cast<unsigned char>(value[index + 3]);
        const bool shortest = first != 0xf0 || second >= 0x90;
        const bool in_range = first != 0xf4 || second <= 0x8f;
        if (continuation(second) && continuation(third) && continuation(fourth)
            && shortest && in_range) {
            return {static_cast<std::uint32_t>(((first & 0x07) << 18)
                | ((second & 0x3f) << 12) | ((third & 0x3f) << 6) | (fourth & 0x3f)),
                index + 4, true};
        }
    }
    return {0xfffd, index + 1, false};
}

struct CharacterTables {
    NamedCharacterCodepoints forward;
    NamedCharacterReverseMap reverse;
};

CharacterTables load_character_tables() {
    std::istringstream input{std::string(bundled_named_characters_json())};

    std::map<std::string, std::uint32_t> ordered;
    bool in_characters = false;
    std::string line;
    while (std::getline(input, line)) {
        if (!in_characters) {
            if (line.find("\"characters\"") != std::string::npos) in_characters = true;
            continue;
        }
        const auto quote_begin = line.find('"');
        if (quote_begin == std::string::npos) {
            if (line.find('}') != std::string::npos) break;
            continue;
        }
        const auto quote_end = line.find('"', quote_begin + 1);
        const auto colon = line.find(':', quote_end == std::string::npos ? quote_begin : quote_end);
        if (quote_end == std::string::npos || colon == std::string::npos) continue;
        std::size_t number_begin = colon + 1;
        while (number_begin < line.size() && (line[number_begin] == ' ' || line[number_begin] == '\t')) {
            ++number_begin;
        }
        std::size_t number_end = number_begin;
        while (number_end < line.size() && line[number_end] >= '0' && line[number_end] <= '9') {
            ++number_end;
        }
        if (number_begin == number_end) continue;
        ordered.emplace(
            line.substr(quote_begin + 1, quote_end - quote_begin - 1),
            static_cast<std::uint32_t>(std::stoul(line.substr(number_begin, number_end - number_begin))));
    }
    if (ordered.empty()) throw std::runtime_error("bundled named-character table is empty");

    CharacterTables tables;
    tables.forward = std::move(ordered);
    for (const auto& [name, codepoint] : tables.forward) {
        if (codepoint < 128 && name.compare(0, 3, "Raw") == 0) continue;
        tables.reverse.emplace(codepoint, name);
    }
    return tables;
}

const CharacterTables& character_tables() {
    static const CharacterTables tables = load_character_tables();
    return tables;
}

std::string numeric_escape(std::uint32_t codepoint, char marker, int width) {
    std::ostringstream output;
    output.imbue(std::locale::classic());
    output << '\\' << marker << std::hex << std::nouppercase << std::setfill('0')
           << std::setw(width) << codepoint;
    return output.str();
}

} // namespace

const NamedCharacterCodepoints& named_character_codepoints() {
    return character_tables().forward;
}

const NamedCharacterReverseMap& named_character_reverse_map() {
    return character_tables().reverse;
}

std::optional<std::string> named_character(const std::string& name) {
    const auto found = character_tables().forward.find(name);
    if (found == character_tables().forward.end()) return std::nullopt;
    const auto encoded = encode_utf8(found->second);
    return encoded.empty() ? std::nullopt : std::optional<std::string>(encoded);
}

std::optional<std::string> named_character_name(const std::string& utf8_character) {
    if (utf8_character.empty()) return std::nullopt;
    const auto decoded = decode_utf8(utf8_character, 0);
    if (!decoded.valid || decoded.end != utf8_character.size()) return std::nullopt;
    const auto found = character_tables().reverse.find(decoded.codepoint);
    return found == character_tables().reverse.end()
        ? std::nullopt : std::optional<std::string>(found->second);
}

std::optional<std::string> named_character_escape_for_char(
    const std::string& utf8_character) {
    const auto name = named_character_name(utf8_character);
    if (!name) return std::nullopt;
    return "\\[" + *name + "]";
}

std::optional<DecodedNamedCharacterEscape> decode_named_character_escape(
    std::string_view text, std::size_t index) {
    if (index > text.size() || text.size() - index < 2
        || text[index] != '\\' || text[index + 1] != '[') {
        return std::nullopt;
    }
    const auto end = text.find(']', index + 2);
    if (end == std::string_view::npos) return std::nullopt;
    const auto name = std::string(text.substr(index + 2, end - index - 2));
    const auto character = named_character(name);
    if (!character) return std::nullopt;
    return DecodedNamedCharacterEscape{*character, end + 1};
}

std::optional<DecodedNamedCharacterEscape> decode_named_character_escape_strict(
    std::string_view text, std::size_t index) {
    if (index > text.size() || text.size() - index < 2
        || text[index] != '\\' || text[index + 1] != '[') {
        return std::nullopt;
    }
    const auto end = text.find(']', index + 2);
    if (end == std::string_view::npos) {
        throw std::invalid_argument(
            "Unterminated Wolfram named character escape at offset "
            + std::to_string(index) + ".");
    }
    const auto name = std::string(text.substr(index + 2, end - index - 2));
    const auto character = named_character(name);
    if (!character) {
        throw std::invalid_argument(
            "Unknown Wolfram named character escape \\[" + name + "].");
    }
    return DecodedNamedCharacterEscape{*character, end + 1};
}

std::string encode_printable_ascii(const std::string& text) {
    std::string output;
    for (std::size_t index = 0; index < text.size();) {
        const auto decoded = decode_utf8(text, index);
        const auto codepoint = decoded.codepoint;
        if (codepoint >= 32 && codepoint < 127) {
            output.push_back(static_cast<char>(codepoint));
        } else if (codepoint == 8) output += R"(\b)";
        else if (codepoint == 9) output += R"(\t)";
        else if (codepoint == 10) output += R"(\n)";
        else if (codepoint == 12) output += R"(\f)";
        else if (codepoint == 13) output += R"(\r)";
        else if (codepoint == 27) output += R"(\[RawEscape])";
        else if (codepoint < 32 || codepoint == 127) {
            std::ostringstream escape;
            escape.imbue(std::locale::classic());
            escape << '\\' << std::oct << std::setfill('0') << std::setw(3) << codepoint;
            output += escape.str();
        } else {
            const auto name = character_tables().reverse.find(codepoint);
            if (name != character_tables().reverse.end()) output += "\\[" + name->second + "]";
            else if (codepoint <= 0xffff) output += numeric_escape(codepoint, ':', 4);
            else output += numeric_escape(codepoint, '|', 6);
        }
        index = decoded.end;
    }
    return output;
}

} // namespace tungsten
