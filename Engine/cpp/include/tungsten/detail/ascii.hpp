#pragma once

namespace tungsten::detail {

constexpr bool ascii_is_digit(unsigned char value) noexcept {
    return value >= static_cast<unsigned char>('0')
        && value <= static_cast<unsigned char>('9');
}

constexpr bool ascii_is_lower(unsigned char value) noexcept {
    return value >= static_cast<unsigned char>('a')
        && value <= static_cast<unsigned char>('z');
}

constexpr bool ascii_is_upper(unsigned char value) noexcept {
    return value >= static_cast<unsigned char>('A')
        && value <= static_cast<unsigned char>('Z');
}

constexpr bool ascii_is_alpha(unsigned char value) noexcept {
    return ascii_is_lower(value) || ascii_is_upper(value);
}

constexpr bool ascii_is_alnum(unsigned char value) noexcept {
    return ascii_is_alpha(value) || ascii_is_digit(value);
}

constexpr bool ascii_is_hex_digit(unsigned char value) noexcept {
    return ascii_is_digit(value)
        || (value >= static_cast<unsigned char>('a')
            && value <= static_cast<unsigned char>('f'))
        || (value >= static_cast<unsigned char>('A')
            && value <= static_cast<unsigned char>('F'));
}

constexpr bool ascii_is_space(unsigned char value) noexcept {
    return value == static_cast<unsigned char>(' ')
        || value == static_cast<unsigned char>('\t')
        || value == static_cast<unsigned char>('\n')
        || value == static_cast<unsigned char>('\r')
        || value == static_cast<unsigned char>('\f')
        || value == static_cast<unsigned char>('\v');
}

constexpr char ascii_lower(unsigned char value) noexcept {
    return ascii_is_upper(value)
        ? static_cast<char>(value + static_cast<unsigned char>('a' - 'A'))
        : static_cast<char>(value);
}

} // namespace tungsten::detail
