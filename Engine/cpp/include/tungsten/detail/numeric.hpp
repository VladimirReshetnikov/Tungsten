#pragma once

#include <charconv>
#include <cmath>
#include <gmpxx.h>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>

namespace tungsten::detail {

// Parse the invariant decimal syntax used by Wolfram and JSON numeric text.
// Unlike strtod/stod this is unaffected by the process C locale.  A leading
// plus is accepted to match Python float and Wolfram real spellings even
// though std::from_chars intentionally accepts only a leading minus.
inline std::optional<double> parse_ascii_double(std::string_view text) noexcept {
    if (text.empty()) return std::nullopt;
    if (text.front() == '+') {
        text.remove_prefix(1);
        if (text.empty() || text.front() == '+' || text.front() == '-')
            return std::nullopt;
    }
    double value = 0.0;
    const auto result = std::from_chars(
        text.data(), text.data() + text.size(), value, std::chars_format::general);
    if (result.ec != std::errc{} || result.ptr != text.data() + text.size())
        return std::nullopt;
    return std::isfinite(value) ? std::optional<double>(value) : std::nullopt;
}

// Spell a finite binary64 value like Python repr(float), then project its
// exponent marker into Wolfram syntax.  Precision-less to_chars already gives
// the same shortest round-tripping digits, but its fixed/scientific choice is
// implementation-defined; Python uses fixed form for decimal exponents in
// [-4, 15].
inline std::string python_machine_real_text(double value) {
    char buffer[128];
    const auto converted = std::to_chars(
        buffer, buffer + sizeof(buffer), value, std::chars_format::general);
    if (converted.ec != std::errc{})
        throw std::invalid_argument("could not format a machine real");
    std::string text(buffer, converted.ptr);
    const auto exponent_marker = text.find_first_of("eE");
    if (exponent_marker != std::string::npos) {
        auto exponent_text = std::string_view(text).substr(exponent_marker + 1);
        if (!exponent_text.empty() && exponent_text.front() == '+')
            exponent_text.remove_prefix(1);
        int exponent = 0;
        const auto parsed = std::from_chars(
            exponent_text.data(), exponent_text.data() + exponent_text.size(), exponent);
        if (parsed.ec != std::errc{}
            || parsed.ptr != exponent_text.data() + exponent_text.size())
            throw std::invalid_argument("could not format a machine-real exponent");
        if (exponent >= -4 && exponent < 16) {
            const bool negative = !text.empty() && text.front() == '-';
            const auto mantissa_start = negative ? std::size_t{1} : std::size_t{0};
            auto digits = text.substr(
                mantissa_start, exponent_marker - mantissa_start);
            if (const auto point = digits.find('.'); point != std::string::npos)
                digits.erase(point, 1);
            const auto decimal_position = static_cast<long long>(exponent) + 1;
            std::string fixed = negative ? "-" : "";
            if (decimal_position <= 0) {
                fixed += "0.";
                fixed.append(static_cast<std::size_t>(-decimal_position), '0');
                fixed += digits;
            } else if (static_cast<std::size_t>(decimal_position) >= digits.size()) {
                fixed += digits;
                fixed.append(
                    static_cast<std::size_t>(decimal_position) - digits.size(), '0');
            } else {
                fixed.append(digits, 0, static_cast<std::size_t>(decimal_position));
                fixed.push_back('.');
                fixed.append(digits, static_cast<std::size_t>(decimal_position));
            }
            text = std::move(fixed);
        }
    }
    if (text.size() >= 2 && text.compare(text.size() - 2, 2, ".0") == 0)
        text.erase(text.size() - 1);
    if (const auto exponent = text.find_first_of("eE"); exponent != std::string::npos)
        text.replace(exponent, 1, "*^");
    if (text.find('.') == std::string::npos && text.find("*^") == std::string::npos)
        text.push_back('.');
    return text;
}

namespace numeric_detail {

inline mpq_class exact_rational(double value) {
    mpq_class result;
    mpq_set_d(result.get_mpq_t(), value);
    return result;
}

inline bool has_even_significand(double value) {
    if (value == 0.0) return true;
    static_assert(std::numeric_limits<double>::radix == 2,
        "correctly_rounded_double requires a binary floating-point type");
    double significand;
    if (value < std::numeric_limits<double>::min()) {
        significand = std::scalbn(
            value,
            std::numeric_limits<double>::digits
                - std::numeric_limits<double>::min_exponent);
    } else {
        int exponent = 0;
        const auto fraction = std::frexp(value, &exponent);
        significand = std::ldexp(
            fraction, std::numeric_limits<double>::digits);
    }
    return std::fmod(significand, 2.0) == 0.0;
}

} // namespace numeric_detail

// GMP's mpq_get_d deliberately truncates toward zero.  CPython converts int
// and Fraction values to binary64 with round-to-nearest, ties-to-even.  Start
// from GMP's adjacent lower-magnitude value, then select between it and the
// next representable value by comparing their exact rational midpoint.
inline double correctly_rounded_double(const mpq_class& value) {
    if (value == 0) return 0.0;
    const bool negative = value < 0;
    const mpq_class magnitude = negative ? -value : value;
    const auto lower = magnitude.get_d();
    if (!std::isfinite(lower))
        throw std::overflow_error("integer division result too large for a float");

    const auto lower_exact = numeric_detail::exact_rational(lower);
    double rounded = lower;
    if (lower == std::numeric_limits<double>::max()) {
        const auto previous = std::nextafter(lower, 0.0);
        const auto previous_exact = numeric_detail::exact_rational(previous);
        const mpq_class overflow_threshold =
            lower_exact + (lower_exact - previous_exact) / 2;
        if (magnitude >= overflow_threshold)
            throw std::overflow_error("integer division result too large for a float");
    } else {
        const auto upper = std::nextafter(
            lower, std::numeric_limits<double>::infinity());
        const auto upper_exact = numeric_detail::exact_rational(upper);
        const mpq_class midpoint = (lower_exact + upper_exact) / 2;
        if (magnitude > midpoint
            || (magnitude == midpoint
                && !numeric_detail::has_even_significand(lower))) {
            rounded = upper;
        }
    }
    return negative ? -rounded : rounded;
}

inline double correctly_rounded_double(const mpz_class& value) {
    return correctly_rounded_double(mpq_class(value));
}

} // namespace tungsten::detail
