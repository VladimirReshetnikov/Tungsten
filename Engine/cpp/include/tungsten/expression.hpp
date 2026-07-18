#pragma once

#include <cstddef>
#include <cstdint>
#include <gmpxx.h>
#include <memory>
#include <optional>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

namespace tungsten {

class Expr;
struct ExprNode;

enum class ExprKind {
    Symbol,
    Integer,
    Real,
    Rational,
    Complex,
    Root,
    SpecialReal,
    String,
    ByteArray,
    SparseArray,
    Call,
};

struct SparseEntry;

class Expr {
public:
    Expr();
    Expr(const Expr&) noexcept = default;
    Expr& operator=(const Expr&) noexcept = default;
    Expr(Expr&& other) noexcept;
    Expr& operator=(Expr&& other) noexcept;

    [[nodiscard]] ExprKind kind() const noexcept;
    [[nodiscard]] std::size_t length() const noexcept;
    [[nodiscard]] std::size_t depth() const noexcept;
    [[nodiscard]] Expr head() const;
    [[nodiscard]] const std::vector<Expr>& args() const noexcept;
    [[nodiscard]] bool is_atom() const noexcept;
    [[nodiscard]] const std::string* symbol_name() const noexcept;
    [[nodiscard]] bool has_head(const std::string& expected) const noexcept;

    [[nodiscard]] const std::string& text() const;
    [[nodiscard]] const mpz_class& integer_value() const;
    [[nodiscard]] const mpq_class& rational_value() const;
    [[nodiscard]] Expr real_part() const;
    [[nodiscard]] Expr imaginary_part() const;
    [[nodiscard]] const std::vector<mpz_class>& root_coefficients() const;
    [[nodiscard]] std::size_t root_index() const;
    [[nodiscard]] long root_method() const;
    [[nodiscard]] const std::vector<std::uint8_t>& bytes() const;
    [[nodiscard]] const std::vector<std::size_t>& dimensions() const;
    [[nodiscard]] const std::vector<SparseEntry>& sparse_entries() const;
    [[nodiscard]] Expr fill_value() const;

    [[nodiscard]] std::string to_full_form() const;
    [[nodiscard]] std::string to_input_form() const;
    [[nodiscard]] std::string to_json() const;

    friend bool operator==(const Expr& left, const Expr& right) noexcept;
    friend bool operator!=(const Expr& left, const Expr& right) noexcept {
        return !(left == right);
    }

private:
    explicit Expr(std::shared_ptr<const ExprNode> node);
    std::shared_ptr<const ExprNode> node_;

    friend Expr symbol(std::string name);
    friend Expr integer(mpz_class value);
    friend Expr real(std::string text);
    friend Expr rational(mpz_class numerator, mpz_class denominator);
    friend Expr complex(Expr real_value, Expr imaginary_value);
    friend Expr special_real(std::string name);
    friend Expr string(std::string value);
    friend Expr byte_array(std::vector<std::uint8_t> values);
    friend Expr root(std::vector<mpz_class> coefficients, std::size_t index, long method);
    friend Expr sparse_array(
        std::vector<std::size_t> dimensions,
        std::vector<SparseEntry> entries,
        Expr fill_value);
    friend Expr call(Expr head, std::vector<Expr> args);
};

struct SparseEntry {
    std::vector<std::size_t> indices;
    Expr value;

    friend bool operator==(const SparseEntry& left, const SparseEntry& right) noexcept {
        return left.indices == right.indices && left.value == right.value;
    }
};

Expr symbol(std::string name);
Expr integer(mpz_class value);

// GMP's C++ constructors only provide a subset of the standard integral
// widths.  In particular, passing size_t/std::int64_t directly is ambiguous
// on common LLP64 targets.  Normalize every standard integral type through a
// decimal spelling so this overload set is complete without typedef-dependent
// duplicate declarations.
template<typename Integral,
    std::enable_if_t<std::is_integral_v<std::remove_cv_t<Integral>>, int> = 0>
Expr integer(Integral value) {
    using Value = std::remove_cv_t<Integral>;
    if constexpr (std::is_same_v<Value, bool>) {
        return integer(mpz_class(value ? 1L : 0L));
    } else {
        using Unsigned = std::make_unsigned_t<Value>;
        const auto unsigned_value = static_cast<Unsigned>(value);
        if constexpr (std::is_signed_v<Value>) {
            if (value < 0) {
                const auto magnitude = static_cast<Unsigned>(Unsigned{0} - unsigned_value);
                return integer(mpz_class(
                    "-" + std::to_string(static_cast<unsigned long long>(magnitude)), 10));
            }
        }
        return integer(mpz_class(
            std::to_string(static_cast<unsigned long long>(unsigned_value)), 10));
    }
}
Expr real(std::string text);
Expr rational(mpz_class numerator, mpz_class denominator);
Expr complex(Expr real_value, Expr imaginary_value);
Expr special_real(std::string name);
Expr string(std::string value);
Expr byte_array(std::vector<std::uint8_t> values);
Expr root(std::vector<mpz_class> coefficients, std::size_t index, long method = 0);
Expr sparse_array(
    std::vector<std::size_t> dimensions,
    std::vector<SparseEntry> entries,
    Expr fill_value = integer(0L));
Expr call(Expr head, std::vector<Expr> args = {});
Expr call(const std::string& head, std::vector<Expr> args = {});
Expr list(std::vector<Expr> items = {});

[[nodiscard]] std::string system_dispatch_name(const std::string& name);

} // namespace tungsten
