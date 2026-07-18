#include "tungsten/json.hpp"
#include "tungsten/detail/numeric.hpp"

#include <charconv>
#include <cmath>
#include <iomanip>
#include <limits>
#include <sstream>
#include <system_error>
#include <utility>

namespace tungsten {
namespace {

constexpr std::size_t maximum_json_depth = 512;

void append_utf8(std::string& output, std::uint32_t codepoint) {
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
}

int hex_value(char character) noexcept {
    if (character >= '0' && character <= '9') return character - '0';
    if (character >= 'a' && character <= 'f') return character - 'a' + 10;
    if (character >= 'A' && character <= 'F') return character - 'A' + 10;
    return -1;
}

bool valid_number_text(std::string_view source) noexcept {
    std::size_t position = 0;
    if (position < source.size() && source[position] == '-') ++position;
    if (position == source.size()) return false;

    if (source[position] == '0') {
        ++position;
        if (position < source.size() && source[position] >= '0' && source[position] <= '9')
            return false;
    } else {
        if (source[position] < '1' || source[position] > '9') return false;
        while (position < source.size()
            && source[position] >= '0' && source[position] <= '9') ++position;
    }

    if (position < source.size() && source[position] == '.') {
        ++position;
        const auto fraction_start = position;
        while (position < source.size()
            && source[position] >= '0' && source[position] <= '9') ++position;
        if (position == fraction_start) return false;
    }

    if (position < source.size()
        && (source[position] == 'e' || source[position] == 'E')) {
        ++position;
        if (position < source.size()
            && (source[position] == '+' || source[position] == '-')) ++position;
        const auto exponent_start = position;
        while (position < source.size()
            && source[position] >= '0' && source[position] <= '9') ++position;
        if (position == exponent_start) return false;
    }
    return position == source.size();
}

class JsonParser {
public:
    explicit JsonParser(std::string_view source) : source_(source) {}

    JsonValue parse() {
        skip_whitespace();
        auto value = parse_value(0);
        skip_whitespace();
        if (position_ != source_.size()) fail("unexpected trailing JSON input");
        return value;
    }

private:
    [[noreturn]] void fail(const std::string& message) const {
        throw JsonError(message, position_);
    }

    void skip_whitespace() noexcept {
        while (position_ < source_.size()) {
            const auto character = source_[position_];
            if (character != ' ' && character != '\t'
                && character != '\r' && character != '\n') break;
            ++position_;
        }
    }

    bool consume(char character) noexcept {
        if (position_ >= source_.size() || source_[position_] != character) return false;
        ++position_;
        return true;
    }

    void consume_literal(std::string_view literal) {
        if (source_.substr(position_, literal.size()) != literal)
            fail("invalid JSON literal");
        position_ += literal.size();
    }

    JsonValue parse_value(std::size_t depth) {
        if (depth > maximum_json_depth) fail("JSON nesting depth limit exceeded");
        if (position_ >= source_.size()) fail("expected a JSON value");
        switch (source_[position_]) {
        case 'n': consume_literal("null"); return JsonValue();
        case 't': consume_literal("true"); return JsonValue(true);
        case 'f': consume_literal("false"); return JsonValue(false);
        case '"': return JsonValue(parse_string());
        case '[': return parse_array(depth + 1);
        case '{': return parse_object(depth + 1);
        default:
            if (source_[position_] == '-'
                || (source_[position_] >= '0' && source_[position_] <= '9'))
                return parse_number();
            fail("expected a JSON value");
        }
    }

    std::uint32_t parse_hex_quad() {
        if (position_ + 4 > source_.size()) fail("incomplete JSON Unicode escape");
        std::uint32_t value = 0;
        for (std::size_t index = 0; index < 4; ++index) {
            const auto digit = hex_value(source_[position_++]);
            if (digit < 0) fail("invalid JSON Unicode escape");
            value = (value << 4) | static_cast<std::uint32_t>(digit);
        }
        return value;
    }

