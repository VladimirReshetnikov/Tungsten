#pragma once

#include "tungsten/expression.hpp"

#include <stdexcept>
#include <string>

namespace tungsten {

enum class ParseForm { Input, Full, Standard };

class ParseError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

[[nodiscard]] Expr parse_expression(
    const std::string& text, ParseForm form = ParseForm::Input);
[[nodiscard]] Expr parse_input_form(const std::string& text);
[[nodiscard]] Expr parse_full_form(const std::string& text);
[[nodiscard]] Expr parse_standard_form(const std::string& text);
[[nodiscard]] Expr interpret_standard_form(const Expr& expression);
[[nodiscard]] std::string box_item_to_standard_text(const Expr& expression);

} // namespace tungsten
