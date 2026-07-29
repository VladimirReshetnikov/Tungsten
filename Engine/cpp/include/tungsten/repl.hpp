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
    std::vector<Expr> message_names;

    [[nodiscard]] bool is_exit() const noexcept { return kind == Kind::Exit; }
    [[nodiscard]] std::vector<EvaluationMessage> evaluation_messages() const;
};

class EvaluationSession {
public:
    EvaluationSession();
    EvaluationSession(const EvaluationSession& other);
    EvaluationSession(EvaluationSession&& other);
    EvaluationSession& operator=(const EvaluationSession& other);
    EvaluationSession& operator=(EvaluationSession&& other);

    [[nodiscard]] std::size_t line() const noexcept { return line_; }
    // History lookups return independent snapshots. A missing optional means that the line
    // never existed or has been pruned; retained effect histories use an empty vector when the
    // line produced no such effects. Exit lines retain their input and effect histories but do
    // not have an output history entry.
    [[nodiscard]] std::optional<std::string> input_string(std::size_t line) const;
    [[nodiscard]] std::optional<Expr> input(std::size_t line) const;
    [[nodiscard]] std::optional<Expr> output(std::size_t line) const;
    [[nodiscard]] std::optional<std::vector<Expr>> message_names(std::size_t line) const;
    [[nodiscard]] std::optional<std::vector<std::string>> message_texts(
        std::size_t line) const;
    [[nodiscard]] std::optional<std::vector<EvaluationMessage>> evaluation_messages(
        std::size_t line) const;
    [[nodiscard]] std::optional<std::vector<std::string>> prints(std::size_t line) const;
    [[nodiscard]] const Evaluator& evaluator() const noexcept { return evaluator_; }
    [[nodiscard]] SessionOutput evaluate_input(const std::string& source);
    [[nodiscard]] SessionOutput evaluate_expression(
        const std::string& source,
        const Expr& expression);
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
    [[nodiscard]] SessionOutput evaluate_prepared_input(
        const std::string& source,
        const Expr& expression,
        std::vector<std::string> prints,
        std::vector<Expr> message_names,
        std::vector<std::string> messages);
    void refresh_evaluator_session_context();
    void prune_history();

    Evaluator evaluator_;
    std::size_t line_ = 0;
    std::map<std::size_t, std::string> input_strings_;
    std::map<std::size_t, Expr> inputs_;
    std::map<std::size_t, Expr> outputs_;
    std::map<std::size_t, std::vector<Expr>> message_history_;
    std::map<std::size_t, std::vector<std::string>> message_text_history_;
    std::map<std::size_t, std::vector<std::string>> print_history_;
    std::set<std::size_t> evaluating_input_history_;
    std::vector<Expr> current_generated_messages_;
};

int run_repl(
    std::istream& input,
    std::ostream& output,
    std::ostream& error,
    bool show_banner = true);

} // namespace tungsten
