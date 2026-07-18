#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <initializer_list>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace tungsten {

class JsonError : public std::runtime_error {
public:
    JsonError(std::string message, std::size_t offset);

    [[nodiscard]] std::size_t offset() const noexcept;

private:
    std::size_t offset_;
};

class JsonValue {
public:
    struct Number {
        std::string text;

        friend bool operator==(const Number& left, const Number& right) noexcept {
            return left.text == right.text;
        }
    };

    using Array = std::vector<JsonValue>;
    // Transparent comparison lets the noexcept string-view lookup overloads
    // avoid allocating a temporary std::string.
    using Object = std::map<std::string, JsonValue, std::less<>>;

    enum class Type {
        Null,
        Boolean,
        Number,
        String,
        Array,
        Object,
    };

    JsonValue() noexcept;
    JsonValue(std::nullptr_t) noexcept;
    JsonValue(bool value);
    JsonValue(int value);
    JsonValue(long value);
    JsonValue(long long value);
    JsonValue(unsigned value);
    JsonValue(unsigned long value);
    JsonValue(unsigned long long value);
    JsonValue(double value);
    JsonValue(const char* value);
    JsonValue(std::string value);
    JsonValue(Array value);
    JsonValue(Object value);
    JsonValue(std::initializer_list<JsonValue> values);

    static JsonValue number(std::string text);
    static JsonValue object(
        std::initializer_list<std::pair<const std::string, JsonValue>> values);
    static JsonValue parse(std::string_view source);

    [[nodiscard]] Type type() const noexcept;
    [[nodiscard]] bool is_null() const noexcept;
    [[nodiscard]] bool is_boolean() const noexcept;
    [[nodiscard]] bool is_number() const noexcept;
    [[nodiscard]] bool is_string() const noexcept;
    [[nodiscard]] bool is_array() const noexcept;
    [[nodiscard]] bool is_object() const noexcept;

    [[nodiscard]] bool as_boolean() const;
    [[nodiscard]] const Number& as_number() const;
    [[nodiscard]] std::optional<std::int64_t> as_int64() const noexcept;
    [[nodiscard]] std::optional<std::uint64_t> as_uint64() const noexcept;
    [[nodiscard]] std::optional<double> as_double() const noexcept;
    [[nodiscard]] const std::string& as_string() const;
    [[nodiscard]] const Array& as_array() const;
    [[nodiscard]] Array& as_array();
    [[nodiscard]] const Object& as_object() const;
    [[nodiscard]] Object& as_object();

    [[nodiscard]] bool contains(std::string_view key) const noexcept;
    [[nodiscard]] const JsonValue* find(std::string_view key) const noexcept;
    [[nodiscard]] JsonValue* find(std::string_view key) noexcept;
    [[nodiscard]] const JsonValue& at(std::string_view key) const;
    [[nodiscard]] JsonValue& at(std::string_view key);
    [[nodiscard]] const JsonValue& at(std::size_t index) const;
    [[nodiscard]] JsonValue& at(std::size_t index);
    JsonValue& operator[](const std::string& key);
    JsonValue& operator[](std::size_t index);
    void push_back(JsonValue value);
    [[nodiscard]] std::size_t size() const noexcept;

    [[nodiscard]] std::string dump() const;
    [[nodiscard]] std::string dump_pretty(std::size_t indentation = 2) const;

    friend bool operator==(const JsonValue& left, const JsonValue& right) noexcept {
        return left.value_ == right.value_;
    }
    friend bool operator!=(const JsonValue& left, const JsonValue& right) noexcept {
        return !(left == right);
    }

private:
    using Storage = std::variant<std::nullptr_t, bool, Number, std::string, Array, Object>;

    explicit JsonValue(Number value);
    Storage value_;
};

[[nodiscard]] std::string json_escape(std::string_view value);
// Decode UTF-8 with the same replacement boundaries as
// ``bytes.decode("utf-8", errors="replace")`` in the compatibility oracle.
[[nodiscard]] std::string decode_utf8_lossy(std::string_view value);

} // namespace tungsten