    std::string parse_string() {
        if (!consume('"')) fail("expected a JSON string");
        std::string result;
        while (position_ < source_.size()) {
            const auto character = static_cast<unsigned char>(source_[position_++]);
            if (character == '"') return result;
            if (character < 0x20) fail("unescaped control character in JSON string");
            if (character != '\\') {
                result.push_back(static_cast<char>(character));
                continue;
            }

            if (position_ >= source_.size()) fail("incomplete JSON escape");
            switch (source_[position_++]) {
            case '"': result.push_back('"'); break;
            case '\\': result.push_back('\\'); break;
            case '/': result.push_back('/'); break;
            case 'b': result.push_back('\b'); break;
            case 'f': result.push_back('\f'); break;
            case 'n': result.push_back('\n'); break;
            case 'r': result.push_back('\r'); break;
            case 't': result.push_back('\t'); break;
            case 'u': {
                auto codepoint = parse_hex_quad();
                if (codepoint >= 0xd800 && codepoint <= 0xdbff) {
                    if (position_ + 2 > source_.size()
                        || source_[position_] != '\\' || source_[position_ + 1] != 'u')
                        fail("JSON high surrogate is missing its low surrogate");
                    position_ += 2;
                    const auto low = parse_hex_quad();
                    if (low < 0xdc00 || low > 0xdfff)
                        fail("invalid JSON low surrogate");
                    codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (low - 0xdc00);
                } else if (codepoint >= 0xdc00 && codepoint <= 0xdfff) {
                    fail("unexpected JSON low surrogate");
                }
                append_utf8(result, codepoint);
                break;
            }
            default: fail("invalid JSON escape");
            }
        }
        fail("unterminated JSON string");
    }

    JsonValue parse_number() {
        const auto start = position_;
        if (source_[position_] == '-') ++position_;
        if (position_ >= source_.size()) fail("incomplete JSON number");
        if (source_[position_] == '0') {
            ++position_;
            if (position_ < source_.size()
                && source_[position_] >= '0' && source_[position_] <= '9')
                fail("leading zero in JSON number");
        } else {
            if (source_[position_] < '1' || source_[position_] > '9')
                fail("invalid JSON number");
            while (position_ < source_.size()
                && source_[position_] >= '0' && source_[position_] <= '9') ++position_;
        }
        if (position_ < source_.size() && source_[position_] == '.') {
            ++position_;
            const auto fraction_start = position_;
            while (position_ < source_.size()
                && source_[position_] >= '0' && source_[position_] <= '9') ++position_;
            if (position_ == fraction_start) fail("missing JSON fractional digits");
        }
        if (position_ < source_.size()
            && (source_[position_] == 'e' || source_[position_] == 'E')) {
            ++position_;
            if (position_ < source_.size()
                && (source_[position_] == '+' || source_[position_] == '-')) ++position_;
            const auto exponent_start = position_;
            while (position_ < source_.size()
                && source_[position_] >= '0' && source_[position_] <= '9') ++position_;
            if (position_ == exponent_start) fail("missing JSON exponent digits");
        }
        return JsonValue::number(std::string(source_.substr(start, position_ - start)));
    }

    JsonValue parse_array(std::size_t depth) {
        consume('[');
        skip_whitespace();
        JsonValue::Array result;
        if (consume(']')) return JsonValue(std::move(result));
        while (true) {
            result.push_back(parse_value(depth));
            skip_whitespace();
            if (consume(']')) return JsonValue(std::move(result));
            if (!consume(',')) fail("expected ',' or ']' in JSON array");
            skip_whitespace();
        }
    }

    JsonValue parse_object(std::size_t depth) {
        consume('{');
        skip_whitespace();
        JsonValue::Object result;
        if (consume('}')) return JsonValue(std::move(result));
        while (true) {
            if (position_ >= source_.size() || source_[position_] != '"')
                fail("expected a string key in JSON object");
            auto key = parse_string();
            skip_whitespace();
            if (!consume(':')) fail("expected ':' after JSON object key");
            skip_whitespace();
            result.insert_or_assign(std::move(key), parse_value(depth));
            skip_whitespace();
            if (consume('}')) return JsonValue(std::move(result));
            if (!consume(',')) fail("expected ',' or '}' in JSON object");
            skip_whitespace();
        }
    }

