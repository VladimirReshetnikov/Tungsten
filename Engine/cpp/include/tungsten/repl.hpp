#pragma once

#include "tungsten/evaluator.hpp"
#include "tungsten/expression.hpp"

#include <cstddef>
#include <iosfwd>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace tungsten {

inline constexpr const char* repl_version = "0.1.0";

[[nodiscard]] std::string repl_banner();

using DisplayOutputParts = std::pair<std::optional<std::string>, std::string>;

[[nodiscard]] DisplayOutputParts display_output_parts(const Expr& expression);
[[nodiscard]] std::string apply_output_size_limit(
    const Expr& expression,
    const std::string& text,
    std::optional<std::size_t> limit);

struct SessionOutput {
    enum class Kind { Value, Exit };

    Kind kind = Kind::Value;
    int exit_code = 0;
    std::size_t line = 0;
    Expr result;
    std::vector<std::string> prints;
    std::vector<std::string> messages;

    [[nodiscard]] bool is_exit() const noexcept { return kind == Kind::Exit; }
};

class EvaluationSession {
public:
    EvaluationSession();

    [[nodiscard]] std::size_t line() const noexcept { return line_; }
    [[nodiscard]] SessionOutput evaluate_input(const std::string& source);
    [[nodiscard]] Expr preprint(const Expr& result);
    [[nodiscard]] std::optional<std::size_t> output_size_limit();

private:
    [[nodiscard]] std::string apply_pre_read(
        const std::string& source,
        std::vector<std::string>& prints,
        std::vector<Expr>& message_names,
        std::vector<std::string>& messages);
    [[nodiscard]] Expr apply_hook(
        const std::string& name,
        const Expr& expression,
        std::vector<std::string>* prints,
        std::vector<Expr>* message_names,
        std::vector<std::string>* messages);
    [[nodiscard]] Expr replace_session_references(
        const Expr& expression,
        std::set<std::size_t>& expanding_inputs);
    [[nodiscard]] std::optional<std::size_t> history_index(
        const std::vector<Expr>& arguments) const;
    void collect_effects(
        std::vector<std::string>& prints,
        std::vector<Expr>& message_names,
        std::vector<std::string>& messages) const;
    void prune_history();

    Evaluator evaluator_;
    std::size_t line_ = 0;
    std::map<std::size_t, std::string> input_strings_;
    std::map<std::size_t, Expr> inputs_;
    std::map<std::size_t, Expr> outputs_;
    std::map<std::size_t, std::vector<Expr>> message_history_;
};

int run_repl(
    std::istream& input,
    std::ostream& output,
    std::ostream& error,
    bool show_banner = true);

} // namespace tungsten
