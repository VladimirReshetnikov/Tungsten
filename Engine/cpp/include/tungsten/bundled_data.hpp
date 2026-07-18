#pragma once

#include <string_view>

namespace tungsten {

[[nodiscard]] std::string_view bundled_system_symbols_json() noexcept;
[[nodiscard]] std::string_view bundled_named_characters_json() noexcept;

} // namespace tungsten