    std::string_view source_;
    std::size_t position_ = 0;
};

void append_indent(std::string& output, std::size_t depth, std::size_t width) {
    if (width != 0 && depth > output.max_size() / width)
        throw std::length_error("JSON indentation is too large");
    output.append(depth * width, ' ');
}

void dump_json(
    const JsonValue& value,
    std::string& output,
    std::optional<std::size_t> indentation,
    std::size_t depth) {
    switch (value.type()) {
    case JsonValue::Type::Null: output += "null"; return;
    case JsonValue::Type::Boolean: output += value.as_boolean() ? "true" : "false"; return;
    case JsonValue::Type::Number: output += value.as_number().text; return;
    case JsonValue::Type::String: output += json_escape(value.as_string()); return;
    case JsonValue::Type::Array: {
        const auto& array = value.as_array();
        output.push_back('[');
        if (array.empty()) { output.push_back(']'); return; }
        for (std::size_t index = 0; index < array.size(); ++index) {
            if (index) output.push_back(',');
            if (indentation) {
                output.push_back('\n');
                append_indent(output, depth + 1, *indentation);
            }
            dump_json(array[index], output, indentation, depth + 1);
        }
        if (indentation) {
            output.push_back('\n');
            append_indent(output, depth, *indentation);
        }
        output.push_back(']');
        return;
    }
    case JsonValue::Type::Object: {
        const auto& object = value.as_object();
        output.push_back('{');
        if (object.empty()) { output.push_back('}'); return; }
        std::size_t index = 0;
        for (const auto& [key, item] : object) {
            if (index++) output.push_back(',');
            if (indentation) {
                output.push_back('\n');
                append_indent(output, depth + 1, *indentation);
            }
            output += json_escape(key);
            output += indentation ? ": " : ":";
            dump_json(item, output, indentation, depth + 1);
        }
        if (indentation) {
            output.push_back('\n');
            append_indent(output, depth, *indentation);
        }
        output.push_back('}');
        return;
    }
    }
}

template<typename Value>
std::optional<Value> parse_integral(const std::string& text) noexcept {
    if (text.find_first_of(".eE") != std::string::npos) return std::nullopt;
    Value value{};
    const auto result = std::from_chars(text.data(), text.data() + text.size(), value);
    if (result.ec != std::errc{} || result.ptr != text.data() + text.size())
        return std::nullopt;
    return value;
}

std::string format_python_json_double(double value) {
    // Use the same shortest-digit and fixed/scientific normalization as the
    // expression formatter.  JSON changes only the exponent marker and keeps
    // a fractional suffix for integral floating-point values.
    auto text = detail::python_machine_real_text(value);
    if (!text.empty() && text.back() == '.') text.push_back('0');
    if (const auto exponent = text.find("*^"); exponent != std::string::npos)
        text.replace(exponent, 2, "e");
    return text;
}

} // namespace

JsonError::JsonError(std::string message, std::size_t offset)
    : std::runtime_error(std::move(message) + " at byte " + std::to_string(offset)),
      offset_(offset) {}

std::size_t JsonError::offset() const noexcept { return offset_; }

JsonValue::JsonValue() noexcept : value_(nullptr) {}
JsonValue::JsonValue(std::nullptr_t) noexcept : value_(nullptr) {}
JsonValue::JsonValue(bool value) : value_(value) {}
JsonValue::JsonValue(int value) : JsonValue(static_cast<long long>(value)) {}
JsonValue::JsonValue(long value) : JsonValue(static_cast<long long>(value)) {}
JsonValue::JsonValue(long long value) : value_(Number{std::to_string(value)}) {}
JsonValue::JsonValue(unsigned value) : JsonValue(static_cast<unsigned long long>(value)) {}
JsonValue::JsonValue(unsigned long value)
    : JsonValue(static_cast<unsigned long long>(value)) {}
JsonValue::JsonValue(unsigned long long value) : value_(Number{std::to_string(value)}) {}

JsonValue::JsonValue(double value) {
    if (!std::isfinite(value))
        throw std::invalid_argument("JSON numbers must be finite");
    value_ = Number{format_python_json_double(value)};
}

JsonValue::JsonValue(const char* value) : value_(std::string(value == nullptr ? "" : value)) {}
JsonValue::JsonValue(std::string value) : value_(std::move(value)) {}
JsonValue::JsonValue(Array value) : value_(std::move(value)) {}
JsonValue::JsonValue(Object value) : value_(std::move(value)) {}
JsonValue::JsonValue(std::initializer_list<JsonValue> values) : value_(Array(values)) {}
JsonValue::JsonValue(Number value) : value_(std::move(value)) {}

JsonValue JsonValue::number(std::string text) {
    if (!valid_number_text(text)) throw std::invalid_argument("invalid JSON number text");
    return JsonValue(Number{std::move(text)});
}

JsonValue JsonValue::object(
    std::initializer_list<std::pair<const std::string, JsonValue>> values) {
    return JsonValue(Object(values));
}

JsonValue JsonValue::parse(std::string_view source) { return JsonParser(source).parse(); }

JsonValue::Type JsonValue::type() const noexcept {
    return static_cast<Type>(value_.index());
}

bool JsonValue::is_null() const noexcept { return type() == Type::Null; }
bool JsonValue::is_boolean() const noexcept { return type() == Type::Boolean; }
bool JsonValue::is_number() const noexcept { return type() == Type::Number; }
bool JsonValue::is_string() const noexcept { return type() == Type::String; }
bool JsonValue::is_array() const noexcept { return type() == Type::Array; }
bool JsonValue::is_object() const noexcept { return type() == Type::Object; }

bool JsonValue::as_boolean() const {
    if (!is_boolean()) throw std::logic_error("JSON value is not a boolean");
    return std::get<bool>(value_);
}

const JsonValue::Number& JsonValue::as_number() const {
    if (!is_number()) throw std::logic_error("JSON value is not a number");
    return std::get<Number>(value_);
}

std::optional<std::int64_t> JsonValue::as_int64() const noexcept {
    if (!is_number()) return std::nullopt;
    return parse_integral<std::int64_t>(std::get<Number>(value_).text);
}

std::optional<std::uint64_t> JsonValue::as_uint64() const noexcept {
    if (!is_number()) return std::nullopt;
    return parse_integral<std::uint64_t>(std::get<Number>(value_).text);
}

std::optional<double> JsonValue::as_double() const noexcept {
    if (!is_number()) return std::nullopt;
    const auto value = detail::parse_ascii_double(
        std::get<Number>(value_).text);
    return value && std::isfinite(*value) ? value : std::nullopt;
}

const std::string& JsonValue::as_string() const {
    if (!is_string()) throw std::logic_error("JSON value is not a string");
    return std::get<std::string>(value_);
}

const JsonValue::Array& JsonValue::as_array() const {
    if (!is_array()) throw std::logic_error("JSON value is not an array");
    return std::get<Array>(value_);
}

JsonValue::Array& JsonValue::as_array() {
    if (!is_array()) throw std::logic_error("JSON value is not an array");
    return std::get<Array>(value_);
}

const JsonValue::Object& JsonValue::as_object() const {
    if (!is_object()) throw std::logic_error("JSON value is not an object");
    return std::get<Object>(value_);
}

JsonValue::Object& JsonValue::as_object() {
    if (!is_object()) throw std::logic_error("JSON value is not an object");
    return std::get<Object>(value_);
}

bool JsonValue::contains(std::string_view key) const noexcept { return find(key) != nullptr; }

const JsonValue* JsonValue::find(std::string_view key) const noexcept {
    if (!is_object()) return nullptr;
    const auto& object = std::get<Object>(value_);
    const auto iterator = object.find(key);
    return iterator == object.end() ? nullptr : &iterator->second;
}

JsonValue* JsonValue::find(std::string_view key) noexcept {
    if (!is_object()) return nullptr;
    auto& object = std::get<Object>(value_);
    const auto iterator = object.find(key);
    return iterator == object.end() ? nullptr : &iterator->second;
}

const JsonValue& JsonValue::at(std::string_view key) const {
    const auto* value = find(key);
    if (value == nullptr) throw std::out_of_range("JSON object key not found");
    return *value;
}

JsonValue& JsonValue::at(std::string_view key) {
    auto* value = find(key);
    if (value == nullptr) throw std::out_of_range("JSON object key not found");
    return *value;
}

const JsonValue& JsonValue::at(std::size_t index) const { return as_array().at(index); }
JsonValue& JsonValue::at(std::size_t index) { return as_array().at(index); }

JsonValue& JsonValue::operator[](const std::string& key) {
    if (is_null()) value_ = Object{};
    return as_object()[key];
}

JsonValue& JsonValue::operator[](std::size_t index) { return as_array().at(index); }

void JsonValue::push_back(JsonValue value) {
    if (is_null()) value_ = Array{};
    as_array().push_back(std::move(value));
}

std::size_t JsonValue::size() const noexcept {
    if (is_string()) return std::get<std::string>(value_).size();
    if (is_array()) return std::get<Array>(value_).size();
    if (is_object()) return std::get<Object>(value_).size();
    return 0;
}

std::string decode_utf8_lossy(std::string_view value) {
    constexpr std::string_view replacement = "\xef\xbf\xbd";
    std::string output;
    output.reserve(value.size());
    for (std::size_t position = 0; position < value.size();) {
        const auto lead = static_cast<unsigned char>(value[position]);
        if (lead < 0x80) {
            output.push_back(static_cast<char>(lead));
            ++position;
            continue;
        }

        std::size_t length = 0;
        unsigned char first_minimum = 0x80;
        unsigned char first_maximum = 0xbf;
        if (lead >= 0xc2 && lead <= 0xdf) {
            length = 2;
        } else if (lead >= 0xe0 && lead <= 0xef) {
            length = 3;
            if (lead == 0xe0) first_minimum = 0xa0;
            else if (lead == 0xed) first_maximum = 0x9f;
        } else if (lead >= 0xf0 && lead <= 0xf4) {
            length = 4;
            if (lead == 0xf0) first_minimum = 0x90;
            else if (lead == 0xf4) first_maximum = 0x8f;
        } else {
            output += replacement;
            ++position;
            continue;
        }

        if (position + 1 >= value.size()) {
            output += replacement;
            ++position;
            continue;
        }
        const auto first = static_cast<unsigned char>(value[position + 1]);
        if (first < first_minimum || first > first_maximum) {
            output += replacement;
            ++position;
            continue;
        }

        std::size_t consumed = 2;
        while (consumed < length && position + consumed < value.size()) {
            const auto continuation =
                static_cast<unsigned char>(value[position + consumed]);
            if (continuation < 0x80 || continuation > 0xbf) break;
            ++consumed;
        }
        if (consumed < length) {
            // Once a valid prefix has begun, CPython consumes that entire
            // prefix as one malformed subsequence, whether it ended at EOF or
            // at a non-continuation byte.
            output += replacement;
            position += consumed;
            continue;
        }
        output.append(value.substr(position, length));
        position += length;
    }
    return output;
}

std::string JsonValue::dump() const {
    std::string output;
    dump_json(*this, output, std::nullopt, 0);
    return output;
}

std::string JsonValue::dump_pretty(std::size_t indentation) const {
    std::string output;
    dump_json(*this, output, indentation, 0);
    return output;
}

std::string json_escape(std::string_view value) {
    std::string output;
    output.push_back('"');
    constexpr char hexadecimal[] = "0123456789abcdef";
    const auto append_quad = [&](std::uint32_t codepoint) {
        output += "\\u";
        output.push_back(hexadecimal[(codepoint >> 12) & 0x0f]);
        output.push_back(hexadecimal[(codepoint >> 8) & 0x0f]);
        output.push_back(hexadecimal[(codepoint >> 4) & 0x0f]);
        output.push_back(hexadecimal[codepoint & 0x0f]);
    };
    for (std::size_t position = 0; position < value.size();) {
        const auto character = static_cast<unsigned char>(value[position]);
        switch (character) {
        case '"': output += "\\\""; ++position; break;
        case '\\': output += "\\\\"; ++position; break;
        case '\b': output += "\\b"; ++position; break;
        case '\f': output += "\\f"; ++position; break;
        case '\n': output += "\\n"; ++position; break;
        case '\r': output += "\\r"; ++position; break;
        case '\t': output += "\\t"; ++position; break;
        default:
            if (character < 0x20) {
                output += "\\u00";
                output.push_back(hexadecimal[character >> 4]);
                output.push_back(hexadecimal[character & 0x0f]);
                ++position;
                break;
            }
            if (character < 0x80) {
                if (character == 0x7f) append_quad(character);
                else output.push_back(static_cast<char>(character));
                ++position;
                break;
            }

            std::size_t length = 0;
            std::uint32_t codepoint = 0;
            std::uint32_t minimum = 0;
            if (character >= 0xc2 && character <= 0xdf) {
                length = 2; codepoint = character & 0x1f; minimum = 0x80;
            } else if (character >= 0xe0 && character <= 0xef) {
                length = 3; codepoint = character & 0x0f; minimum = 0x800;
            } else if (character >= 0xf0 && character <= 0xf4) {
                length = 4; codepoint = character & 0x07; minimum = 0x10000;
            }
            bool valid = length != 0 && position + length <= value.size();
            for (std::size_t index = 1; valid && index < length; ++index) {
                const auto continuation =
                    static_cast<unsigned char>(value[position + index]);
                if ((continuation & 0xc0) != 0x80) {
                    valid = false;
                } else {
                    codepoint = (codepoint << 6) | (continuation & 0x3f);
                }
            }
            if (!valid || codepoint < minimum || codepoint > 0x10ffff) {
                // Keep serialization valid for byte strings that could not
                // have originated from a Python str.  Normal runtime inputs
                // are UTF-8 or have already passed through a lossy decoder.
                output += "\\u00";
                output.push_back(hexadecimal[character >> 4]);
                output.push_back(hexadecimal[character & 0x0f]);
                ++position;
                break;
            }
            if (codepoint <= 0xffff) {
                append_quad(codepoint);
            } else {
                codepoint -= 0x10000;
                append_quad(0xd800 + (codepoint >> 10));
                append_quad(0xdc00 + (codepoint & 0x3ff));
            }
            position += length;
            break;
        }
    }
    output.push_back('"');
    return output;
}

} // namespace tungsten
