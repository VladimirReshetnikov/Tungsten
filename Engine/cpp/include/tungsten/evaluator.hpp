#pragma once

#include "tungsten/expression.hpp"

#include <cstddef>
#include <optional>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

namespace tungsten {

struct EvaluationMessage {
    Expr name;
    std::string text;

    [[nodiscard]] Expr name_expr() const {
        return call("HoldForm", {name});
    }

    friend bool operator==(
        const EvaluationMessage& left, const EvaluationMessage& right) {
        return left.name == right.name && left.text == right.text;
    }
    friend bool operator!=(
        const EvaluationMessage& left, const EvaluationMessage& right) {
        return !(left == right);
    }
};

struct EvaluationResult {
    Expr result;
    std::vector<EvaluationMessage> messages;
    std::vector<std::string> prints;
};

struct SymbolInfo {
    std::string full_name;
    std::string context;
    std::string short_name;
    bool built_in = false;
    std::set<std::string> attributes;
};

enum class ValueKind { Own, Down, Up, Sub, N };

class Evaluator {
public:
    Evaluator();

    [[nodiscard]] Expr evaluate(const Expr& expression);
    [[nodiscard]] EvaluationResult evaluate_result(const Expr& expression);
    [[nodiscard]] std::optional<SymbolInfo> symbol_info(
        const Expr& symbol_expression) const;
    [[nodiscard]] std::vector<Expr> value_rules(
        const Expr& symbol_expression, ValueKind kind) const;
    [[nodiscard]] const std::vector<Expr>& messages() const noexcept { return messages_; }
    [[nodiscard]] const std::vector<std::string>& message_texts() const noexcept { return message_texts_; }
    [[nodiscard]] const std::vector<std::string>& prints() const noexcept { return prints_; }

private:
    struct Definition { Expr value; bool delayed = false; };
    struct PatternDefinition {
        Expr lhs;
        Expr value;
        bool delayed = false;
    };
    using PatternDefinitions = std::vector<PatternDefinition>;
    using DefinitionTable = std::unordered_map<std::string, PatternDefinitions>;
    struct ReapScope {
        Expr selector;
        std::vector<std::pair<Expr, Expr>> entries;
    };
    struct MessageScope {
        bool quiet = false;
        std::vector<Expr> selectors;
        bool triggered = false;
    };
    enum class ControlKind { None, Break, Continue, Return, Goto };
    Expr evaluate_impl(const Expr& expression);
    Expr evaluate_call(const Expr& head, const std::vector<Expr>& args);
    void emit_message(const Expr& name, std::string text);
    [[nodiscard]] bool message_is_enabled(const Expr& name) const;
    [[nodiscard]] bool control_active() const noexcept;
    [[nodiscard]] Expr control_expression() const;
    void clear_control() noexcept;
    [[nodiscard]] std::string resolve_full_symbol_name(
        const std::string& symbol_name) const;
    [[nodiscard]] std::string ensure_full_symbol_name(
        const std::string& symbol_name);
    [[nodiscard]] bool is_built_in_full_name(
        const std::string& full_name) const;
    void register_expression_symbols(const Expr& expression);
    [[nodiscard]] bool tag_occurs_in_upvalue_position(
        const std::string& full_tag, const Expr& expression) const;
    [[nodiscard]] Expr normalize_assignment_lhs(const Expr& expression);
    [[nodiscard]] std::set<std::string> attributes_for(const Expr& symbol_expression) const;
    [[nodiscard]] bool symbol_has_attribute(
        const std::string& symbol_name, const std::string& attribute) const;
    [[nodiscard]] std::optional<Expr> apply_definitions(
        const Expr& expression, const PatternDefinitions& definitions);
    [[nodiscard]] std::optional<Expr> apply_down_values(const Expr& expression);
    [[nodiscard]] std::optional<Expr> apply_up_values(const Expr& expression);
    [[nodiscard]] std::optional<Expr> apply_sub_values(const Expr& expression);

    std::size_t depth_ = 0;
    std::size_t recursion_limit_ = 1024;
    std::size_t module_counter_ = 0;
    std::size_t abort_protection_depth_ = 0;
    std::unordered_map<std::string, std::size_t> unique_string_counters_;
    std::unordered_map<std::string, Definition> own_values_;
    DefinitionTable down_values_;
    DefinitionTable up_values_;
    DefinitionTable sub_values_;
    std::unordered_map<std::string, std::set<std::string>> user_attributes_;
    std::set<std::string> unprotected_symbols_;
    std::set<std::string> known_symbols_;
    std::vector<std::string> active_own_values_;
    std::optional<Expr> thrown_;
    std::optional<Expr> thrown_tag_;
    std::optional<Expr> thrown_handler_;
    std::optional<Expr> confirmation_failure_;
    std::optional<Expr> confirmation_information_;
    std::optional<Expr> confirmation_function_;
    std::optional<Expr> confirmation_pattern_;
    std::optional<Expr> confirmation_tag_;
    std::vector<ReapScope> reap_stack_;
    std::vector<MessageScope> message_scopes_;
    std::set<std::string> disabled_messages_;
    std::set<std::string> disabled_message_heads_;
    bool assert_enabled_ = false;
    ControlKind control_kind_ = ControlKind::None;
    std::optional<Expr> control_value_;
    std::optional<Expr> control_target_;
    bool aborted_ = false;
    bool deferred_abort_ = false;
    std::vector<Expr> messages_;
    std::vector<std::string> message_texts_;
    std::vector<std::string> prints_;
};

[[nodiscard]] Expr evaluate(const Expr& expression);

} // namespace tungsten
