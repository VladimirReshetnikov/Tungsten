#pragma once

#include <cstdint>
#include <string>

namespace tungsten {
class Expr;
namespace detail {
[[nodiscard]] std::string format_input(const Expr& expression, std::uint16_t parent_precedence);
}
} // namespace tungsten
