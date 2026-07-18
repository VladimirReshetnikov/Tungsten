#include "tungsten/json.hpp"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <string>

namespace {

int failures = 0;

void check(bool condition, const std::string& message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

void check_equal(
    const std::string& actual,
    const std::string& expected,
    const std::string& message) {
    if (actual != expected) {
        std::cerr << "FAIL: " << message << "\n  expected: " << expected
                  << "\n  actual:   " << actual << '\n';
        ++failures;
    }
}

void expect_parse_error(std::string_view source, const std::string& message) {
    try {
        (void)tungsten::JsonValue::parse(source);
        check(false, message);
    } catch (const tungsten::JsonError&) {
    }
}

template<typename Function>
void expect_length_error(Function&& function, const std::string& message) {
    try {
        function();
        check(false, message);
    } catch (const std::length_error&) {
    }
}

} // namespace

int main() {
    using tungsten::JsonValue;

    check_equal(tungsten::decode_utf8_lossy(std::string("\xe2\x82", 2)),
        u8"\ufffd", "truncated UTF-8 is one replacement subsequence");
    check_equal(tungsten::decode_utf8_lossy(std::string("\xe2\x82" "A", 3)),
        u8"\ufffd" "A",
        "valid UTF-8 prefix before a non-continuation is one replacement");
    check_equal(tungsten::decode_utf8_lossy(std::string("\xe0\x80\x80", 3)),
        u8"\ufffd\ufffd\ufffd",
        "overlong UTF-8 emits one replacement per invalid byte");
    check_equal(tungsten::decode_utf8_lossy(std::string("\xed\xa0\x80", 3)),
        u8"\ufffd\ufffd\ufffd",
        "UTF-8 surrogate encoding emits one replacement per invalid byte");

    const auto payload = JsonValue::parse(
        R"({"array":[null,true,false,-12,3.5e+2],"text":"a\n\u03b1\ud83d\ude00"})");
    check(payload.is_object(), "object parsing");
    check(payload.at("array").is_array(), "array parsing");
    check(payload.at("array").at(1).as_boolean(), "boolean parsing");
    check(payload.at("array").at(3).as_int64() == -12, "integer conversion");
    check(payload.at("array").at(4).as_double() == 350.0, "real conversion");
    check(!JsonValue::parse("1e9999").as_double(),
        "out-of-range JSON double conversion is rejected");
    check_equal(payload.at("text").as_string(), u8"a\nα😀", "Unicode escape decoding");

    check_equal(
        payload.dump(),
        R"({"array":[null,true,false,-12,3.5e+2],"text":"a\n\u03b1\ud83d\ude00"})",
        "compact serialization");
    check_equal(
        payload.dump_pretty(2),
        u8"{\n"
        "  \"array\": [\n"
        "    null,\n"
        "    true,\n"
        "    false,\n"
        "    -12,\n"
        "    3.5e+2\n"
        "  ],\n"
        "  \"text\": \"a\\n\\u03b1\\ud83d\\ude00\"\n"
        "}",
        "pretty serialization");

    auto built = JsonValue::object({
        {"name", "Tungsten"},
        {"success", true},
        {"values", JsonValue::Array{1, 2, 3}},
    });
    built["nested"]["value"] = 42;
    built["values"].push_back(4);
    const std::string_view nested_key = "nested";
    check(built.find(nested_key) != nullptr && built.contains(nested_key),
        "string-view object lookup is allocation-free and available through the public API");
    check_equal(
        built.dump(),
        R"({"name":"Tungsten","nested":{"value":42},"success":true,"values":[1,2,3,4]})",
        "programmatic object and array construction");

    const auto duplicate = JsonValue::parse(R"({"key":1,"key":2})");
    check(duplicate.at("key").as_int64() == 2, "duplicate object key uses last value");
    check(JsonValue::parse("-0").as_int64() == 0, "negative zero integer conversion");
    check_equal(JsonValue(-0.0).dump(), "-0.0", "negative zero formatting");
    check_equal(JsonValue(0.0).dump(), "0.0", "floating zero retains its type spelling");
    check_equal(JsonValue(1.0).dump(), "1.0", "integral double retains its type spelling");
    check_equal(JsonValue(0.1).dump(), "0.1", "double uses shortest round-trip spelling");
    check_equal(JsonValue(1.2345).dump(), "1.2345",
        "double serialization does not expose binary approximation noise");
    check_equal(JsonValue(1.0e15).dump(), "1000000000000000.0",
        "double formatting uses Python's fixed-notation exponent range");
    check_equal(JsonValue(1.0e16).dump(), "1e+16",
        "double formatting uses scientific notation at exponent sixteen");
    check_equal(
        tungsten::json_escape(std::string("\0\x01\b\f\n\r\t\"\\", 9)),
        R"("\u0000\u0001\b\f\n\r\t\"\\")",
        "control-character escaping");
    check_equal(tungsten::json_escape(u8"α😀"),
        R"("\u03b1\ud83d\ude00")",
        "non-ASCII JSON escaping matches Python ensure_ascii defaults");
    check_equal(tungsten::json_escape(std::string(1, '\x7f')),
        R"("\u007f")", "DEL escaping matches Python ensure_ascii defaults");

    expect_parse_error("", "empty input rejected");
    expect_parse_error("01", "leading zero rejected");
    expect_parse_error("1.", "missing fraction rejected");
    expect_parse_error("1e", "missing exponent rejected");
    expect_parse_error("[1,]", "trailing array comma rejected");
    expect_parse_error(R"({"a":1,})", "trailing object comma rejected");
    expect_parse_error(R"("\ud800")", "unpaired high surrogate rejected");
    expect_parse_error(R"("\udc00")", "unpaired low surrogate rejected");
    expect_parse_error("true false", "trailing input rejected");
    expect_length_error(
        [&] {
            (void)JsonValue(JsonValue::Array{JsonValue::Array{1}})
                .dump_pretty(std::numeric_limits<std::size_t>::max());
        },
        "oversized pretty-print indentation is rejected before size arithmetic wraps");

    try {
        (void)JsonValue(std::numeric_limits<double>::infinity());
        check(false, "non-finite number rejected");
    } catch (const std::invalid_argument&) {
    }

    if (failures != 0) {
        std::cerr << failures << " JSON test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all C++ JSON tests passed\n";
    return EXIT_SUCCESS;
}
