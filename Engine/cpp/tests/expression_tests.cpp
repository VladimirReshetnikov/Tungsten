#include "tungsten/evaluator.hpp"
#include "tungsten/expression.hpp"
#include "tungsten/parser.hpp"
#include "tungsten/wolfram_strings.hpp"

#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <map>
#include <numeric>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

int failures = 0;

void check(bool condition, const std::string& message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

void check_equal(
    const std::string& actual, const std::string& expected, const std::string& message) {
    if (actual != expected) {
        std::cerr << "FAIL: " << message << "\n  expected: " << expected
                  << "\n  actual:   " << actual << '\n';
        ++failures;
    }
}

std::map<std::string, std::size_t> full_form_counts(
    const std::vector<tungsten::Expr>& expressions) {
    std::map<std::string, std::size_t> counts;
    for (const auto& expression : expressions)
        ++counts[expression.to_full_form()];
    return counts;
}

} // namespace

int main() {
    using namespace tungsten;

    const auto expression = call("Plus", {
        symbol("x"), call("Times", {integer(-1L), symbol("y")})});
    check_equal(expression.to_full_form(), "Plus[x, Times[-1, y]]", "full form");
    check_equal(expression.to_input_form(), "x - y", "input form subtraction");
    check(expression.depth() == 3, "expression depth");
    check(expression.length() == 2, "expression length");
    check(expression.head() == symbol("Plus"), "call head");

    check_equal(rational(2, 6).to_full_form(), "Rational[1, 3]", "rational normalization");
    check_equal(rational(2, 1).to_full_form(), "2", "integral rational normalization");
    check_equal(complex(integer(2L), integer(-3L)).to_input_form(), "2 - 3 I", "complex form");
    check(complex(integer(2L), integer(0L)) == integer(2L), "zero imaginary normalization");

    const auto bytes = byte_array({0, 1, 2, 253, 254, 255});
    check_equal(bytes.to_full_form(), "ByteArray[\"AAEC/f7/\"]", "byte array full form");
    check_equal(bytes.to_json(),
        "{\"type\":\"byte_array\",\"values\":[0,1,2,253,254,255],"
        "\"base64\":\"AAEC/f7/\",\"length\":6}", "byte array JSON");

    const auto sparse = sparse_array({3, 4}, {{{1, 2}, integer(9L)}}, integer(-1L));
    check(sparse.length() == 3, "sparse length");
    check(sparse.depth() == 3, "sparse depth");
    check(sparse.fill_value() == integer(-1L), "sparse fill value");
    check_equal(sparse.to_full_form(),
        "SparseArray[List[Rule[List[1, 2], 9]], List[3, 4], -1]", "sparse full form");

    const auto wide_sparse = sparse_array(
        {mpz_class("18446744073709551616", 10)}, {}, integer(0L));
    check(wide_sparse.kind() == ExprKind::SparseArray,
        "wide sparse expression kind");
    check(wide_sparse.is_atom(), "wide sparse atom model");
    check(wide_sparse.sparse_dimensions()
            == std::vector<mpz_class>{
                mpz_class("18446744073709551616", 10)},
        "wide sparse exact dimensions");
    check_equal(wide_sparse.to_json(),
        "{\"type\":\"sparse_array\",\"dimensions\":[18446744073709551616],"
        "\"fill_value\":{\"type\":\"integer\",\"value\":0},\"entries\":[],"
        "\"explicit_length\":0}",
        "wide sparse JSON keeps arbitrary-precision dimensions");
    bool wide_native_dimensions_rejected = false;
    try {
        static_cast<void>(wide_sparse.dimensions());
    } catch (const std::overflow_error&) {
        wide_native_dimensions_rejected = true;
    }
    check(wide_native_dimensions_rejected,
        "wide sparse machine-dimension accessor rejects narrowing");

    const auto wide_trailing_dimension = sparse_array(
        {mpz_class(2), mpz_class("18446744073709551616", 10)}, {},
        integer(0L));
    check(wide_trailing_dimension.length() == 2,
        "sparse native length ignores non-native trailing axes");
    bool negative_sparse_dimension_rejected = false;
    try {
        static_cast<void>(sparse_array(
            {mpz_class(-1)}, {}, integer(0L)));
    } catch (const std::invalid_argument&) {
        negative_sparse_dimension_rejected = true;
    }
    check(negative_sparse_dimension_rejected,
        "direct exact sparse construction rejects negative dimensions");

    check_equal(wl_string("a\\b\n\"c"), "\"a\\\\b\\n\\\"c\"", "Wolfram string encoder");
    check_equal(parse_wl_string_literal("\"\\[Alpha]\\:03b2\\141\""), u8"\u03b1\u03b2a",
        "Wolfram character escape decoder");
    check_equal(parse_wl_string_literal("\"\\[NoSuchName]\""), "\\[NoSuchName]",
        "unknown named escape preservation");
    check_equal(encode_printable_ascii(u8"x\u03b1"), "x\\[Alpha]", "named character encoder");

    const auto boxed = compose_inline_box_string(
        "before ", {R"WL(RowBox[{"literal \\)", FormBox[\(x\), TraditionalForm]}])WL"}, " after");
    const auto segments = split_inline_boxes(boxed);
    check(segments.size() == 3, "inline box segment count");
    check(segments.size() == 3
        && segments[1].kind == WolframStringSegment::Kind::InlineBox,
        "inline box segment kind");
    check_equal(display_text(boxed, "[InlineBox]"), "before [InlineBox] after",
        "inline box display text");
    const auto decoded_boxed = parse_wl_string_literal(wl_string(boxed));
    check(inline_box_segments(decoded_boxed).size() == 1, "decoded inline box recognition");

    check_equal(symbol("System`Plus").to_json(),
        "{\"type\":\"symbol\",\"name\":\"System`Plus\"}", "symbol JSON");
    check_equal(call("f", {integer(1L), string("x")}).to_json(),
        "{\"type\":\"call\",\"head\":{\"type\":\"symbol\",\"name\":\"f\"},"
        "\"args\":[{\"type\":\"integer\",\"value\":1},{\"type\":\"string\",\"value\":\"x\"}]}",
        "call JSON");

    check_equal(parse_input_form("Plus[1, Times[2, x]]").to_full_form(),
        "Plus[1, Times[2, x]]", "full-form parser surface");
    check_equal(parse_input_form("1 + 2 x^3").to_full_form(),
        "Plus[1, Times[2, Power[x, 3]]]", "arithmetic parser");
    check_equal(parse_input_form("Hold[1 + (2 + 3)]").to_full_form(),
        "Hold[Plus[1, Plus[2, 3]]]", "grouping preserves nested flat head");
    check_equal(parse_input_form("Hold[16^^ff, 1.2``20*^-3]").to_full_form(),
        "Hold[255, 1.2``20*^-3]", "numeric parser surface");
    check_equal(parse_input_form("f[x_Integer, y_]").to_full_form(),
        "f[Pattern[x, Blank[Integer]], Pattern[y, Blank[]]]", "pattern parser");
    check_equal(parse_input_form("x_ /; x > 0").to_full_form(),
        "Condition[Pattern[x, Blank[]], Greater[x, 0]]", "condition parser");
    check_equal(parse_input_form("f[a] /. a -> b").to_full_form(),
        "ReplaceAll[f[a], Rule[a, b]]", "rule parser");
    check_equal(parse_input_form("expr[[1, 2 ;; -1]]").to_full_form(),
        "Part[expr, 1, Span[2, -1]]", "part and span parser");
    check_equal(parse_input_form("f @ # &").to_full_form(),
        "Function[f[Slot[1]]]", "slot and function parser");
    check_equal(parse_input_form("Hold[a < b <= c]").to_full_form(),
        "Hold[Inequality[a, Less, b, LessEqual, c]]", "comparison chain parser");
    check_equal(parse_input_form("<|a -> 1, b -> {2, 3}|>").to_full_form(),
        "Association[Rule[a, 1], Rule[b, List[2, 3]]]", "association parser");

    check_equal(evaluate(parse_input_form("1 + 2*3 + x + 2*x")).to_full_form(),
        "Plus[7, Times[3, x]]", "exact arithmetic evaluator");
    check_equal(evaluate(parse_input_form("(2/3)^-2")).to_full_form(),
        "Rational[9, 4]", "exact rational power evaluator");
    check_equal(evaluate(parse_input_form("Function[{x, y}, x + y][2, 3]")).to_full_form(),
        "5", "named pure function evaluator");
    check_equal(evaluate(parse_input_form("Reap[Sow[1]; Sow[2]; 3]")).to_full_form(),
        "List[3, List[List[1, 2]]]", "reap and sow evaluator");
    Evaluator stateful;
    check_equal(stateful.evaluate(parse_input_form("value = 12")).to_full_form(), "12", "set evaluator");
    check_equal(stateful.evaluate(parse_input_form("value + 3")).to_full_form(), "15", "stateful own value");

    check_equal(stateful.evaluate(parse_input_form("Check[Part[f[a], 2], fallback]")).to_full_form(),
        "fallback", "Check catches emitted messages");
    check(stateful.messages().size() == 1, "Check preserves the caught message");
    check_equal(stateful.message_texts().empty() ? "" : stateful.message_texts().front(),
        "Part::error: Part specifications are invalid for f[a].",
        "Part diagnostic text");
    check_equal(stateful.evaluate(parse_input_form("Quiet[Check[Part[f[a], 2], fallback]]")).to_full_form(),
        "fallback", "Quiet suppresses an inner Check message");
    check(stateful.messages().empty(), "Quiet hides visible messages");
    check_equal(stateful.evaluate(parse_input_form("Print[InputForm[{1, 2/3, a + b}]]")).to_full_form(),
        "Null", "Print returns Null");
    check_equal(stateful.prints().empty() ? "" : stateful.prints().front(),
        "{1, 2/3, a + b}", "InputForm print rendering");
    check_equal(stateful.evaluate(parse_input_form(
        "CheckAbort[WithCleanup[Print[\"expr1\"]; Abort[]; Print[\"expr2\"], "
        "Print[\"cleanup\"]], caught]")).to_full_form(),
        "caught", "WithCleanup preserves abort for CheckAbort");
    check(stateful.prints().size() == 2, "WithCleanup executes cleanup after abort");
    check(stateful.prints().size() == 2 && stateful.prints()[0] == "expr1"
            && stateful.prints()[1] == "cleanup",
        "WithCleanup skips the aborted tail and prints cleanup");

    Evaluator timing;
    check_equal(timing.evaluate(parse_input_form(
        "TimeConstrained[Pause[.03];7,.002,timeout]")).to_full_form(),
        "timeout", "TimeConstrained interrupts Pause and evaluates its fallback");
    check_equal(timing.evaluate(parse_input_form("TimeRemaining[]")).to_full_form(),
        "Infinity", "expired deadline is removed before the next root evaluation");
    const auto absolute_timing = timing.evaluate(parse_input_form(
        "AbsoluteTiming[Pause[.005];7]"));
    check(absolute_timing.has_head("List") && absolute_timing.args().size() == 2
            && absolute_timing.args()[0].kind() == ExprKind::Real
            && absolute_timing.args()[1] == integer(7L),
        "AbsoluteTiming returns a real elapsed duration and evaluated value");
    check_equal(timing.evaluate(parse_input_form(
        "TimeConstrained[TimeConstrained[Pause[.03],.002,inner],.02,outer]"
        )).to_full_form(),
        "inner", "an earlier inner deadline owns its fallback");
    check_equal(timing.evaluate(parse_input_form(
        "TimeConstrained[TimeConstrained[Pause[.03],.02,inner],.002,outer]"
        )).to_full_form(),
        "outer", "an earlier outer deadline bypasses the inner fallback");

    Evaluator abort_ownership;
    check_equal(abort_ownership.evaluate(parse_input_form(
        "CheckAbort[AbortProtect[Abort[];"
        "Print[InputForm[Pause[0]]]],caught]"
        )).to_full_form(),
        "caught", "a protected pending abort survives Pause evaluation");
    check(abort_ownership.prints().size() == 1
            && abort_ownership.prints().front() == "Null",
        "Pause still evaluates normally under a pre-existing protected abort");
    check_equal(abort_ownership.evaluate(parse_input_form(
        "CheckAbort[AbortProtect[Abort[];Print[InputForm["
        "TimeConstrained[7,1,fail]]]],caught]"
        )).to_full_form(),
        "caught", "a protected pending abort survives TimeConstrained evaluation");
    check(abort_ownership.prints().size() == 1
            && abort_ownership.prints().front() == "7",
        "TimeConstrained evaluates its body under a pre-existing protected abort");
    check_equal(abort_ownership.evaluate(parse_input_form(
        "CheckAbort[AbortProtect[Abort[];Print[InputForm["
        "AbsoluteTiming[7]]]],caught]"
        )).to_full_form(),
        "caught", "a protected pending abort survives AbsoluteTiming evaluation");
    const auto protected_timing = abort_ownership.prints().size() == 1
        ? parse_input_form(abort_ownership.prints().front()) : symbol("Missing");
    check(protected_timing.has_head("List")
            && protected_timing.args().size() == 2
            && protected_timing.args()[0].kind() == ExprKind::Real
            && protected_timing.args()[1] == integer(7L),
        "AbsoluteTiming remains structurally complete under a pending abort");
    check_equal(abort_ownership.evaluate(parse_input_form(
        "CheckAbort[AbortProtect[Abort[];WithCleanup[Print[\"init\"],"
        "Print[\"body\"],Print[\"cleanup\"]];Print[\"after\"]],caught]"
        )).to_full_form(),
        "caught", "WithCleanup preserves an enclosing pending abort");
    check(abort_ownership.prints()
            == std::vector<std::string>({"init", "body", "cleanup", "after"}),
        "WithCleanup does not mistake an enclosing abort for init control");
    check_equal(abort_ownership.evaluate(parse_input_form(
        "CheckAbort[AbortProtect[Pause[Abort[]]],caught]"
        )).to_full_form(),
        "caught", "Abort in a protected Pause duration remains deferred");
    check(abort_ownership.messages().size() == 1
            && abort_ownership.messages().front().to_full_form()
                == "MessageName[Pause, \"error\"]",
        "protected Abort returns Null for Pause duration validation");
    check_equal(abort_ownership.evaluate(parse_input_form(
        "CheckAbort[AbortProtect[TimeConstrained[7,Abort[],fallback]],caught]"
        )).to_full_form(),
        "caught", "Abort in a protected time limit remains deferred");
    check(abort_ownership.messages().size() == 1
            && abort_ownership.messages().front().to_full_form()
                == "MessageName[TimeConstrained, \"error\"]",
        "protected Abort returns Null for time-limit validation");
    check_equal(abort_ownership.evaluate(parse_input_form(
        "CheckAbort[AbortProtect[Print[InputForm["
        "AbsoluteTiming[Abort[]]]]],caught]"
        )).to_full_form(),
        "caught", "Abort in AbsoluteTiming remains protected");
    const auto aborted_timing = abort_ownership.prints().size() == 1
        ? parse_input_form(abort_ownership.prints().front()) : symbol("Missing");
    check(aborted_timing.has_head("List")
            && aborted_timing.args().size() == 2
            && aborted_timing.args()[0].kind() == ExprKind::Real
            && aborted_timing.args()[1] == symbol("Null"),
        "AbsoluteTiming wraps the Null returned by a protected Abort");
    check_equal(abort_ownership.evaluate(parse_input_form(
        "TimeConstrained[AbortProtect[Abort[];Pause[.03]],.001,timeout]"
        )).to_full_form(),
        "timeout", "timeout unwinding discards its AbortProtect-local abort");
    check_equal(abort_ownership.evaluate(parse_input_form(
        "TimeConstrained[AbortProtect[Abort[];WithCleanup[Pause[.03],"
        "Print[\"cleanup\"]]],.001,timeout]"
        )).to_full_form(),
        "timeout", "cleanup timeout discards its AbortProtect-local abort");
    check(abort_ownership.prints().size() == 1
            && abort_ownership.prints().front() == "cleanup",
        "WithCleanup still executes while a timeout unwinds AbortProtect");
    check_equal(abort_ownership.evaluate(parse_input_form(
        "CheckAbort[AbortProtect[AbortProtect[Abort[];"
        "Print[\"innerTail\"]];Print[\"outerTail\"]],fail]"
        )).to_full_form(),
        "fail", "nested AbortProtect propagates the pending abort");
    check(abort_ownership.prints()
            == std::vector<std::string>({"innerTail", "outerTail"}),
        "CompoundExpression re-defers an inner protected abort");
    check_equal(abort_ownership.evaluate(parse_input_form(
        "CheckAbort[AbortProtect[Abort[];Print[InputForm[CheckAbort[1,inner]]];"
        "Print[InputForm[CheckAbort[Abort[],inner]]];Print[\"tail\"]],fail]"
        )).to_full_form(),
        "fail", "same-depth CheckAbort does not consume an older pending abort");
    check(abort_ownership.prints()
            == std::vector<std::string>({"1", "inner", "tail"}),
        "same-depth CheckAbort catches only the Abort raised in its body");

    Evaluator timeout_state;
    (void)timeout_state.evaluate(parse_input_form("$RecursionLimit=20"));
    for (int repetition = 0; repetition < 32; ++repetition)
        check_equal(timeout_state.evaluate(parse_input_form(
            "TimeConstrained[Pause[.03],.001,timeout]"
            )).to_full_form(),
            "timeout", "repeated timeout restores evaluator depth");
    (void)timeout_state.evaluate(parse_input_form("$RecursionLimit=1024"));
    (void)timeout_state.evaluate(parse_input_form(
        "tungstenTimedOwn:=Pause[.03]"));
    check_equal(timeout_state.evaluate(parse_input_form(
        "TimeConstrained[tungstenTimedOwn,.002,timeout]"
        )).to_full_form(),
        "timeout", "timeout unwinds an active own-value evaluation");
    (void)timeout_state.evaluate(parse_input_form("tungstenTimedOwn=7"));
    check_equal(timeout_state.evaluate(parse_input_form(
        "tungstenTimedOwn")).to_full_form(),
        "7", "timeout leaves no stale own-value recursion guard");
    check_equal(timeout_state.evaluate(parse_input_form(
        "tungstenBlock[x_]:=original")).to_full_form(),
        "Null", "timed Block restoration setup");
    check_equal(timeout_state.evaluate(parse_input_form(
        "TimeConstrained[Block[{tungstenBlock},"
        "tungstenBlock[x_]:=temporary;Pause[.03]],.002,timeout]"
        )).to_full_form(),
        "timeout", "timeout unwinds Block-local definitions");
    check_equal(timeout_state.evaluate(parse_input_form(
        "tungstenBlock[1]")).to_full_form(),
        "original", "Block definitions are restored after timeout");
    check_equal(timeout_state.evaluate(parse_input_form(
        "tungstenInherited[x_]:=outer")).to_full_form(),
        "Null", "timed InheritedBlock restoration setup");
    check_equal(timeout_state.evaluate(parse_input_form(
        "{TimeConstrained[InheritedBlock[{tungstenInherited},"
        "tungstenInherited[x_]:=inner;Pause[.03]],.002,timeout],"
        "tungstenInherited[a]}")).to_full_form(),
        "List[timeout, outer]",
        "InheritedBlock definitions are restored after timeout");
    check_equal(timeout_state.evaluate(parse_input_form(
        "tungstenIterator=original;{TimeConstrained["
        "Table[Pause[.03],{tungstenIterator,1,2}],.002,timeout],"
        "tungstenIterator}")).to_full_form(),
        "List[timeout, original]",
        "iterator binding is restored after timeout");
    check_equal(timeout_state.evaluate(parse_input_form(
        "Reap[TimeConstrained[Reap[Pause[.03]],.002,Sow[fallback]]]"
        )).to_full_form(),
        "List[fallback, List[List[fallback]]]",
        "timeout pops an inner Reap scope before evaluating the fallback");
    check_equal(timeout_state.evaluate(parse_input_form(
        "TimeConstrained[Quiet[Pause[.03]],.002,Message[foo::bar]]"
        )).to_full_form(),
        "Null", "timeout pops Quiet before evaluating the fallback");
    check_equal(timeout_state.messages().empty() ? ""
            : timeout_state.messages().front().to_full_form(),
        "MessageName[foo, \"bar\"]",
        "post-timeout fallback message remains visible");
    check_equal(timeout_state.evaluate(parse_input_form(
        "Check[TimeConstrained[Check[Pause[.03],inner,f::tag],.002,timeout];"
        "Message[g::tag];7,outer,g::tag]"
        )).to_full_form(),
        "outer", "timeout pops the innermost Check message scope");
    check_equal(timeout_state.evaluate(parse_input_form(
        "CheckAbort[TimeConstrained[AbortProtect[Pause[.03]],.002,timeout];"
        "Print[\"before\"];Abort[];Print[\"after\"];done,caught]"
        )).to_full_form(),
        "caught", "timeout restores AbortProtect depth");
    check(timeout_state.prints().size() == 1
            && timeout_state.prints().front() == "before",
        "restored AbortProtect depth stops the post-abort tail");
    check_equal(timeout_state.evaluate(parse_input_form(
        "TimeConstrained[WithCleanup[7,Pause[.03]];Pause[.03];9,.04,outer]"
        )).to_full_form(),
        "outer", "WithCleanup restores deadline suppression after cleanup");
    check_equal(timeout_state.evaluate(parse_input_form(
        "{TimeConstrained[Pause[.03],.002,timeout],TimeRemaining[],"
        "TimeConstrained[Pause[0];7,.1,secondFail]}"
        )).to_full_form(),
        "List[timeout, Infinity, 7]",
        "deadline stack is reusable after timeout");
    (void)timeout_state.evaluate(parse_input_form("Part[f[a],2]"));
    check(!timeout_state.messages().empty(),
        "same evaluator records a diagnostic after timeout recovery");
    check_equal(timeout_state.evaluate(parse_input_form("1+1")).to_full_form(),
        "2", "same evaluator remains usable after timeout recovery");
    check(timeout_state.messages().empty(),
        "same evaluator restores root depth and clears later effects");

    check_equal(evaluate(parse_input_form(
        "WithCleanup[7,Abort[]]")).to_full_form(),
        "$Aborted", "cleanup Abort supersedes a completed body at root");
    check_equal(evaluate(parse_input_form(
        "Catch[WithCleanup[Throw[body],Throw[cleanup]]]"
        )).to_full_form(),
        "cleanup", "cleanup Throw supersedes a body Throw");
    check_equal(evaluate(parse_input_form(
        "WithCleanup[Return[body],Return[cleanup]]"
        )).to_full_form(),
        "Return[cleanup]", "cleanup Return supersedes a body Return");
    check_equal(evaluate(parse_input_form(
        "CheckAbort[Catch[WithCleanup[Abort[],Throw[cleanup]]],caught]"
        )).to_full_form(),
        "cleanup", "cleanup Throw supersedes a pending body Abort");
    Evaluator cleanup_precedence;
    (void)cleanup_precedence.evaluate(parse_input_form(
        "tungstenCleanupReturn[]:=Catch[WithCleanup[Throw[body],"
        "Return[cleanup]]]"));
    check_equal(cleanup_precedence.evaluate(parse_input_form(
        "tungstenCleanupReturn[]")).to_full_form(),
        "cleanup", "cleanup Return supersedes a pending body Throw");
    (void)cleanup_precedence.evaluate(parse_input_form(
        "tungstenCleanupThrow[]:=Catch[WithCleanup[Return[body],"
        "Throw[cleanup]]]"));
    check_equal(cleanup_precedence.evaluate(parse_input_form(
        "tungstenCleanupThrow[]")).to_full_form(),
        "cleanup", "cleanup Throw supersedes a pending body Return");
    check_equal(cleanup_precedence.evaluate(parse_input_form(
        "CheckAbort[TimeConstrained[7,Abort[],fallback],caught]"
        )).to_full_form(),
        "caught", "control from a time-limit expression bypasses validation");
    check(cleanup_precedence.messages().empty(),
        "time-limit control does not emit a numeric diagnostic");
    check_equal(cleanup_precedence.evaluate(parse_input_form(
        "Catch[Pause[Throw[seconds]]]")).to_full_form(),
        "seconds", "control from a Pause duration bypasses validation");
    check(cleanup_precedence.messages().empty(),
        "Pause duration control does not emit a numeric diagnostic");

    check_equal(evaluate(parse_input_form(
        "Module[{i = 0, s = 0}, While[i < 5, i = i + 1; "
        "If[Mod[i, 2] == 0, Continue[]]; s = s + i]; s]")).to_full_form(),
        "9", "While catches Continue");
    check_equal(evaluate(parse_input_form(
        "Module[{s = 0}, For[i = 1, i <= 10, i++, "
        "If[i > 5, Break[]]; s = s + i]; s]")).to_full_form(),
        "15", "For catches Break");
    check_equal(evaluate(parse_input_form(
        "Module[{}, For[i = 1, i <= 10, i++, "
        "If[i == 4, Return[fourth, For]]]]")).to_full_form(),
        "fourth", "targeted Return exits For");
    check_equal(evaluate(parse_input_form(
        "Module[{x = 0}, Label[start]; x = x + 1; "
        "If[x < 3, Goto[start]]; x]")).to_full_form(),
        "3", "Goto resumes after a matching Label");
    check_equal(evaluate(parse_input_form("Table[Break[], {i, 1, 3}]")).to_full_form(),
        "Break[]", "Table propagates Break");

    check_equal(stateful.evaluate(parse_input_form(
        "tungstenReturn[x_] := (If[x > 0, Return[positive]]; negative)")).to_full_form(),
        "Null", "Return function definition");
    check_equal(stateful.evaluate(parse_input_form("tungstenReturn[1]")).to_full_form(),
        "positive", "definition boundary catches bare Return");
    check_equal(stateful.evaluate(parse_input_form("tungstenReturn[-1]")).to_full_form(),
        "negative", "definition continues without Return");

    const std::vector<std::pair<std::string, std::string>> exact_integer_cases{
        {"Binomial[-3, 2]", "6"},
        {"Binomial[3, -2]", "0"},
        {"Binomial[100002, 100001]", "100002"},
        {"Binomial[100002, 100000]", "5000150001"},
        {"Binomial[100003, 100001]", "5000250003"},
        {"Multinomial[2, 3, 4]", "1260"},
        {"Multinomial[100001]", "1"},
        {"JacobiSymbol[1001, 9907]", "-1"},
        {"KroneckerSymbol[-1, 2]", "1"},
        {"Fibonacci[-6]", "-8"},
        {"LucasL[-6]", "18"},
        {"BernoulliB[1]", "Rational[-1, 2]"},
        {"BernoulliB[10]", "Rational[5, 66]"},
        {"BernoulliB[1000001]", "0"},
        {"EulerE[6]", "-61"},
        {"EulerE[1000001]", "0"},
        {"HarmonicNumber[5]", "Rational[137, 60]"},
        {"HarmonicNumber[5, 2]", "Rational[5269, 3600]"},
        {"HarmonicNumber[0, 1000]", "0"},
        {"ContinuedFraction[415/93]", "List[4, 2, 6, 7]"},
        {"ContinuedFraction[415/93, 2]", "List[4, 2]"},
        {"ContinuedFraction[-415/93]", "List[-4, -2, -6, -7]"},
        {"FromContinuedFraction[{4, 2, 6, 7}]", "Rational[415, 93]"},
        {"FromContinuedFraction[{}]", "Infinity"},
        {"IntegerPartitions[4]",
            "List[List[4], List[3, 1], List[2, 2], List[2, 1, 1], List[1, 1, 1, 1]]"},
        {"IntegerPartitions[4, 2]", "List[List[4], List[3, 1], List[2, 2]]"},
        {"IntegerPartitions[4, {2}]", "List[List[3, 1], List[2, 2]]"},
        {"PartitionsP[10]", "42"},
        {"PartitionsQ[10]", "10"},
        {"MultiplicativeOrder[2, 7]", "3"},
        {"PrimitiveRoot[7]", "3"},
        {"CarmichaelLambda[12]", "2"},
        {"LiouvilleLambda[18]", "-1"},
        {"JordanTotient[2, 10]", "72"},
        {"JordanTotient[0, 1000000001]", "0"},
        {"RamanujanTau[5]", "4830"},
        {"DivisorSigma[2, 6]", "50"},
        {"DivisorSigma[-1, 6]", "2"},
        {"DivisorSigma[1000, 1]", "1"},
        {"ModularInverse[3, 7]", "5"},
        {"PowerMod[2, -1, 4]", "PowerMod[2, -1, 4]"},
        {"IntegerReverse[1234]", "4321"},
        {"IntegerReverse[-1234]", "4321"},
        {"IntegerReverse[16, 2]", "1"},
        {"IntegerReverse[0]", "0"},
        {"IntegerReverse[123456789012345678901234567890]",
            "98765432109876543210987654321"},
        {"IntegerReverse[-123456789012345678901234567890]",
            "98765432109876543210987654321"},
        {"IntegerReverse[24197857203266734864793317670504947440, 16]",
            "21173125052858393283395314067335103265"},
        {"IntegerReverse[-24197857203266734864793317670504947440, 16]",
            "21173125052858393283395314067335103265"},
        {"IntegerReverse[12, x]", "IntegerReverse[12, x]"},
        {"IntegerReverse[12, 4097]", "IntegerReverse[12, 4097]"},
        {"DigitCount[1122]", "List[2, 2, 0, 0, 0, 0, 0, 0, 0, 0]"},
        {"DigitCount[16, 2]", "List[1, 4]"},
        {"DigitCount[16, 2, 0]", "4"},
        {"DigitCount[0]", "List[0, 0, 0, 0, 0, 0, 0, 0, 0, 1]"},
        {"DigitCount[0, 2, 0]", "1"},
        {"DigitCount[123456789012345678901234567890]",
            "List[3, 3, 3, 3, 3, 3, 3, 3, 3, 3]"},
        {"DigitCount[-123456789012345678901234567890]",
            "List[3, 3, 3, 3, 3, 3, 3, 3, 3, 3]"},
        {"DigitCount[340282366920938463463374607431768211456, 2]", "List[1, 128]"},
        {"DigitCount[-340282366920938463463374607431768211456, 2, 0]", "128"},
        {"DigitCount[24197857203266734864793317670504947440, 16]",
            "List[2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2]"},
        {"DigitCount[12, x]", "DigitCount[12, x]"},
        {"DigitCount[12, 10, x]", "DigitCount[12, 10, x]"},
        {"DigitCount[12, 4097, 1]", "DigitCount[12, 4097, 1]"},
        {"BitNot[0]", "-1"},
        {"BitClear[15, 2]", "11"},
        {"BitClear[0, 10000001]", "0"},
        {"BitSet[8, 1]", "10"},
        {"BitGet[-2, 1]", "1"},
        {"BitGet[0, 10000001]", "0"},
        {"BitLength[-8]", "3"},
        {"BitLength[0]", "0"},
        {"FactorInteger[5, GaussianIntegers -> True]",
            "List[List[Complex[0, -1], 1], List[Complex[1, 2], 1], List[Complex[2, 1], 1]]"},
        {"FactorInteger[3 + 4 I, GaussianIntegers -> True]",
            "List[List[Complex[2, 1], 2]]"},
        {"FactorInteger[210, 2]", "List[List[2, 1], List[105, 1]]"},
        {"FactorInteger[210, 5]", "List[List[2, 1], List[3, 1], List[5, 1], List[7, 1]]"},
    };
    for (const auto& [source, expected] : exact_integer_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "exact integer evaluator: " + source);

    const std::vector<std::pair<std::string, std::string>> composite_cases{
        {"CompositeQ[-100]", "False"},
        {"CompositeQ[-4]", "False"},
        {"CompositeQ[-1]", "False"},
        {"CompositeQ[0]", "False"},
        {"CompositeQ[1]", "False"},
        {"CompositeQ[2]", "False"},
        {"CompositeQ[3]", "False"},
        {"CompositeQ[4]", "True"},
        {"CompositeQ[5]", "False"},
        {"CompositeQ[6]", "True"},
        {"CompositeQ[9]", "True"},
        {"CompositeQ[25]", "True"},
        {"CompositeQ[97]", "False"},
        {"CompositeQ[561]", "True"},
        {"CompositeQ[65537]", "False"},
        {"CompositeQ[1000005]", "True"},
        {"CompositeQ[18446744073709551615]", "True"},
        {"CompositeQ[18446744073709551557]", "False"},
        {"CompositeQ[2^16]", "True"},
        {"CompositeQ[49/7]", "False"},
        {"CompositeQ[]", "CompositeQ[]"},
        {"CompositeQ[x]", "CompositeQ[x]"},
        {"CompositeQ[4.]", "CompositeQ[4.]"},
        {"CompositeQ[4,6]", "CompositeQ[4, 6]"},
    };
    for (const auto& [source, expected] : composite_cases) {
        Evaluator composite_evaluator;
        check_equal(composite_evaluator.evaluate(parse_input_form(source)).to_full_form(),
            expected, "CompositeQ parity: " + source);
        check(composite_evaluator.messages().empty(),
            "CompositeQ invalid forms remain silent: " + source);
    }
    check_equal(evaluate(parse_input_form("CompositeQ[{4,5,6}]")).to_full_form(),
        "List[True, False, True]", "CompositeQ Listable threading");
    check_equal(evaluate(parse_input_form("CompositeQ[{{4,5},{6,7}}]")).to_full_form(),
        "List[List[True, False], List[True, False]]",
        "CompositeQ nested Listable threading");
    check_equal(evaluate(parse_input_form("CompositeQ[{4,5},{6,7}]")).to_full_form(),
        "List[CompositeQ[4, 6], CompositeQ[5, 7]]",
        "CompositeQ threads equal multiple lists before arity validation");
    Evaluator composite_listable_error;
    check_equal(composite_listable_error.evaluate(parse_input_form(
        "CompositeQ[{4},{6,7}]")).to_full_form(),
        "CompositeQ[List[4], List[6, 7]]",
        "CompositeQ incompatible Listable lengths remain raw");
    check_equal(composite_listable_error.messages().empty() ? ""
            : composite_listable_error.messages().front().to_full_form(),
        "MessageName[CompositeQ, \"error\"]",
        "CompositeQ incompatible Listable message name");
    check_equal(composite_listable_error.message_texts().empty() ? ""
            : composite_listable_error.message_texts().front(),
        "CompositeQ::error: Listable Function arguments have incompatible list lengths.",
        "CompositeQ incompatible Listable diagnostic");
    check_equal(evaluate(parse_input_form(
        "CompositeQ[Unevaluated[4]]")).to_full_form(),
        "CompositeQ[Unevaluated[4]]",
        "CompositeQ preserves a direct Unevaluated wrapper");
    Evaluator composite_alias_unevaluated;
    (void)composite_alias_unevaluated.evaluate(parse_input_form("f=CompositeQ"));
    check_equal(composite_alias_unevaluated.evaluate(parse_input_form(
        "f[Unevaluated[4]]")).to_full_form(),
        "CompositeQ[Unevaluated[4]]",
        "CompositeQ alias preserves a direct Unevaluated wrapper");
    check(composite_alias_unevaluated.messages().empty(),
        "CompositeQ alias Unevaluated form remains silent");
    check_equal(evaluate(parse_input_form(
        "CompositeQ[Sequence[Unevaluated[4]]]")).to_full_form(),
        "CompositeQ[Unevaluated[4]]",
        "CompositeQ preserves Unevaluated nested directly in Sequence");
    check_equal(evaluate(parse_input_form(
        "CompositeQ[Splice[{Unevaluated[4]},CompositeQ]]"
        )).to_full_form(),
        "CompositeQ[Unevaluated[4]]",
        "CompositeQ preserves Unevaluated nested in a Splice payload");
    check_equal(evaluate(parse_input_form(
        "CompositeQ[Splice[f[4],CompositeQ]]"
        )).to_full_form(),
        "CompositeQ[Splice[f[4], CompositeQ]]",
        "CompositeQ does not splice a non-List Splice payload");

    const auto full_sample = evaluate(parse_input_form(
        "RandomSample[{a,b,c,d}]") );
    check(full_sample.has_head("List") && full_sample.args().size() == 4,
        "RandomSample full list shape");
    check(full_form_counts(full_sample.args()) == full_form_counts(
            {symbol("a"), symbol("b"), symbol("c"), symbol("d")}),
        "RandomSample full list is a permutation");

    const auto duplicate_sample = evaluate(parse_input_form(
        "RandomSample[{a,a,b,c},3]"));
    check(duplicate_sample.has_head("List") && duplicate_sample.args().size() == 3,
        "RandomSample bounded duplicate shape");
    const auto duplicate_counts = full_form_counts(duplicate_sample.args());
    const auto duplicate_capacity = full_form_counts(
        {symbol("a"), symbol("a"), symbol("b"), symbol("c")});
    check(std::all_of(duplicate_counts.begin(), duplicate_counts.end(),
            [&](const auto& entry) {
                const auto found = duplicate_capacity.find(entry.first);
                return found != duplicate_capacity.end()
                    && entry.second <= found->second;
            }),
        "RandomSample never exceeds duplicate multiplicity");

    const auto all_duplicate_sample = evaluate(parse_input_form(
        "RandomSample[{a,a,b,c},All]"));
    check(all_duplicate_sample.has_head("List")
            && full_form_counts(all_duplicate_sample.args()) == duplicate_capacity,
        "RandomSample All preserves a complete multiset");
    check_equal(evaluate(parse_input_form(
        "RandomSample[{a,b,c,d},0]")).to_full_form(),
        "List[]", "RandomSample zero count");
    check_equal(evaluate(parse_input_form(
        "RandomSample[{}]")).to_full_form(),
        "List[]", "RandomSample empty source");
    const auto upto_sample = evaluate(parse_input_form(
        "RandomSample[{a,b,c,d},UpTo[2]]"));
    check(upto_sample.has_head("List") && upto_sample.args().size() == 2,
        "RandomSample UpTo clips to its count");
    const auto huge_upto_sample = evaluate(parse_input_form(
        "RandomSample[{a,b},UpTo[1000000000000000000000000000000]]"));
    check(huge_upto_sample.has_head("List")
            && full_form_counts(huge_upto_sample.args())
                == full_form_counts({symbol("a"), symbol("b")}),
        "RandomSample arbitrary-width UpTo clips at source length");

    const auto headed_sample = evaluate(parse_input_form(
        "RandomSample[f[a,b,c,d],2]"));
    check(headed_sample.has_head("f") && headed_sample.args().size() == 2,
        "RandomSample preserves an arbitrary head");
    check(std::all_of(headed_sample.args().begin(), headed_sample.args().end(),
            [](const Expr& item) {
                return item == symbol("a") || item == symbol("b")
                    || item == symbol("c") || item == symbol("d");
            }),
        "RandomSample arbitrary-head items come from the source");
    check_equal(evaluate(parse_input_form(
        "RandomSample[f[],All]")).to_full_form(),
        "f[]", "RandomSample accepts a zero-argument compound source");
    const auto evaluated_sample = evaluate(parse_input_form(
        "RandomSample[Identity[f[a,b,c]],1+1]"));
    check(evaluated_sample.has_head("f") && evaluated_sample.args().size() == 2,
        "RandomSample evaluates source and count before sampling");

    const auto association_sample = evaluate(parse_input_form(
        "RandomSample[Association[a->1,b->2,c->3],2]"));
    const auto association_capacity = full_form_counts({
        call("Rule", {symbol("a"), integer(1L)}),
        call("Rule", {symbol("b"), integer(2L)}),
        call("Rule", {symbol("c"), integer(3L)})});
    check(association_sample.has_head("Association")
            && association_sample.args().size() == 2,
        "RandomSample Association shape");
    check(std::all_of(association_sample.args().begin(),
            association_sample.args().end(), [&](const Expr& entry) {
                return association_capacity.count(entry.to_full_form()) != 0;
            }),
        "RandomSample keeps Association rules atomic");
    const auto delayed_association = evaluate(parse_input_form(
        "RandomSample[Association[a:>x,b->2],All]"));
    check(delayed_association.has_head("Association")
            && full_form_counts(delayed_association.args()) == full_form_counts({
                call("RuleDelayed", {symbol("a"), symbol("x")}),
                call("Rule", {symbol("b"), integer(2L)})}),
        "RandomSample preserves complete RuleDelayed Association entries");
    const auto normalized_association = evaluate(parse_input_form(
        "RandomSample[Association[a->1,a->2,b->3],All]"));
    check(normalized_association.has_head("Association")
            && full_form_counts(normalized_association.args()) == full_form_counts({
                call("Rule", {symbol("a"), integer(2L)}),
                call("Rule", {symbol("b"), integer(3L)})}),
        "RandomSample samples normalized Association keys");
    const auto malformed_association = evaluate(parse_input_form(
        "RandomSample[Association[z,a->1],2]"));
    check(malformed_association.has_head("Association")
            && full_form_counts(malformed_association.args()) == full_form_counts({
                symbol("z"), call("Rule", {symbol("a"), integer(1L)})}),
        "RandomSample treats a malformed Association as an ordinary compound");
    check_equal(evaluate(parse_input_form(
        "RandomSample[Unevaluated[Association[{a->1,b->2}]],All]"
        )).to_full_form(),
        "Association[List[Rule[a, 1], Rule[b, 2]]]",
        "RandomSample does not flatten a raw nested Association item");
    Evaluator raw_duplicate_association_evaluator;
    const auto raw_duplicate_association =
        raw_duplicate_association_evaluator.evaluate(parse_input_form(
            "RandomSample[Unevaluated[Association[a->1,a->2]],2]"));
    check(raw_duplicate_association.has_head("Association")
            && raw_duplicate_association.args().size() == 1
            && raw_duplicate_association.args()[0].has_head("Rule")
            && raw_duplicate_association.args()[0].args().size() == 2
            && raw_duplicate_association.args()[0].args()[0] == symbol("a")
            && (raw_duplicate_association.args()[0].args()[1] == integer(1L)
                || raw_duplicate_association.args()[0].args()[1] == integer(2L)),
        "RandomSample samples raw duplicate Association keys as occurrences before rebuild");
    check(raw_duplicate_association_evaluator.messages().empty(),
        "RandomSample raw duplicate Association count uses pre-normalized length");
    check_equal(evaluate(parse_input_form(
        "RandomSample[Unevaluated[List[Sequence[a,b],Nothing]],All]"
        )).to_full_form(),
        "List[a, b]",
        "RandomSample rebuild splices Sequence and removes Nothing from a raw List");
    const auto raw_general_rebuild = evaluate(parse_input_form(
        "RandomSample[Unevaluated[f[Sequence[a,b],Nothing]],All]"));
    check(raw_general_rebuild.has_head("f")
            && full_form_counts(raw_general_rebuild.args()) == full_form_counts({
                symbol("a"), symbol("b"), symbol("Nothing")}),
        "RandomSample rebuild splices Sequence but retains Nothing for a general head");
    check_equal(evaluate(parse_input_form(
        "RandomSample[Unevaluated[Association[Nothing,a->1]],All]"
        )).to_full_form(),
        "Association[Rule[a, 1]]",
        "RandomSample raw Association rebuild removes Nothing");
    check_equal(evaluate(parse_input_form(
        "RandomSample[Unevaluated[Association[Sequence[a->1,a->2]]],All]"
        )).to_full_form(),
        "Association[Rule[a, 1], Rule[a, 2]]",
        "RandomSample malformed Association rebuild splices without deduplication");
    check_equal(evaluate(parse_input_form(
        "RandomSample[Unevaluated[List[Splice[{a,b}]]],All]"
        )).to_full_form(),
        "List[a, b]", "RandomSample raw List rebuild applies eligible Splice");
    check_equal(evaluate(parse_input_form(
        "RandomSample[Splice[f[{a,b},0],RandomSample],0]"
        )).to_full_form(),
        "Splice[]", "RandomSample does not outer-splice a non-List payload");
    const auto ineligible_splice = evaluate(parse_input_form(
        "RandomSample[Unevaluated[f[Splice[g[a,b],f]]],All]"));
    check_equal(ineligible_splice.to_full_form(),
        "f[Splice[g[a, b], f]]",
        "RandomSample raw rebuild retains a non-List Splice payload");

    const auto unevaluated_sample = evaluate(parse_input_form(
        "RandomSample[Unevaluated[{1+1,3}],All]"));
    check(unevaluated_sample.has_head("List")
            && full_form_counts(unevaluated_sample.args()) == full_form_counts({
                call("Plus", {integer(1L), integer(1L)}), integer(3L)}),
        "RandomSample samples direct Unevaluated contents without evaluating them");
    const auto nested_unevaluated_list_sample = evaluate(parse_input_form(
        "RandomSample[{Unevaluated[1+1],3},All]"));
    check(nested_unevaluated_list_sample.has_head("List")
            && full_form_counts(nested_unevaluated_list_sample.args())
                == full_form_counts({
                    call("Unevaluated", {
                        call("Plus", {integer(1L), integer(1L)})}),
                    integer(3L)}),
        "RandomSample preserves nested Unevaluated wrappers in List sources");
    const auto nested_unevaluated_headed_sample = evaluate(parse_input_form(
        "RandomSample[f[Unevaluated[1+1],3],All]"));
    check(nested_unevaluated_headed_sample.has_head("f")
            && full_form_counts(nested_unevaluated_headed_sample.args())
                == full_form_counts({
                    call("Unevaluated", {
                        call("Plus", {integer(1L), integer(1L)})}),
                    integer(3L)}),
        "RandomSample preserves nested Unevaluated wrappers under user heads");
    const auto nested_unevaluated_association_sample = evaluate(parse_input_form(
        "RandomSample[Association[a->Unevaluated[1+1],b->3],All]"));
    check(nested_unevaluated_association_sample.has_head("Association")
            && full_form_counts(nested_unevaluated_association_sample.args())
                == full_form_counts({
                    call("Rule", {symbol("a"), call("Unevaluated", {
                        call("Plus", {integer(1L), integer(1L)})})}),
                    call("Rule", {symbol("b"), integer(3L)})}),
        "RandomSample preserves nested Unevaluated wrappers in Association rules");
    check_equal(evaluate(parse_input_form(
        "RandomSample[Unevaluated[Sequence[a,b]],0]")).to_full_form(),
        "Sequence[]",
        "RandomSample unwraps Unevaluated only after outer Sequence splicing");
    const auto unevaluated_sequence_sample = evaluate(parse_input_form(
        "RandomSample[Unevaluated[Sequence[{a,b},0]]]"));
    check(unevaluated_sequence_sample.has_head("Sequence")
            && full_form_counts(unevaluated_sequence_sample.args())
                == full_form_counts({list({symbol("a"), symbol("b")}), integer(0L)}),
        "RandomSample treats a Sequence inside Unevaluated as the sampled source");
    check_equal(evaluate(parse_input_form(
        "RandomSample[{a,Nothing,b},All] // Sort")).to_full_form(),
        "List[a, b]", "RandomSample sees Nothing-elided List items");
    Evaluator random_sample_effects;
    check_equal(random_sample_effects.evaluate(parse_input_form(
        "x=0; {RandomSample[(x=x+1;{a,b}),(x=x+1;0)],x}")).to_full_form(),
        "List[List[], 2]", "RandomSample evaluates source before count exactly once");

    struct RandomDiagnosticCase {
        std::string source;
        std::string expected_result;
        std::string expected_name;
        std::string expected_text;
    };
    const std::vector<RandomDiagnosticCase> random_diagnostic_cases{
        {"RandomSample[]", "RandomSample[]", "RandomSample",
            "RandomSample expects an expression and an optional count."},
        {"RandomSample[{a,b},All,1]", "RandomSample[List[a, b], All, 1]",
            "RandomSample", "RandomSample expects an expression and an optional count."},
        {"RandomSample[a]", "RandomSample[a]", "RandomSample",
            "RandomSample expects a nonatomic expression."},
        {"RandomSample[{a,b},x]", "RandomSample[List[a, b], x]", "RandomSample",
            "RandomSample expects an integer, UpTo[n], All, or no count."},
        {"RandomSample[{a,b},UpTo[x]]", "RandomSample[List[a, b], UpTo[x]]",
            "RandomSample", "RandomSample expects an integer, UpTo[n], All, or no count."},
        {"RandomSample[{a,b},-1]", "RandomSample[List[a, b], -1]", "RandomSample",
            "RandomSample count must be between 0 and the sequence length."},
        {"RandomSample[{a,b},3]", "RandomSample[List[a, b], 3]", "RandomSample",
            "RandomSample count must be between 0 and the sequence length."},
        {"RandomSample[{a,b},UpTo[-1]]", "RandomSample[List[a, b], UpTo[-1]]",
            "RandomSample", "RandomSample count must be between 0 and the sequence length."},
        {"RandomSample[{a,b},1000000000000000000000000000000]",
            "RandomSample[List[a, b], 1000000000000000000000000000000]",
            "RandomSample", "RandomSample count must be between 0 and the sequence length."},
        {"RandomSample[{a,b},UpTo[-1000000000000000000000000000000]]",
            "RandomSample[List[a, b], UpTo[-1000000000000000000000000000000]]",
            "RandomSample", "RandomSample count must be between 0 and the sequence length."},
        {"RandomPermutation[]", "RandomPermutation[]", "RandomPermutation",
            "RandomPermutation expects an integer length."},
        {"RandomPermutation[1,2]", "RandomPermutation[1, 2]", "RandomPermutation",
            "RandomPermutation expects an integer length."},
        {"RandomPermutation[-1]", "RandomPermutation[-1]", "RandomPermutation",
            "RandomPermutation expects a non-negative integer."},
        {"RandomPermutation[-1000000000000000000000000000000]",
            "RandomPermutation[-1000000000000000000000000000000]",
            "RandomPermutation", "RandomPermutation expects a non-negative integer."},
        {"RandomPermutation[2.]", "RandomPermutation[2.]", "RandomPermutation",
            "RandomPermutation currently expects an integer length."},
        {"RandomPermutation[x]", "RandomPermutation[x]", "RandomPermutation",
            "RandomPermutation currently expects an integer length."},
        {"RandomPermutation[Unevaluated[2]]", "RandomPermutation[Unevaluated[2]]",
            "RandomPermutation", "RandomPermutation currently expects an integer length."},
    };
    for (const auto& diagnostic : random_diagnostic_cases) {
        Evaluator random_diagnostics;
        check_equal(random_diagnostics.evaluate(parse_input_form(
            diagnostic.source)).to_full_form(), diagnostic.expected_result,
            "random failure remains raw: " + diagnostic.source);
        check_equal(random_diagnostics.messages().empty() ? ""
                : random_diagnostics.messages().front().to_full_form(),
            "MessageName[" + diagnostic.expected_name + ", \"error\"]",
            "random diagnostic message name: " + diagnostic.source);
        check_equal(random_diagnostics.message_texts().empty() ? ""
                : random_diagnostics.message_texts().front(),
            diagnostic.expected_name + "::error: " + diagnostic.expected_text,
            "random diagnostic text: " + diagnostic.source);
        check(random_diagnostics.messages().size() == 1,
            "random invalid form emits exactly one message: " + diagnostic.source);
    }
    Evaluator random_validation_order;
    check_equal(random_validation_order.evaluate(parse_input_form(
        "RandomSample[a,-1]")).to_full_form(),
        "RandomSample[a, -1]", "RandomSample validates source before count");
    check_equal(random_validation_order.message_texts().empty() ? ""
            : random_validation_order.message_texts().front(),
        "RandomSample::error: RandomSample expects a nonatomic expression.",
        "RandomSample source-before-count diagnostic");
    Evaluator random_print_order;
    (void)random_print_order.evaluate(parse_input_form(
        "RandomSample[(Print[\"source\"];a),(Print[\"count\"];-1)]"));
    check(random_print_order.prints()
            == std::vector<std::string>({"source", "count"}),
        "RandomSample evaluates invalid arguments left to right");
    check_equal(random_print_order.message_texts().empty() ? ""
            : random_print_order.message_texts().front(),
        "RandomSample::error: RandomSample expects a nonatomic expression.",
        "RandomSample source validation still precedes count after effects");

    Evaluator random_alias;
    (void)random_alias.evaluate(parse_input_form("f=RandomSample"));
    check_equal(random_alias.evaluate(parse_input_form("f[a]")).to_full_form(),
        "f[a]", "RandomSample alias errors preserve the raw call");
    check_equal(random_alias.messages().empty() ? ""
            : random_alias.messages().front().to_full_form(),
        "MessageName[f, \"error\"]", "RandomSample alias message name");
    check_equal(random_alias.message_texts().empty() ? ""
            : random_alias.message_texts().front(),
        "f::error: RandomSample expects a nonatomic expression.",
        "RandomSample alias diagnostic prefix");
    Evaluator permutation_alias;
    (void)permutation_alias.evaluate(parse_input_form("f=RandomPermutation"));
    check_equal(permutation_alias.evaluate(parse_input_form("f[-1]")).to_full_form(),
        "f[-1]", "RandomPermutation alias errors preserve the raw call");
    check_equal(permutation_alias.message_texts().empty() ? ""
            : permutation_alias.message_texts().front(),
        "f::error: RandomPermutation expects a non-negative integer.",
        "RandomPermutation alias diagnostic prefix");
    Evaluator permutation_alias_unevaluated;
    (void)permutation_alias_unevaluated.evaluate(parse_input_form(
        "f=RandomPermutation"));
    check_equal(permutation_alias_unevaluated.evaluate(parse_input_form(
        "f[Unevaluated[0]]")).to_full_form(),
        "f[Unevaluated[0]]",
        "RandomPermutation alias preserves Unevaluated on type failure");
    check_equal(permutation_alias_unevaluated.message_texts().empty() ? ""
            : permutation_alias_unevaluated.message_texts().front(),
        "f::error: RandomPermutation currently expects an integer length.",
        "RandomPermutation alias Unevaluated diagnostic");
    Evaluator permutation_sequence_unevaluated;
    check_equal(permutation_sequence_unevaluated.evaluate(parse_input_form(
        "RandomPermutation[Sequence[Unevaluated[0]]]"
        )).to_full_form(),
        "RandomPermutation[Sequence[Unevaluated[0]]]",
        "RandomPermutation raw fallback preserves Unevaluated nested in Sequence");
    check_equal(permutation_sequence_unevaluated.message_texts().empty() ? ""
            : permutation_sequence_unevaluated.message_texts().front(),
        "RandomPermutation::error: RandomPermutation currently expects an integer length.",
        "RandomPermutation Sequence-nested Unevaluated diagnostic");
    Evaluator permutation_nonlist_splice;
    check_equal(permutation_nonlist_splice.evaluate(parse_input_form(
        "RandomPermutation[Splice[f[0],RandomPermutation]]"
        )).to_full_form(),
        "RandomPermutation[Splice[f[0], RandomPermutation]]",
        "RandomPermutation does not splice a non-List Splice payload");
    check_equal(permutation_nonlist_splice.message_texts().empty() ? ""
            : permutation_nonlist_splice.message_texts().front(),
        "RandomPermutation::error: RandomPermutation currently expects an integer length.",
        "RandomPermutation non-List Splice diagnostic");

    Evaluator nonsymbol_sample_head;
    check_equal(nonsymbol_sample_head.evaluate(parse_input_form(
        "Identity[RandomSample][a]")).to_full_form(),
        "Identity[RandomSample][a]",
        "RandomSample nonsymbolic callable errors preserve the raw call");
    check_equal(nonsymbol_sample_head.messages().empty() ? ""
            : nonsymbol_sample_head.messages().front().to_full_form(),
        "MessageName[General, \"error\"]",
        "RandomSample nonsymbolic callable uses General message name");
    check_equal(nonsymbol_sample_head.message_texts().empty() ? ""
            : nonsymbol_sample_head.message_texts().front(),
        "General::error: RandomSample expects a nonatomic expression.",
        "RandomSample nonsymbolic callable diagnostic prefix");
    Evaluator nonsymbol_permutation_head;
    check_equal(nonsymbol_permutation_head.evaluate(parse_input_form(
        "Identity[RandomPermutation][-1]")).to_full_form(),
        "Identity[RandomPermutation][-1]",
        "RandomPermutation nonsymbolic callable errors preserve the raw call");
    check_equal(nonsymbol_permutation_head.message_texts().empty() ? ""
            : nonsymbol_permutation_head.message_texts().front(),
        "General::error: RandomPermutation expects a non-negative integer.",
        "RandomPermutation nonsymbolic callable diagnostic prefix");
    Evaluator nonsymbol_composite_head;
    check_equal(nonsymbol_composite_head.evaluate(parse_input_form(
        "Identity[CompositeQ][{4,5},{6}]")).to_full_form(),
        "Identity[CompositeQ][List[4, 5], List[6]]",
        "CompositeQ nonsymbolic callable Listable errors preserve the raw call");
    check_equal(nonsymbol_composite_head.messages().empty() ? ""
            : nonsymbol_composite_head.messages().front().to_full_form(),
        "MessageName[General, \"error\"]",
        "CompositeQ nonsymbolic callable uses General message name");
    check_equal(nonsymbol_composite_head.message_texts().empty() ? ""
            : nonsymbol_composite_head.message_texts().front(),
        "General::error: Listable Function arguments have incompatible list lengths.",
        "CompositeQ nonsymbolic callable diagnostic prefix");

    for (const std::size_t length : {std::size_t{0}, std::size_t{1},
            std::size_t{2}, std::size_t{8}, std::size_t{32}}) {
        const auto encoded = evaluate(parse_input_form(
            "RandomPermutation[" + std::to_string(length) + "]"));
        check(encoded.has_head("Cycles") && encoded.args().size() == 1
                && encoded.args()[0].has_head("List"),
            "RandomPermutation returns a Cycles expression for length "
                + std::to_string(length));
        if (!encoded.has_head("Cycles") || encoded.args().size() != 1
            || !encoded.args()[0].has_head("List")) continue;

        std::vector<std::size_t> image(length);
        std::iota(image.begin(), image.end(), std::size_t{1});
        std::set<std::size_t> seen;
        std::size_t previous_cycle_minimum = 0;
        bool valid_cycles = true;
        for (const auto& cycle_expression : encoded.args()[0].args()) {
            if (!cycle_expression.has_head("List")
                || cycle_expression.args().size() < 2) {
                valid_cycles = false;
                continue;
            }
            std::vector<std::size_t> cycle;
            for (const auto& member : cycle_expression.args()) {
                if (member.kind() != ExprKind::Integer
                    || !member.integer_value().fits_ulong_p()) {
                    valid_cycles = false;
                    continue;
                }
                const auto value = static_cast<std::size_t>(
                    member.integer_value().get_ui());
                if (value == 0 || value > length || !seen.insert(value).second)
                    valid_cycles = false;
                cycle.push_back(value);
            }
            if (cycle.empty()) continue;
            const auto minimum = *std::min_element(cycle.begin(), cycle.end());
            if (cycle.front() != minimum || minimum <= previous_cycle_minimum)
                valid_cycles = false;
            previous_cycle_minimum = minimum;
            for (std::size_t index = 0; index < cycle.size(); ++index)
                if (cycle[index] >= 1 && cycle[index] <= length)
                    image[cycle[index] - 1] = cycle[(index + 1) % cycle.size()];
        }
        auto sorted_image = image;
        std::sort(sorted_image.begin(), sorted_image.end());
        std::vector<std::size_t> expected_image(length);
        std::iota(expected_image.begin(), expected_image.end(), std::size_t{1});
        check(valid_cycles && sorted_image == expected_image,
            "RandomPermutation cycles encode a canonical permutation for length "
                + std::to_string(length));
        if (length <= 1)
            check(encoded.args()[0].args().empty(),
                "RandomPermutation omits fixed points for length "
                    + std::to_string(length));
    }
    check(evaluate(parse_input_form("RandomPermutation[8/2]")).has_head("Cycles"),
        "RandomPermutation evaluates an exact integer argument");

    const std::vector<std::pair<std::string, std::string>> transcendental_cases{
        {"ComplexExpand[x + I]", "ComplexExpand[Plus[Complex[0, 1], x]]"},
        {"Arg[0]", "0"},
        {"Arg[1]", "0"},
        {"Arg[-1]", "Pi"},
        {"Arg[I]", "Times[Rational[1, 2], Pi]"},
        {"Arg[-I]", "Times[Rational[-1, 2], Pi]"},
        {"Arg[1 + I]", "Times[Rational[1, 4], Pi]"},
        {"Arg[1 + 2 I]", "ArcTan[1, 2]"},
        {"Arg[-1 + 2 I]", "ArcTan[-1, 2]"},
        {"ReIm[1 + 2 I]", "List[1, 2]"},
        {"ReIm[Pi]", "List[Pi, 0]"},
        {"ReIm[Root[#^2 + 1 &, 1]]", "List[0, -1]"},
        {"Arg[Root[#^2 + 1 &, 1]]", "Times[Rational[-1, 2], Pi]"},
        {"ComplexExpand[Re[1 + 2 I]]", "1"},
        {"ComplexExpand[Im[1 + 2 I]]", "2"},
        {"ComplexExpand[Conjugate[1 + 2 I]]", "Complex[1, -2]"},
        {"ComplexExpand[Abs[1 + 2 I]]", "Power[5, Rational[1, 2]]"},
        {"ComplexExpand[Arg[1 + I]]", "Times[Rational[1, 4], Pi]"},
        {"ComplexExpand[Exp[1 + 2 I]]", "Times[E, Plus[Cos[2], Times[Complex[0, 1], Sin[2]]]]"},
        {"ComplexExpand[Sin[1 + 2 I]]", "Plus[Times[Complex[0, 1], Cos[1], Sinh[2]], Times[Cosh[2], Sin[1]]]"},
        {"ComplexExpand[Cos[1 + 2 I]]", "Plus[Times[Complex[0, -1], Sin[1], Sinh[2]], Times[Cos[1], Cosh[2]]]"},
        {"ComplexExpand[Tan[1 + 2 I]]", "Times[Plus[Sin[2], Times[Complex[0, 1], Sinh[4]]], Power[Plus[Cos[2], Cosh[4]], -1]]"},
        {"ComplexExpand[Log[1 + 2 I]]", "Plus[Log[Power[5, Rational[1, 2]]], Times[Complex[0, 1], ArcTan[2]]]"},
        {"ComplexExpand[Sqrt[1 + 2 I]]", "Plus[Power[Times[Rational[1, 2], Plus[1, Power[5, Rational[1, 2]]]], Rational[1, 2]], Times[Complex[0, 1], Power[Times[Rational[1, 2], Plus[-1, Power[5, Rational[1, 2]]]], Rational[1, 2]]]]"},
        {"ComplexExpand[ArcSin[2]]", "Plus[Times[Complex[0, -1], Log[Plus[2, Power[3, Rational[1, 2]]]]], Times[Rational[1, 2], Pi]]"},
        {"ComplexExpand[Re[ArcSin[2]]]", "Times[Rational[1, 2], Pi]"},
        {"ComplexExpand[Im[ArcSin[2]]]", "Times[-1, Log[Plus[2, Power[3, Rational[1, 2]]]]]"},
        {"ComplexExpand[Re[Root[#^2 + 1 &, 1]]]", "0"},
        {"ComplexExpand[Conjugate[Root[#^2 + 1 &, 1]]]", "Complex[0, 1]"},
        {"ComplexExpand[Abs[Root[#^2 + 1 &, 1]]]", "1"},
        {"ComplexExpand[Arg[Root[#^2 + 1 &, 1]]]", "Times[Rational[-1, 2], Pi]"},
        {"ComplexExpand[{Re[1 + I], Im[1 + I], Abs[1 + I], Arg[1 + I]}]", "List[1, 1, Power[2, Rational[1, 2]], Times[Rational[1, 4], Pi]]"},
        {"Simplify[Sin[1]^2 + Cos[1]^2]", "1"},
        {"FullSimplify[Sin[1]^2 + Cos[1]^2]", "1"},
        {"Simplify[Sqrt[2]^2]", "2"},
        {"Simplify[E^Log[2]]", "2"},
        {"Simplify[Root[#^2 - 2 &, 2]^2]", "2"},
        {"Simplify[Sin[1]]", "Sin[1]"},
        {"Simplify[x + 1]", "Plus[1, x]"},
        {"Simplify[Sin[x]^2 + Cos[x]^2]", "Plus[Power[Cos[x], 2], Power[Sin[x], 2]]"},
        {"Exp[1]", "E"},
        {"Exp[2]", "Power[E, 2]"},
        {"Exp[I Pi]", "-1"},
        {"Log[E]", "1"},
        {"Log[10, 100]", "2"},
        {"Log[0]", "-Infinity"},
        {"Log[-1]", "Times[Complex[0, 1], Pi]"},
        {"Sin[0]", "0"},
        {"Sin[Pi/6]", "Rational[1, 2]"},
        {"Cos[Pi/3]", "Rational[1, 2]"},
        {"Tan[Pi/4]", "1"},
        {"Cot[Pi/4]", "1"},
        {"Sec[0]", "1"},
        {"Csc[Pi/2]", "1"},
        {"Tan[Pi/2]", "ComplexInfinity"},
        {"ArcSin[1/2]", "Times[Rational[1, 6], Pi]"},
        {"ArcCos[1/2]", "Times[Rational[1, 3], Pi]"},
        {"ArcTan[1, 1]", "Times[Rational[1, 4], Pi]"},
        {"ArcTan[-1, 1]", "Times[Rational[3, 4], Pi]"},
        {"ArcTan[1, -1]", "Times[Rational[-1, 4], Pi]"},
        {"ArcTan[0, 0]", "Indeterminate"},
        {"ArcCot[-1]", "Times[Rational[3, 4], Pi]"},
        {"ArcSec[2]", "Times[Rational[1, 3], Pi]"},
        {"ArcCsc[2]", "Times[Rational[1, 6], Pi]"},
        {"ArcSin[2]", "ArcSin[2]"},
        {"ArcCosh[2]", "ArcCosh[2]"},
        {"Sinh[0]", "0"},
        {"Cosh[0]", "1"},
        {"Tanh[0]", "0"},
        {"Coth[0]", "ComplexInfinity"},
        {"Sech[0]", "1"},
        {"Csch[0]", "ComplexInfinity"},
        {"ArcCoth[0]", "Times[Complex[0, Rational[1, 2]], Pi]"},
        {"ArcSech[2]", "Times[Complex[0, Rational[1, 3]], Pi]"},
        {"30 Degree", "Times[30, Degree]"},
        {"Sin[30 Degree]", "Rational[1, 2]"},
        {"SinDegrees[30]", "Rational[1, 2]"},
        {"CosDegrees[60]", "Rational[1, 2]"},
        {"TanDegrees[45]", "1"},
        {"CotDegrees[45]", "1"},
        {"SecDegrees[60]", "2"},
        {"CscDegrees[30]", "2"},
        {"ArcSinDegrees[1/2]", "30"},
        {"ArcCosDegrees[1/2]", "60"},
        {"ArcTanDegrees[1]", "45"},
        {"ArcCotDegrees[1]", "45"},
        {"ArcCotDegrees[-1]", "135"},
        {"ArcSecDegrees[2]", "60"},
        {"ArcCscDegrees[2]", "30"},
        {"Haversine[0]", "0"},
        {"Haversine[Pi]", "1"},
        {"Haversine[Pi/5]", "Plus[Rational[3, 8], Times[Rational[-1, 8], Power[5, Rational[1, 2]]]]"},
        {"Haversine[1]", "Haversine[1]"},
        {"InverseHaversine[1]", "Pi"},
        {"InverseHaversine[2]", "InverseHaversine[2]"},
        {"Gudermannian[0]", "0"},
        {"Gudermannian[1]", "Gudermannian[1]"},
        {"InverseGudermannian[0]", "0"},
        {"InverseGudermannian[1]", "InverseGudermannian[1]"},
        {"NumberQ[Pi]", "True"},
        {"NumberQ[I Pi]", "True"},
        {"ExactNumberQ[I Pi]", "True"},
        {"RealValuedNumberQ[Sin[1]]", "True"},
        {"Sin[1.]", "0.8414709848078965"},
        {"Cos[1.]", "0.5403023058681398"},
        {"Exp[1.]", "2.718281828459045"},
        {"Exp[50.]", "5.184705528587072*^+21"},
        {"Log[2.]", "0.6931471805599453"},
        {"ArcTan[1.]", "0.7853981633974483"},
        {"Sin[1`20]", "0.84147098480789650665`20."},
        {"N[Degree, 20]", "0.017453292519943295769`20."},
        {"N[Gudermannian[1], 30]", "0.865769483239658624289601846192`30."},
        {"N[ArcCoth[2], 30]", "0.549306144334054845697622618461`30."},
        {"N[Log[-1], 20]", "Complex[0.`20., 3.1415926535897932385`20.]"},
        {"Pi > 3", "True"},
        {"E < 3", "True"},
        {"Sin[1] > 0", "True"},
        {"UnitStep[Sin[1] - 1/2]", "1"},
        {"Max[Pi, E, 3]", "Pi"},
        {"Min[Sin[1], Cos[1]]", "Cos[1]"},
    };
    for (const auto& [source, expected] : transcendental_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "transcendental evaluator: " + source);

    const std::vector<std::pair<std::string, std::string>> algebraic_root_cases{
        {"Root[I # + 1 &, 1]",
            "Root[Function[Plus[1, Power[Slot[1], 2]]], 2, 0]"},
        {"Root[((1 + I)/2) #^2 + 1 &, 1]",
            "Root[Function[Plus[2, Times[2, Power[Slot[1], 2]], Power[Slot[1], 4]]], 1, 0]"},
        {"Root[#^2 - 2^(1/3) &, 2]",
            "Root[Function[Plus[-2, Power[Slot[1], 6]]], 2, 0]"},
        {"Root[#^2 - Root[#^3 - 2 &, 1] &, 1]",
            "Root[Function[Plus[-2, Power[Slot[1], 6]]], 1, 0]"},
        {"Root[(Root[#^2 - 2 &, 2] + I) #^2 + 1 &, 1]",
            "Root[Function[Plus[1, Times[-2, Power[Slot[1], 4]], Times[9, Power[Slot[1], 8]]]], 3, 0]"},
        {"MinimalPolynomial[Root[#^3 - 2 &, 1]^2, x]",
            "Plus[-4, Power[x, 3]]"},
        {"MinimalPolynomial[Root[#^2 - 2 &, 2] + Root[#^2 - 3 &, 2], x]",
            "Plus[1, Power[x, 4], Times[-10, Power[x, 2]]]"},
        {"RootReduce[Sin[Pi/5]]",
            "Root[Function[Plus[5, Times[-20, Power[Slot[1], 2]], Times[16, Power[Slot[1], 4]]]], 3, 0]"},
        {"RootReduce[Cos[2 Pi/7]]",
            "Root[Function[Plus[-1, Times[-4, Slot[1]], Times[4, Power[Slot[1], 2]], Times[8, Power[Slot[1], 3]]]], 3, 0]"},
        {"RootReduce[SinDegrees[20]]",
            "Root[Function[Plus[-3, Times[36, Power[Slot[1], 2]], Times[-96, Power[Slot[1], 4]], Times[64, Power[Slot[1], 6]]]], 4, 0]"},
        {"RootReduce[Haversine[Pi/5]]",
            "Root[Function[Plus[1, Times[-12, Slot[1]], Times[16, Power[Slot[1], 2]]]], 1, 0]"},
        {"CountRoots[x^3 - x, x]", "3"},
        {"CountRoots[x^2 + 1, x]", "0"},
        {"CountRoots[(x - 1)^2 (x + 1), {x, -2, 2}]", "3"},
        {"CountRoots[(x - 1)^2, {x, 1, 1}]", "2"},
        {"CountRoots[x^2 + 1, {x, -1 - I, 1 + I}]", "2"},
        {"RootIntervals[(x - 1)^2 (x + 1)]",
            "List[List[List[-1, -1], List[1, 1]], List[List[1], List[2]]]"},
        {"RootIntervals[x^2 + 1]", "List[List[], List[]]"},
        {"IsolatingInterval[Root[#^2 - 2 &, 1]]",
            "List[Rational[-91, 64], Rational[-45, 32]]"},
        {"IsolatingInterval[Root[#^2 + 1 &, 1]]",
            "List[Complex[Rational[-1, 128], Rational[-129, 128]], Complex[Rational[1, 128], Rational[-127, 128]]]"},
        {"Normal[RootSum[(# - 1)^2 &, f]]", "Times[2, f[1]]"},
        {"RootSum[#^2 - 2 &, (#^2 &)]", "4"},
        {"RootSum[#^3 - 2 &, (#^3 &)]", "6"},
        {"RootSum[(# - 1)^2 &, (# &)]", "2"},
        {"Conjugate[Root[#^3 - 2 &, 2]]",
            "Root[Function[Plus[-2, Power[Slot[1], 3]]], 3, 0]"},
        {"Root[#^3 - 3 # + 1 &, 1] < Root[#^3 - 3 # + 1 &, 2]", "True"},
        {"Max[Root[#^3 - 3 # + 1 &, 1], Root[#^3 - 3 # + 1 &, 3]]",
            "Root[Function[Plus[1, Times[-3, Slot[1]], Power[Slot[1], 3]]], 3, 0]"},
        {"N[Root[#^3 - 2 &, 1], 30]",
            "1.25992104989487316476721060728`30."},
    };
    for (const auto& [source, expected] : algebraic_root_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "algebraic root evaluator: " + source);

    const std::vector<std::pair<std::string, std::string>> kernel_parity_cases{
        {"Plus[x, Times[-1, y], x]", "Plus[Times[2, x], Times[-1, y]]"},
        {"Plus[Times[a, x], Times[b, x]]", "Times[x, Plus[a, b]]"},
        {"Plus[Times[a, x], Times[b, x], Times[c, y], Times[d, y]]",
            "Plus[Times[x, Plus[a, b]], Times[y, Plus[c, d]]]"},
        {"Power[1, x]", "1"},
        {"Power[Times[a, b], 2]", "Times[Power[a, 2], Power[b, 2]]"},
        {"Power[Times[-1, x], 3]", "Times[-1, Power[x, 3]]"},
        {"Times[Power[x, a], Power[x, b]]", "Power[x, Plus[a, b]]"},
        {"Times[Power[x, a], Power[x, a]]", "Power[x, Times[2, a]]"},
        {"Association[Rule[a, 1], Rule[b, 2], Rule[a, 3]]",
            "Association[Rule[a, 3], Rule[b, 2]]"},
        {"Association[Rule[\"name\", x]][\"name\"]", "x"},
        {"Function[Slot[\"name\"]][Association[Rule[\"name\", x]]]", "x"},
        {"Dot[List[List[1, 2], List[3, 4]], List[5, 6]]", "List[17, 39]"},
        {"FixedPoint[Function[Plus[Slot[1], -1]], 5, 0]", "5"},
        {"FixedPoint[Function[Plus[Slot[1], -1]], 5, 2]", "3"},
        {"FixedPointList[Function[Plus[Slot[1], -1]], 5, 2]", "List[5, 4, 3]"},
        {"Level[f[a, g[b]], List[-1]]", "List[a, b]"},
        {"Outer[f, List[List[a, b], List[c, d]], List[List[x, y], List[z, w]]]",
            "List[List[List[List[f[a, x], f[a, y]], List[f[a, z], f[a, w]]], List[List[f[b, x], f[b, y]], List[f[b, z], f[b, w]]]], List[List[List[f[c, x], f[c, y]], List[f[c, z], f[c, w]]], List[List[f[d, x], f[d, y]], List[f[d, z], f[d, w]]]]]"},
        {"Outer[f, List[List[a, b], List[c, d]], List[List[x, y], List[z, w]], 1]",
            "List[List[f[List[a, b], List[x, y]], f[List[a, b], List[z, w]]], List[f[List[c, d], List[x, y]], f[List[c, d], List[z, w]]]]"},
        {"Outer[f, List[a, List[b, c]], List[x, y], 1]",
            "List[List[f[a, x], f[a, y]], List[f[List[b, c], x], f[List[b, c], y]]]"},
        {"Outer[f, List[a, b], List[x, y], List[u, v], 1]",
            "List[List[List[f[a, x, u], f[a, x, v]], List[f[a, y, u], f[a, y, v]]], List[List[f[b, x, u], f[b, x, v]], List[f[b, y, u], f[b, y, v]]]]"},
        {"Part[List[a, b, c, d, e], Span[5, 1, -1]]", "List[e, d, c, b, a]"},
        {"Part[List[a, b, c, d, e], Span[1, 5, 2]]", "List[a, c, e]"},
        {"Part[List[a, b, c, d], Span[2, All]]", "List[b, c, d]"},
        {"Part[List[a, b, c, d], Span[All, 1, -1]]", "List[d, c, b, a]"},
        {"Part[List[a, b, c, d], All]", "List[a, b, c, d]"},
    };
    for (const auto& [source, expected] : kernel_parity_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "kernel parity evaluator: " + source);

    const std::vector<std::pair<std::string, std::string>> traversal_level_cases{
        {"Level[x,0]", "List[x]"},
        {"Level[f[a,g[b]],{1}]", "List[a, g[b]]"},
        {"Level[f[a,g[b]],{2}]", "List[b]"},
        {"Level[f[a,g[b]],{0,1}]", "List[a, g[b], f[a, g[b]]]"},
        {"Level[<|a->x,b:>g[y]|>,Infinity]", "List[x, y, g[y]]"},
        {"Level[f[],{-2}]", "List[f[]]"},
        {"Level[{a,Nothing,g[b,Nothing]},Infinity]", "List[a, b, g[b, Nothing]]"},
        {"Apply[q,f[a,g[b]]]", "q[a, g[b]]"},
        {"Apply[q,<|a->x,b:>g[y]|>]", "q[x, g[y]]"},
        {"Apply[q,f[a,g[b]],{1}]", "f[a, q[b]]"},
        {"Apply[q,<|a->x,b:>g[y]|>,{1}]",
            "Association[Rule[a, x], RuleDelayed[b, q[y]]]"},
        {"Apply[q,f[a,g[b]],{-2}]", "f[a, q[b]]"},
        {"Apply[q,f[],{-2}]", "q[]"},
        {"Map[q,f[a,g[b]]]", "f[q[a], q[g[b]]]"},
        {"Map[q,<|a->x,b:>g[y]|>]",
            "Association[Rule[a, q[x]], RuleDelayed[b, q[g[y]]]]"},
        {"Map[q,f[a,g[b]],{-1}]", "f[q[a], g[q[b]]]"},
        {"Map[q,f[a,g[b]],{0}]", "q[f[a, g[b]]]"},
        {"Map[q,f[a,g[b]],Heads->True]", "q[f][q[a], q[g[b]]]"},
        {"Map[q,f[a,g[b]],{1,2},Heads->True]", "q[f][q[a], q[q[g][q[b]]]]"},
        {"Map[Function[Nothing],{a,g[b]},Infinity]", "List[]"},
        {"MapApply[q,f[a,g[b]]]", "f[a, q[b]]"},
        {"MapApply[q,<|a->x,b:>g[y]|>]",
            "Association[Rule[a, x], RuleDelayed[b, q[y]]]"},
        {"MapApply[q,f[a,g[b]],{-2}]", "f[a, q[b]]"},
        {"MapApply[q][f[a,g[b]]]", "f[a, q[b]]"},
        {"MapIndexed[q,f[a,g[b]]]", "f[q[a, List[1]], q[g[b], List[2]]]"},
        {"MapIndexed[q,f[a,g[b]],Infinity]",
            "f[q[a, List[1]], q[g[q[b, List[2, 1]]], List[2]]]"},
        {"MapIndexed[q,<|a->x,b:>g[y]|>,Infinity]",
            "Association[Rule[a, q[x, List[Key[a]]]], RuleDelayed[b, "
            "q[g[q[y, List[Key[b], 1]]], List[Key[b]]]]]"},
        {"MapIndexed[q,f[a,g[b]],{-2}]", "f[a, q[g[b], List[2]]]"},
        {"MapIndexed[q][f[a,g[b]]]", "f[q[a, List[1]], q[g[b], List[2]]]"},
        {"MapIndexed[Function[{value,path},path],<|a->x,b->g[y]|>,Infinity]",
            "Association[Rule[a, List[Key[a]]], Rule[b, List[Key[b]]]]"},
    };
    for (const auto& [source, expected] : traversal_level_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "association-aware traversal parity: " + source);

    struct TraversalDiagnosticCase {
        std::string source;
        std::string expected_result;
        std::string expected_message;
    };
    const std::vector<TraversalDiagnosticCase> traversal_diagnostic_cases{
        {"Level[x]", "Level[x]",
            "Level::error: Level expects an expression, a level specification, and an optional heads flag."},
        {"Level[x,1,z]", "Level[x, 1, z]",
            "Level::error: The optional third Level argument must be True or False."},
        {"Level[x,1,True]", "Level[x, 1, True]",
            "Level::error: Level[..., ..., True] is not implemented yet."},
        {"Level[x,z]", "Level[x, z]",
            "Level::error: Unsupported Level specification: 'z'."},
        {"Level[x,{z}]", "Level[x, List[z]]",
            "Level::error: Unsupported level bound: z."},
        {"Apply[q]", "Apply[q]",
            "Apply::error: Apply expects a head, an expression, and an optional level specification."},
        {"Apply[q,x,z]", "Apply[q, x, z]",
            "Apply::error: Unsupported Level specification: 'z'."},
        {"Map[q]", "Map[q]",
            "Map::error: Map expects a function, an expression, and an optional level specification."},
        {"Map[q,x,z]", "Map[q, x, z]",
            "Map::error: Unsupported Level specification: 'z'."},
        {"MapApply[]", "MapApply[]",
            "MapApply::error: MapApply expects a function, an expression, and an optional level specification."},
        {"MapApply[q,x,z]", "MapApply[q, x, z]",
            "MapApply::error: Unsupported Level specification: 'z'."},
        {"MapIndexed[]", "MapIndexed[]",
            "MapIndexed::error: MapIndexed expects a function, an expression, and an optional level specification."},
        {"MapIndexed[q,x,z]", "MapIndexed[q, x, z]",
            "MapIndexed::error: Unsupported Level specification: 'z'."},
    };
    for (const auto& diagnostic : traversal_diagnostic_cases) {
        Evaluator traversal_diagnostics;
        check_equal(traversal_diagnostics.evaluate(parse_input_form(
            diagnostic.source)).to_full_form(), diagnostic.expected_result,
            "traversal failure remains inert: " + diagnostic.source);
        const auto function = diagnostic.source.substr(
            0, diagnostic.source.find('['));
        check_equal(traversal_diagnostics.messages().empty() ? ""
                : traversal_diagnostics.messages().front().to_full_form(),
            "MessageName[" + function + ", \"error\"]",
            "traversal diagnostic message name: " + diagnostic.source);
        check_equal(traversal_diagnostics.message_texts().empty() ? ""
                : traversal_diagnostics.message_texts().front(),
            diagnostic.expected_message,
            "traversal diagnostic text: " + diagnostic.source);
        check(traversal_diagnostics.messages().size() == 1,
            "traversal emits one diagnostic: " + diagnostic.source);
    }

    const std::vector<std::pair<std::string, std::string>> structural_selector_cases{
        {"Part[{a,b,c},{{1},{3}}]", "List[a, c]"},
        {"Part[<|a->1,b->2,c->3|>,0]", "Association"},
        {"Part[<|a->1,b->2,c->3|>,{1,-1}]",
            "Association[Rule[a, 1], Rule[c, 3]]"},
        {"Part[<|a->1,b->2,c->3|>,Span[1,2]]",
            "Association[Rule[a, 1], Rule[b, 2]]"},
        {"Extract[f[a,b,c],0]", "f"},
        {"Extract[f[a,b,c],{{1},{3}}]", "List[a, c]"},
        {"Delete[f[a,b,c],{{1},{3}}]", "f[b]"},
        {"Insert[f[a,b,c],z,0]", "f[z, a, b, c]"},
        {"Insert[f[a,b,c],z,{-1}]", "f[a, b, c, z]"},
        {"Insert[f[a,b,c],z,{{1},{3}}]", "f[z, a, b, z, c]"},
        {"Insert[<|a->1,b->2,c->3|>,z,{{1},{3}}]",
            "Association[z, Rule[a, 1], Rule[b, 2], z, Rule[c, 3]]"},
        {"ReplacePart[f[a,b,c],{{1},{3}}->z]", "f[z, b, z]"},
        {"ReplacePart[<|a->1,b->2,c->3|>,{{1},{3}}->z]",
            "Association[Rule[a, z], Rule[b, 2], Rule[c, z]]"},
    };
    for (const auto& [source, expected] : structural_selector_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "structural selector/path parity: " + source);

    const std::vector<std::pair<std::string, std::string>> conditional_same_q_cases{
        {"DeleteCases[{a,b,c},x_ /; x===b]", "List[a, c]"},
        {"DeleteCases[{a,b,c},x_ /; x===b,{0,Infinity}]", "List[a, c]"},
        {"Replace[{a,b,c},x_ /; x===b->z,{0,Infinity}]", "List[a, z, c]"},
        {"DeleteCases[f[a,b,c],x_ /; x===b]", "f[a, c]"},
        {"DeleteCases[f[a,b,c],x_ /; x===b,{0,Infinity}]", "f[a, c]"},
        {"Replace[f[a,b,c],x_ /; x===b->z,{0,Infinity}]", "f[a, z, c]"},
    };
    for (const auto& [source, expected] : conditional_same_q_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "conditional SameQ pattern parity: " + source);

    struct StructuralDiagnosticCase {
        std::string source;
        std::string expected_result;
        std::string expected_message;
    };
    const std::vector<StructuralDiagnosticCase> structural_diagnostic_cases{
        {"Part[{a,b,c},{0}]", "Part[List[a, b, c], List[0]]",
            "Part::error: Part does not support index 0 in this position."},
        {"Part[<|a->1,b->2,c->3|>,{{1},{3}}]",
            "Part[Association[Rule[a, 1], Rule[b, 2], Rule[c, 3]], List[List[1], List[3]]]",
            "Part::error: Unsupported selector inside Part specification: {{1}, {3}}."},
        {"Extract[{a,b,c},4]", "Extract[List[a, b, c], 4]",
            "Extract::error: Part specifications are invalid for {a, b, c}."},
        {"Extract[{a,b,c},All]", "Extract[List[a, b, c], All]",
            "Extract::error: Extract positions must be a position list or a list of position lists."},
        {"Delete[{a,b,c},0]", "Delete[List[a, b, c], 0]",
            "Delete::error: Position does not support index 0 in this position."},
        {"Delete[{a,b,c},4]", "Delete[List[a, b, c], 4]",
            "Delete::error: Delete positions are invalid for {a, b, c}."},
        {"Delete[{a,b,c},All]", "Delete[List[a, b, c], All]",
            "Delete::error: Unsupported position specification: All."},
        {"Delete[{a,b,c},Span[1,2]]", "Delete[List[a, b, c], Span[1, 2]]",
            "Delete::error: Unsupported position specification: ;; 2."},
        {"Insert[{a,b,c},z,5]", "Insert[List[a, b, c], z, 5]",
            "Insert::error: Insert positions are invalid for {a, b, c}."},
        {"Insert[{a,b,c},z,All]", "Insert[List[a, b, c], z, All]",
            "Insert::error: Insert expects an integer position, a position list, or a list of position lists."},
        {"ReplacePart[{a,b,c},0->z]", "ReplacePart[List[a, b, c], Rule[0, z]]",
            "ReplacePart::error: Position does not support index 0 in this position."},
        {"ReplacePart[{a,b,c},All->z]",
            "ReplacePart[List[a, b, c], Rule[All, z]]",
            "ReplacePart::error: Unsupported position specification: All."},
    };
    for (const auto& diagnostic : structural_diagnostic_cases) {
        Evaluator structural_diagnostics;
        check_equal(structural_diagnostics.evaluate(parse_input_form(
            diagnostic.source)).to_full_form(), diagnostic.expected_result,
            "structural failure remains inert: " + diagnostic.source);
        const auto function = diagnostic.source.substr(
            0, diagnostic.source.find('['));
        check_equal(structural_diagnostics.messages().empty() ? ""
                : structural_diagnostics.messages().front().to_full_form(),
            "MessageName[" + function + ", \"error\"]",
            "structural diagnostic message name: " + diagnostic.source);
        check_equal(structural_diagnostics.message_texts().empty() ? ""
                : structural_diagnostics.message_texts().front(),
            diagnostic.expected_message,
            "structural diagnostic text: " + diagnostic.source);
    }

    const std::vector<std::pair<std::string, std::string>> rounding_multiple_cases{
        {"Floor[-2.5,-2]", "-2"},
        {"Ceiling[.2,2]", "2"},
        {"Round[2.5,2]", "2"},
        {"Floor[3.7,.5]", "3.5"},
        {"Floor[3.7,0.5`20]", "3.5`20."},
    };
    for (const auto& [source, expected] : rounding_multiple_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "rounding multiple result type: " + source);

    check_equal(evaluate(parse_input_form("RankedMin[{3,1,2},2]")).to_full_form(),
        "2", "RankedMin selects a positive rank");
    check_equal(evaluate(parse_input_form(
        "RankedMax[<|a->3,b->1,c->2|>,-2]")).to_full_form(),
        "2", "RankedMax selects a negative rank from association values");

    struct RankedDiagnosticCase {
        std::string source;
        std::string expected_result;
        std::string expected_message;
    };
    const std::vector<RankedDiagnosticCase> ranked_diagnostic_cases{
        {"RankedMin[]", "RankedMin[]",
            "RankedMin::error: RankedMin expects a list and an integer rank."},
        {"RankedMax[x,1]", "RankedMax[x, 1]",
            "RankedMax::error: RankedMax expects a list or association."},
        {"RankedMin[{1,2},x]", "RankedMin[List[1, 2], x]",
            "RankedMin::error: RankedMin expects an explicit integer rank."},
        {"RankedMax[{},1]", "RankedMax[List[], 1]",
            "RankedMax::error: RankedMax requires a nonempty list."},
        {"RankedMin[{1,x},1]", "RankedMin[List[1, x], 1]",
            "RankedMin::error: RankedMin currently expects explicit real-valued numbers."},
        {"RankedMax[{1,2,3},4]", "RankedMax[List[1, 2, 3], 4]",
            "RankedMax::error: RankedMax rank 4 is out of range for a list of length 3."},
        {"RankedMin[{1,2,3},-5]", "RankedMin[List[1, 2, 3], -5]",
            "RankedMin::error: RankedMin rank -5 is out of range for a list of length 3."},
    };
    for (const auto& diagnostic : ranked_diagnostic_cases) {
        Evaluator ranked_diagnostics;
        check_equal(ranked_diagnostics.evaluate(parse_input_form(
            diagnostic.source)).to_full_form(), diagnostic.expected_result,
            "ranked selection failure remains inert: " + diagnostic.source);
        check_equal(ranked_diagnostics.messages().empty() ? ""
                : ranked_diagnostics.messages().front().to_full_form(),
            "MessageName[" + diagnostic.source.substr(0,
                diagnostic.source.find('[')) + ", \"error\"]",
            "ranked selection message name: " + diagnostic.source);
        check_equal(ranked_diagnostics.message_texts().empty() ? ""
                : ranked_diagnostics.message_texts().front(),
            diagnostic.expected_message,
            "ranked selection diagnostic: " + diagnostic.source);
    }

    const std::vector<std::pair<std::string, std::string>> string_parity_cases{
        {u8R"WL(ToUpperCase["café λ"])WL", u8R"WL("CAFÉ Λ")WL"},
        {u8R"WL(ToLowerCase["CAFÉ Λ"])WL", u8R"WL("café λ")WL"},
        {u8R"WL(Capitalize["élan λ"])WL", u8R"WL("Élan λ")WL"},
        {u8R"WL(ToUpperCase["𐐨 ﬃ"])WL", u8R"WL("𐐀 FFI")WL"},
        {u8R"WL(ToLowerCase["İ ΟΣ ΟΣΑ"])WL", u8R"WL("i̇ ος οσα")WL"},
        {u8R"WL(ToLowerCase["AΣ́B ÁΣ"])WL", u8R"WL("aσ́b áς")WL"},
        {u8R"WL(Capitalize["ﬃle"])WL", R"WL("FFIle")WL"},
        {u8R"WL(ToUpperCase[{"café", {"λ"}}])WL",
            u8R"WL(List["CAFÉ", List["Λ"]])WL"},
        {u8R"WL(StringTake["café λ", {1}])WL", u8R"WL("c")WL"},
        {u8R"WL(StringDrop["café λ", {1}])WL", u8R"WL("afé λ")WL"},
        {R"WL(StringTake["abc", {3, 1, -1}])WL", R"WL("cba")WL"},
        {R"WL(StringTake["abc", {{1}, {-1}}])WL", R"WL("abc")WL"},
        {R"WL(StringDrop["abc", {{1}, {-1}}])WL", R"WL("")WL"},
        {R"WL(StringTake["abc", UpTo[2]])WL", R"WL("ab")WL"},
        {R"WL(StringDrop["abc", All])WL", R"WL("")WL"},
        {R"WL(StringSplit["a b", ""])WL", R"WL(List["a b"])WL"},
        {R"WL(StringSplit["", ""])WL", "List[]"},
        {u8R"WL(StringSplit["a b"])WL", R"WL(List["a", "b"])WL"},
        {R"WL(StringPosition["aba", "", 2])WL",
            "List[List[1, 0], List[2, 1]]"},
        {u8R"WL(StringPosition["café λ", ""])WL",
            "List[List[1, 0], List[2, 1], List[3, 2], List[4, 3], "
            "List[5, 4], List[6, 5], List[7, 6]]"},
        {u8R"WL(StringPosition["café λ", LetterCharacter])WL",
            "List[List[1, 1], List[2, 2], List[3, 3], List[4, 4], List[6, 6]]"},
        {R"WL(StringPosition["abc", LetterCharacter, 0])WL", "List[]"},
        {u8R"WL(StringPosition["café λ", __])WL",
            "List[List[1, 6], List[2, 6], List[3, 6], List[4, 6], "
            "List[5, 6], List[6, 6]]"},
        {u8R"WL(StringEndsQ["café λ", LetterCharacter])WL", "True"},
        {u8R"WL(StringCases["café λ", ""])WL",
            R"WL(List["", "", "", "", "", "", ""])WL"},
        {u8R"WL(StringCases["café λ", LetterCharacter])WL",
            u8R"WL(List["c", "a", "f", "é", "λ"])WL"},
        {u8R"WL(StringCases["𐐨", LetterCharacter])WL",
            u8R"WL(List["𐐨"])WL"},
        {u8R"WL(StringCases["éλ", LetterCharacter..])WL",
            u8R"WL(List["éλ"])WL"},
        {u8R"WL(StringCases["é", Alternatives[LetterCharacter, "x"]])WL",
            u8R"WL(List["é"])WL"},
        {u8R"WL(StringCases["é", Pattern[x, LetterCharacter] :> x])WL",
            u8R"WL(List["é"])WL"},
        {u8R"WL(StringCases["١", DigitCharacter])WL",
            u8R"WL(List["١"])WL"},
        {u8R"WL(StringCases[" ", WhitespaceCharacter])WL",
            u8R"WL(List[" "])WL"},
        {u8R"WL(StringCases["—", PunctuationCharacter])WL",
            u8R"WL(List["—"])WL"},
        {u8R"WL(StringCases["é", WordCharacter])WL",
            u8R"WL(List["é"])WL"},
        {u8R"WL(StringCases["a١!", Except[DigitCharacter]])WL",
            u8R"WL(List["a", "!"])WL"},
        {R"WL(StringCases["!", Except[DigitCharacter, LetterCharacter]])WL",
            "List[]"},
        {u8R"WL(StringCases["𐐨", RegularExpression["."]])WL",
            u8R"WL(List["𐐨"])WL"},
        {u8R"WL(StringCases["éé", RegularExpression["é+"]])WL",
            u8R"WL(List["éé"])WL"},
        {u8R"WL(StringCases["É", RegularExpression["(?i)é"]])WL",
            u8R"WL(List["É"])WL"},
        {u8R"WL(StringCases["١٢", RegularExpression["\d{2}"]])WL",
            u8R"WL(List["١٢"])WL"},
        {u8R"WL(StringCases["é", RegularExpression["(?:é|λ)"]])WL",
            u8R"WL(List["é"])WL"},
        {u8R"WL(StringCases["éλ", RegularExpression["é."]])WL",
            u8R"WL(List["éλ"])WL"},
        {u8R"WL(StringCases["١٢", RegularExpression["\d\d"]])WL",
            u8R"WL(List["١٢"])WL"},
        {u8R"WL(StringCases["é", RegularExpression["[éλ]"]])WL",
            u8R"WL(List["é"])WL"},
        {u8R"WL(StringCases["É", RegularExpression["(?i)(é)"]])WL",
            u8R"WL(List["É"])WL"},
        {R"WL(StringCases["abc", RegularExpression["a.(?=c)"]])WL",
            R"WL(List["ab"])WL"},
        {u8R"WL(StringCases["İıſK", RegularExpression["(?i)[isk]"]])WL",
            u8R"WL(List["İ", "ı", "ſ", "K"])WL"},
        {u8R"WL(StringCases["ΣσςµΜμ", RegularExpression["(?i)[σμ]"]])WL",
            u8R"WL(List["Σ", "σ", "ς", "µ", "Μ", "μ"])WL"},
        {u8R"WL(StringCases["éA", RegularExpression["(?i)[a-z]"]])WL",
            R"WL(List["A"])WL"},
        {u8R"WL(StringCases["é\n", RegularExpression["^é$"]])WL",
            u8R"WL(List["é"])WL"},
        {u8R"WL(StringCases["é", RegularExpression["\Aé\Z"]])WL",
            u8R"WL(List["é"])WL"},
        {u8R"WL(StringCases["é", RegularExpression["\u00e9"]])WL",
            u8R"WL(List["é"])WL"},
        {u8R"WL(StringCases["é", RegularExpression["\xE9"]])WL",
            u8R"WL(List["é"])WL"},
        {u8R"WL(StringCases["λ", RegularExpression["(?:é?){2}"]])WL",
            R"WL(List["", ""])WL"},
        {u8R"WL(StringCases["λ", RegularExpression["(?:é*)+"]])WL",
            R"WL(List["", ""])WL"},
        {u8R"WL(StringCases[FromCharacterCode[{8,233}], RegularExpression["[\bé]+"]])WL",
            std::string("List[\"") + '\b' + u8"é\"]"},
        {u8R"WL(StringCases[FromCharacterCode[{8,233}], RegularExpression["[^\b]+"]])WL",
            u8R"WL(List["é"])WL"},
        {u8R"WL(StringCases["a", RegularExpression["é?"]])WL",
            R"WL(List["", ""])WL"},
        {u8R"WL(StringMatchQ["éλ", RegularExpression["é|éλ"]])WL",
            "False"},
        {u8R"WL(StringEndsQ["éλ", RegularExpression["é|éλ"]])WL",
            "False"},
        {u8R"WL(StringCases["éé", StringExpression[RegularExpression["é+"], "é"]])WL",
            "List[]"},
        {R"WL(StringMatchQ["ab", RegularExpression["a|ab"]])WL",
            "False"},
        {R"WL(StringCases["aa", StringExpression[RegularExpression["a+"], "a"]])WL",
            "List[]"},
        {R"WL(StringCases["AB", StringExpression[RegularExpression["(?i)a"], "b"]])WL",
            "List[]"},
        {R"WL(StringCases["ab", StringExpression["A", RegularExpression["(?i)b"]]])WL",
            "List[]"},
        {u8R"WL(StringCases["aé", RegularExpression["^"]])WL",
            R"WL(List[""])WL"},
        {R"WL(StringCases["x\na", RegularExpression["^a"]])WL", "List[]"},
        {R"WL(StringCases["x\na", StringExpression[StartOfLine, "a"]])WL",
            R"WL(List["a"])WL"},
        {R"WL(StringCases["a", Alternatives[RegularExpression["a(?=b)"], LetterCharacter]])WL",
            R"WL(List["a"])WL"},
        {u8R"WL(StringCases["àzê", CharacterRange["à", "ê"]])WL",
            u8R"WL(List["à", "ê"])WL"},
        {u8R"WL(StringCases["١", NumberString])WL",
            u8R"WL(List["١"])WL"},
        {R"WL(StringCases["ab", Alternatives[LetterCharacter, __]])WL",
            R"WL(List["a", "b"])WL"},
        {R"WL(StringCases["ab", Shortest[Longest[__]]])WL",
            R"WL(List["ab"])WL"},
        {R"WL(StringCases["", PatternTest[___, DigitQ]])WL",
            R"WL(List[""])WL"},
        {R"WL(StringCases["ab", LetterCharacter -> Nothing])WL", "List[]"},
        {R"WL(StringCases["ab", LetterCharacter -> Sequence[x, y]])WL",
            "List[x, y, x, y]"},
        {R"WL(StringCases["a", {{"a"}}])WL", R"WL(List["a"])WL"},
        {R"WL(StringMatchQ["ab", Alternatives["a", "ab"]])WL", "True"},
        {R"WL(StringEndsQ["ab", Alternatives["a", "ab"]])WL", "True"},
        {R"WL(StringCases["ab", StringExpression[RegularExpression["(a)"], Pattern[x, _]] -> x])WL",
            R"WL(List["b"])WL"},
        {u8R"WL(StringReplace["café λ", "" -> "x"])WL",
            R"WL("xxxxxxx")WL"},
        {R"WL(StringReplace["", "" -> f["x"]])WL", R"WL(f["x"])WL"},
        {R"WL(StringReplace["a", "a" -> f["x"]])WL", R"WL(f["x"])WL"},
        {R"WL(StringReplace["aa", "a" -> StringExpression[f, g]])WL",
            R"WL(StringExpression[f, g, f, g])WL"},
        {R"WL(StringReplace["ba", "a" -> StringExpression[f, g]])WL",
            R"WL(StringExpression["b", f, g])WL"},
        {R"WL(StringReplace["a", {{"a" -> "x"}}])WL", R"WL("x")WL"},
        {R"WL(CompoundExpression[n = 0, StringReplace["aa", "a" -> (n = n + 1)]])WL",
            "StringExpression[1, 1]"},
        {R"WL(CompoundExpression[n = 0, StringReplace["aa", "a" :> (n = n + 1)]])WL",
            "StringExpression[1, 2]"},
    };
    for (const auto& [source, expected] : string_parity_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "string evaluator parity: " + source);

    struct StringDiagnosticCase {
        std::string source;
        std::string expected_result;
        std::string expected_message;
    };
    const std::vector<StringDiagnosticCase> string_diagnostic_cases{
        {R"WL(StringTake["", 1])WL", R"WL(StringTake["", 1])WL",
            "StringTake::error: Part index 1 is out of range for length 0."},
        {R"WL(StringDrop["", -1])WL", R"WL(StringDrop["", -1])WL",
            "StringDrop::error: Only top-level Part specifications may use index 0."},
        {R"WL(StringTake["a", {1, 2}])WL",
            R"WL(StringTake["a", List[1, 2]])WL",
            "StringTake::error: Part index 2 is out of range for length 1."},
        {R"WL(StringTake["a", {x}])WL",
            R"WL(StringTake["a", List[x]])WL",
            "StringTake::error: StringTake single-element list specifications "
            "must contain an integer, All, or UpTo[n]."},
        {R"WL(StringSplit["a", Whitespace])WL",
            R"WL(StringSplit["a", Whitespace])WL",
            "StringSplit::error: StringSplit currently expects a literal-string "
            "separator or a list of them."},
        {R"WL(StringSplit["a", {",", Whitespace}])WL",
            R"WL(StringSplit["a", List[",", Whitespace]])WL",
            "StringSplit::error: StringSplit currently expects literal-string separators."},
        {R"WL(StringPosition["a", "a", -1])WL",
            R"WL(StringPosition["a", "a", -1])WL",
            "StringPosition::error: Match limits must be non-negative integers or Infinity."},
        {R"WL(StringReplace["a", "a"])WL",
            R"WL(StringReplace["a", "a"])WL",
            "StringReplace::error: StringReplace expects a rule or a list of rules."},
        {R"WL(StringPosition[{"a", 1}, "a"])WL",
            R"WL(StringPosition[List["a", 1], "a"])WL",
            "StringPosition::error: StringPosition expects a string or a list of strings."},
        {R"WL(StringCases[{"a", 1}, "a"])WL",
            R"WL(StringCases[List["a", 1], "a"])WL",
            "StringCases::error: StringCases expects a string or a list of strings."},
        {R"WL(StringReplace[{"a", 1}, "a" -> "x"])WL",
            R"WL(StringReplace[List["a", 1], Rule["a", "x"]])WL",
            "StringReplace::error: StringReplace expects a string or a list of strings."},
        {R"WL(StringContainsQ[{"a", 1}, "a"])WL",
            R"WL(StringContainsQ[List["a", 1], "a"])WL",
            "StringContainsQ::error: StringContainsQ expects a string or a list of strings."},
        {R"WL(StringTake[{"abc", 1}, 1])WL",
            R"WL(StringTake[List["abc", 1], 1])WL",
            "StringTake::error: StringTake expects a string or a list of strings."},
        {R"WL(StringSplit[{"a b", 1}])WL",
            R"WL(StringSplit[List["a b", 1]])WL",
            "StringSplit::error: StringSplit expects a string or a list of strings."},
        {R"WL(StringContainsQ["a", "a", 0])WL",
            R"WL(StringContainsQ["a", "a", 0])WL",
            "StringContainsQ::error: StringContainsQ expects a string and a pattern."},
        {R"WL(StringPosition[])WL", R"WL(StringPosition[])WL",
            "StringPosition::error: StringPosition expects a string, a pattern, and an optional match limit."},
        {R"WL(StringPosition["a", "a", 1, 2])WL",
            R"WL(StringPosition["a", "a", 1, 2])WL",
            "StringPosition::error: StringPosition expects a string, a pattern, and an optional match limit."},
        {R"WL(StringCases[])WL", R"WL(StringCases[])WL",
            "StringCases::error: StringCases expects a string, a pattern or rule, and an optional match limit."},
        {R"WL(StringCases["a"])WL", R"WL(StringCases["a"])WL",
            "StringCases::error: StringCases expects a string, a pattern or rule, and an optional match limit."},
        {R"WL(StringCases["a", "a", 1, 2])WL",
            R"WL(StringCases["a", "a", 1, 2])WL",
            "StringCases::error: StringCases expects a string, a pattern or rule, and an optional match limit."},
        {R"WL(StringReplace[])WL", R"WL(StringReplace[])WL",
            "StringReplace::error: StringReplace expects a string, rules, and an optional replacement limit."},
        {R"WL(StringReplace["a"])WL", R"WL(StringReplace["a"])WL",
            "StringReplace::error: StringReplace expects a string, rules, and an optional replacement limit."},
        {R"WL(StringReplace["a", "a" -> "x", 1, 2])WL",
            R"WL(StringReplace["a", Rule["a", "x"], 1, 2])WL",
            "StringReplace::error: StringReplace expects a string, rules, and an optional replacement limit."},
        {u8R"WL(StringCases["éλ", RegularExpression["é(?=λ)"]])WL",
            u8R"WL(StringCases["éλ", RegularExpression["é(?=λ)"]])WL",
            "StringCases::error: Unsupported Wolfram string-pattern form in the "
            "current Tungsten subset: RegularExpression[\"é(?=λ)\"]."},
        {u8R"WL(StringCases["é", RegularExpression["\N{LATIN SMALL LETTER E WITH ACUTE}"]])WL",
            u8R"WL(StringCases["é", RegularExpression["\\N{LATIN SMALL LETTER E WITH ACUTE}"]])WL",
            "StringCases::error: Unsupported Wolfram string-pattern form in the "
            "current Tungsten subset: RegularExpression[\"\\\\N{LATIN SMALL "
            "LETTER E WITH ACUTE}\"]."},
        {u8R"WL(StringCases["é", RegularExpression["\z"]])WL",
            u8R"WL(StringCases["é", RegularExpression["\\z"]])WL",
            "StringCases::error: Unsupported Wolfram string-pattern form in the "
            "current Tungsten subset: RegularExpression[\"\\\\z\"]."},
        {R"WL(StringCases[" ", RegularExpression["(?=\s)"]])WL",
            R"WL(StringCases[" ", RegularExpression["(?=\\s)"]])WL",
            "StringCases::error: Unsupported Wolfram string-pattern form in the "
            "current Tungsten subset: RegularExpression[\"(?=\\\\s)\"]."},
        {R"WL(StringCases["a\n", RegularExpression["a(?=$)"]])WL",
            R"WL(StringCases["a\n", RegularExpression["a(?=$)"]])WL",
            "StringCases::error: Unsupported Wolfram string-pattern form in the "
            "current Tungsten subset: RegularExpression[\"a(?=$)\"]."},
        {R"WL(StringCases["aaa", RegularExpression["a++a"]])WL",
            R"WL(StringCases["aaa", RegularExpression["a++a"]])WL",
            "StringCases::error: Unsupported Wolfram string-pattern form in the "
            "current Tungsten subset: RegularExpression[\"a++a\"]."},
        {R"WL(StringCases["2024", StringExpression[DatePattern[{"Year"}], RegularExpression[""]]])WL",
            R"WL(StringCases["2024", StringExpression[DatePattern[List["Year"]], RegularExpression[""]]])WL",
            "StringCases::error: Unsupported Wolfram string-pattern form in the "
            "current Tungsten subset: DatePattern[{\"Year\"}]~~"
            "RegularExpression[\"\"]."},
    };
    for (const auto& diagnostic : string_diagnostic_cases) {
        Evaluator string_diagnostics;
        check_equal(string_diagnostics.evaluate(parse_input_form(
            diagnostic.source)).to_full_form(), diagnostic.expected_result,
            "string failure remains inert: " + diagnostic.source);
        const auto function = diagnostic.source.substr(
            0, diagnostic.source.find('['));
        check_equal(string_diagnostics.messages().empty() ? ""
                : string_diagnostics.messages().front().to_full_form(),
            "MessageName[" + function + ", \"error\"]",
            "string diagnostic message name: " + diagnostic.source);
        check_equal(string_diagnostics.message_texts().empty() ? ""
                : string_diagnostics.message_texts().front(),
            diagnostic.expected_message,
            "string diagnostic text: " + diagnostic.source);
    }

    const auto check_held_string_spec = [&](const std::string& setup,
        const std::string& source, const std::string& expected,
        const std::string& function, const std::string& expected_message) {
        Evaluator held_string_spec;
        (void)held_string_spec.evaluate(parse_input_form(setup));
        check_equal(held_string_spec.evaluate(parse_input_form(source)).to_full_form(),
            expected, "held string specification remains raw: " + source);
        check_equal(held_string_spec.messages().empty() ? ""
                : held_string_spec.messages().front().to_full_form(),
            "MessageName[" + function + ", \"error\"]",
            "held string specification message name: " + source);
        check_equal(held_string_spec.message_texts().empty() ? ""
                : held_string_spec.message_texts().front(),
            expected_message,
            "held string specification diagnostic: " + source);
    };
    check_held_string_spec(R"WL(p = "a")WL", R"WL(StringCases["a", p])WL",
        R"WL(StringCases["a", p])WL", "StringCases",
        "StringCases::error: Unsupported Wolfram string-pattern form in the current Tungsten subset: p.");
    check_held_string_spec(R"WL(r = "a" -> "x")WL",
        R"WL(StringReplace["a", r])WL", R"WL(StringReplace["a", r])WL",
        "StringReplace",
        "StringReplace::error: StringReplace expects a rule or a list of rules.");
    check_held_string_spec(R"WL(p = "a")WL",
        R"WL(StringCases["a", p -> "x"])WL",
        R"WL(StringCases["a", Rule[p, "x"]])WL", "StringCases",
        "StringCases::error: Unsupported Wolfram string-pattern form in the current Tungsten subset: p.");
    Evaluator held_rule_evaluation;
    (void)held_rule_evaluation.evaluate(parse_input_form("n = 0"));
    (void)held_rule_evaluation.evaluate(parse_input_form(
        R"WL(StringCases["a", p -> (n = n + 1)])WL"));
    check_equal(held_rule_evaluation.evaluate(parse_input_form("n")).to_full_form(),
        "1", "immediate string Rule RHS evaluates during normalization");
    (void)held_rule_evaluation.evaluate(parse_input_form("n = 0"));
    (void)held_rule_evaluation.evaluate(parse_input_form(
        R"WL(StringCases["a", p :> (n = n + 1)])WL"));
    check_equal(held_rule_evaluation.evaluate(parse_input_form("n")).to_full_form(),
        "0", "delayed string Rule RHS remains held when its pattern is invalid");

    const std::vector<std::pair<std::string, std::string>> take_drop_cases{
        {"Take[{a,b,c},{3,1,-1}]", "List[c, b, a]"},
        {"Drop[{a,b,c},{3,1,-1}]", "List[]"},
        {"Take[{a,b,c},{5,2}]", "List[]"},
        {"Drop[{a,b,c},{2,2,-1}]", "List[a, c]"},
        {"Take[{},0]", "List[]"},
        {"Take[g[a,b,c],None]", "g[]"},
        {"Drop[g[a,b,c],None]", "g[a, b, c]"},
        {"Take[g[g[a,b],g[c,d]],All,-1]", "g[g[b], g[d]]"},
        {"Drop[g[g[a,b],g[c,d]],None,1]", "g[g[b], g[d]]"},
        {"Take[Association[a->1,b->2,c->3],{3,1,-1}]",
            "Association[Rule[c, 3], Rule[b, 2], Rule[a, 1]]"},
        {"Drop[Association[a->1,b->2,c->3],{-1}]",
            "Association[Rule[a, 1], Rule[b, 2]]"},
        {"Take[{a,b,c},{x,y}]", "List[a, b, c]"},
        {"Take[{a,b,c},Span[All,1,-1]]", "List[c, b, a]"},
        {"Take[{a,b,c},{3,1,-9223372036854775808}]", "List[c]"},
    };
    for (const auto& [source, expected] : take_drop_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "Take/Drop selector parity: " + source);

    Evaluator take_drop_diagnostics;
    check_equal(take_drop_diagnostics.evaluate(parse_input_form(
        "Take[{a,b,c},4]")).to_full_form(), "Take[List[a, b, c], 4]",
        "Take out-of-range count remains inert");
    check_equal(take_drop_diagnostics.message_texts().empty() ? ""
            : take_drop_diagnostics.message_texts().front(),
        "Take::error: Part index 4 is out of range for length 3.",
        "Take out-of-range count diagnostic");
    check_equal(take_drop_diagnostics.evaluate(parse_input_form(
        "Take[{a,b,c},-4]")).to_full_form(), "Take[List[a, b, c], -4]",
        "Take negative out-of-range count remains inert");
    check_equal(take_drop_diagnostics.message_texts().empty() ? ""
            : take_drop_diagnostics.message_texts().front(),
        "Take::error: Only top-level Part specifications may use index 0.",
        "Take negative out-of-range diagnostic");
    check_equal(take_drop_diagnostics.evaluate(parse_input_form(
        "Take[{a,b,c},UpTo[5]]")).to_full_form(),
        "Take[List[a, b, c], UpTo[5]]", "unsupported Take UpTo remains inert");
    check_equal(take_drop_diagnostics.message_texts().empty() ? ""
            : take_drop_diagnostics.message_texts().front(),
        "Take::error: Unsupported Take specification: 'UpTo[5]'.",
        "unsupported Take UpTo diagnostic");
    check_equal(take_drop_diagnostics.evaluate(parse_input_form(
        "Take[g[a,b],1,All]")).to_full_form(), "Take[g[a, b], 1, All]",
        "Take multi-axis failure rolls back the complete call");
    check_equal(take_drop_diagnostics.message_texts().empty() ? ""
            : take_drop_diagnostics.message_texts().front(),
        "Take::error: Take expects a nonatomic expression.",
        "Take multi-axis atomic-child diagnostic");
    check_equal(take_drop_diagnostics.evaluate(parse_input_form(
        "Take[{a,b,c},999999999999999999999999999999999]")).to_full_form(),
        "Take[List[a, b, c], 999999999999999999999999999999999]",
        "Take arbitrary-width count remains safe and inert");

    Evaluator gather_by_arity;
    check_equal(gather_by_arity.evaluate(parse_input_form(
        "GatherBy[{1,2,3}]")).to_full_form(),
        "GatherBy[List[1, 2, 3]]",
        "one-argument GatherBy remains inert without indexing a missing key function");
    check_equal(gather_by_arity.messages().empty() ? ""
            : gather_by_arity.messages().front().to_full_form(),
        "MessageName[GatherBy, \"error\"]",
        "one-argument GatherBy message name");
    check_equal(gather_by_arity.message_texts().empty() ? ""
            : gather_by_arity.message_texts().front(),
        "GatherBy::error: GatherBy currently expects two arguments.",
        "one-argument GatherBy message text");
    check(gather_by_arity.prints().empty(),
        "one-argument GatherBy does not produce print effects");

    (void)gather_by_arity.evaluate(parse_input_form(
        "tungstenGatherByAlias=GatherBy"));
    check_equal(gather_by_arity.evaluate(parse_input_form(
        "tungstenGatherByAlias[{1,2,3}]")).to_full_form(),
        "tungstenGatherByAlias[List[1, 2, 3]]",
        "GatherBy alias arity errors preserve the raw call");
    check_equal(gather_by_arity.messages().empty() ? ""
            : gather_by_arity.messages().front().to_full_form(),
        "MessageName[tungstenGatherByAlias, \"error\"]",
        "GatherBy alias message name");
    check_equal(gather_by_arity.message_texts().empty() ? ""
            : gather_by_arity.message_texts().front(),
        "tungstenGatherByAlias::error: GatherBy currently expects two arguments.",
        "GatherBy alias message text");

    Evaluator empty_permute;
    check_equal(empty_permute.evaluate(parse_input_form(
        "Permute[{},{}]")).to_full_form(),
        "List[]", "empty positional permutation is the List identity");
    check(empty_permute.messages().empty()
            && empty_permute.message_texts().empty()
            && empty_permute.prints().empty(),
        "empty positional permutation has no evaluation effects");

    const std::vector<std::pair<std::string, std::string>>
        structural_collection_contracts{
            {"ContainsAll[<|a->1,b->2|>,{1,2}]", "True"},
            {"ContainsAll[{1,2},<|z->2|>]", "True"},
            {"ContainsAny[<|a->1,b->2|>,{2}]", "True"},
            {"ContainsNone[<|a->1,b->2|>,{2}]", "False"},
            {"ContainsExactly[<|a->1,b->2|>,<|x->2,y->1|>]", "True"},
            {"ContainsExactly[{1,1,2},{2,1}]", "True"},
            {"ContainsAll[{},{}]", "True"},
            {"ContainsAny[{},{}]", "False"},
            {"ContainsNone[{},{}]", "True"},
            {"ContainsExactly[{},{}]", "True"},
            {"CountDistinct[<|a->x,b->x,c->y|>]", "2"},
            {"CountDistinct[{1,1.0,1,1.0}]", "2"},
        };
    for (const auto& [source, expected] : structural_collection_contracts)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "structural collection contract: " + source);

    Evaluator structural_collection_diagnostics;
    const auto check_structural_collection_error = [&](const std::string& source,
                                                       const std::string& head,
                                                       const std::string& detail) {
        const auto parsed = parse_input_form(source);
        check_equal(structural_collection_diagnostics.evaluate(parsed).to_full_form(),
            parsed.to_full_form(), head + " preserves the raw invalid call");
        check_equal(structural_collection_diagnostics.messages().empty() ? ""
                : structural_collection_diagnostics.messages().front().to_full_form(),
            "MessageName[" + head + ", \"error\"]",
            head + " invalid collection message name");
        check_equal(structural_collection_diagnostics.message_texts().empty() ? ""
                : structural_collection_diagnostics.message_texts().front(),
            head + "::error: " + detail,
            head + " invalid collection message text");
    };
    check_structural_collection_error(
        "ContainsAll[f[1],g[1]]", "ContainsAll",
        "ContainsAll expects a list or association.");
    check_structural_collection_error(
        "ContainsAny[{1}]", "ContainsAny",
        "ContainsAny expects exactly two arguments.");
    check_structural_collection_error(
        "CountDistinct[f[a,a,b]]", "CountDistinct",
        "CountDistinct expects a list or association.");
    check_structural_collection_error(
        "CountDistinct[{1},x]", "CountDistinct",
        "CountDistinct expects exactly one argument.");
    check_structural_collection_error(
        "CountDistinct[Association[x]]", "CountDistinct",
        "CountDistinct expects a list or association.");
    const auto effectful_collection_source = std::string(
        "ContainsAll[(Print[\"collection-arg\"];f[1]),{1}]");
    const auto effectful_collection_parsed
        = parse_input_form(effectful_collection_source);
    check_equal(structural_collection_diagnostics.evaluate(
            effectful_collection_parsed).to_full_form(),
        effectful_collection_parsed.to_full_form(),
        "collection diagnostics recover the raw syntax after argument effects");
    check(structural_collection_diagnostics.prints()
            == std::vector<std::string>{"collection-arg"},
        "collection diagnostics evaluate argument effects exactly once");
    check_equal(structural_collection_diagnostics.message_texts().empty() ? ""
            : structural_collection_diagnostics.message_texts().front(),
        "ContainsAll::error: ContainsAll expects a list or association.",
        "effectful invalid collection diagnostic text");

    const std::vector<std::pair<std::string, std::string>>
        callback_collection_contracts{
            {"AllTrue[<|a->1,b->2|>,IntegerQ]", "True"},
            {"AnyTrue[<|a->1,b->2|>,#>1&]", "True"},
            {"NoneTrue[<|a->1,b->2|>,#>1&]", "False"},
            {"Tally[<|a->x,b->x,c->y|>]",
                "List[List[x, 2], List[y, 1]]"},
            {"Counts[<|a->x,b->x,c->y|>]",
                "Association[Rule[x, 2], Rule[y, 1]]"},
            {"Tally[{1,2,3},#1<#2&]", "List[List[1, 3]]"},
            {"Counts[{1,2,3},#1<#2&]", "Association[Rule[1, 3]]"},
            {"CountsBy[<|a->1.5,b->1.7,c->2.2|>,Floor]",
                "Association[Rule[1, 2], Rule[2, 1]]"},
            {"ContainsOnly[<|a->1,b->2|>,<|x->1,y->2,z->3|>]", "True"},
            {"ContainsOnly[{1,2},{1,2},SameTest->Automatic]", "True"},
            {"ContainsOnly[{1.0},{1},SameTest:>Equal]", "True"},
            {"ContainsOnly[{1.0},{1},SameTest->SameQ,SameTest->Equal]", "True"},
        };
    for (const auto& [source, expected] : callback_collection_contracts)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "callback collection contract: " + source);

    Evaluator callback_collections;
    check_equal(callback_collections.evaluate(parse_input_form(
        "AllTrue[{1,2,3},(Print[#];#<2)&]")).to_full_form(),
        "False", "AllTrue stops at the first non-True predicate result");
    check(callback_collections.prints() == std::vector<std::string>{"1", "2"},
        "AllTrue short-circuit preserves exact predicate effects");
    check_equal(callback_collections.evaluate(parse_input_form(
        "AnyTrue[{1,2,3},(Print[#];#==2)&]")).to_full_form(),
        "True", "AnyTrue stops at the first True predicate result");
    check(callback_collections.prints() == std::vector<std::string>{"1", "2"},
        "AnyTrue short-circuit preserves exact predicate effects");
    check_equal(callback_collections.evaluate(parse_input_form(
        "NoneTrue[{1,2,3},(Print[#];#==2)&]")).to_full_form(),
        "False", "NoneTrue stops at the first True predicate result");
    check(callback_collections.prints() == std::vector<std::string>{"1", "2"},
        "NoneTrue short-circuit preserves exact predicate effects");

    check_equal(callback_collections.evaluate(parse_input_form(
        "Counts[{1,2},(Print[{#1,#2}];False)&]")).to_full_form(),
        "Association[Rule[1, 1], Rule[2, 1]]",
        "Counts retains distinct groups after a False binary test");
    check(callback_collections.prints() == std::vector<std::string>{"{1, 2}"},
        "Counts calls its binary test as representative then current value");
    check_equal(callback_collections.evaluate(parse_input_form(
        "Tally[{1,2},(Print[{#1,#2}];False)&]")).to_full_form(),
        "List[List[1, 1], List[2, 1]]",
        "Tally retains distinct groups after a False binary test");
    check(callback_collections.prints() == std::vector<std::string>{"{1, 2}"},
        "Tally calls its binary test as representative then current value");

    check_equal(callback_collections.evaluate(parse_input_form(
        "Catch[Counts[{1,2,3},(Print[{#1,#2}];Throw[x])&]]"
        )).to_full_form(),
        "x", "Counts propagates Throw from its binary test");
    check(callback_collections.prints() == std::vector<std::string>{"{1, 2}"},
        "Counts stops invoking its binary test after Throw");
    check_equal(callback_collections.evaluate(parse_input_form(
        "Catch[CountsBy[{1,2,3},(Print[#];If[#==2,Throw[x]];#)&]]"
        )).to_full_form(),
        "x", "CountsBy propagates Throw from its key function");
    check(callback_collections.prints() == std::vector<std::string>{"1", "2"},
        "CountsBy stops invoking its key function after Throw");
    check_equal(callback_collections.evaluate(parse_input_form(
        "Catch[ContainsOnly[{1,2},{0,1,2},"
        "SameTest->((Print[{#1,#2}];Throw[x])&)]]"
        )).to_full_form(),
        "x", "ContainsOnly propagates Throw from SameTest");
    check(callback_collections.prints()
            == std::vector<std::string>{"{1, 0}"},
        "ContainsOnly stops invoking SameTest after Throw");
    check_equal(callback_collections.evaluate(parse_input_form(
        "Enclose[CountsBy[{1,2,3},(Print[#];"
        "If[#==2,Confirm[Failure[\"stop\",<||>]]];#)&]]"
        )).to_full_form(),
        "Failure[\"stop\", Association[]]",
        "CountsBy propagates a confirmation failure from its key function");
    check(callback_collections.prints() == std::vector<std::string>{"1", "2"},
        "CountsBy stops invoking its key function after confirmation failure");
    check_equal(callback_collections.evaluate(parse_input_form(
        "CheckAbort[AnyTrue[{1,2,3},"
        "(Print[#];If[#==2,Abort[]];False)&],caught]"
        )).to_full_form(),
        "caught", "AnyTrue propagates an immediate abort to CheckAbort");
    check(callback_collections.prints() == std::vector<std::string>{"1", "2"},
        "AnyTrue stops invoking its predicate after an immediate abort");

    check_equal(callback_collections.evaluate(parse_input_form(
        "CheckAbort[AbortProtect[AllTrue[{1,2},"
        "(Print[#];If[#==1,Abort[]];True)&];Print[\"after\"]],caught]"
        )).to_full_form(),
        "caught", "AllTrue leaves a protected abort pending for AbortProtect");
    check(callback_collections.prints()
            == std::vector<std::string>{"1", "2", "after"},
        "a protected abort remains invisible to collection iteration");
    check_equal(callback_collections.evaluate(parse_input_form(
        "CheckAbort[AbortProtect[Abort[];CountsBy[{1,2},"
        "(Print[#];#)&];Print[\"after\"]],caught]"
        )).to_full_form(),
        "caught", "CountsBy ignores an enclosing protected pending abort");
    check(callback_collections.prints()
            == std::vector<std::string>{"1", "2", "after"},
        "CountsBy completes while an enclosing protected abort is pending");

    check_equal(callback_collections.evaluate(parse_input_form(
        "ContainsOnly[{1.0,2.0},{0,1,2},"
        "SameTest:>(Print[\"delayed\"];Equal)]"
        )).to_full_form(),
        "True", "ContainsOnly accepts a delayed SameTest option");
    check(callback_collections.prints() == std::vector<std::string>(5, "delayed"),
        "RuleDelayed SameTest is evaluated once per comparison");

    check_structural_collection_error(
        "AllTrue[f[1,2],IntegerQ]", "AllTrue",
        "AllTrue expects a list or association.");
    check_structural_collection_error(
        "AnyTrue[{1}]", "AnyTrue",
        "AnyTrue expects a list and a test function.");
    check_structural_collection_error(
        "Tally[f[a,a,b]]", "Tally",
        "Tally expects a list or association.");
    check_structural_collection_error(
        "Counts[]", "Counts",
        "Counts expects a list or association and an optional binary test.");
    check_structural_collection_error(
        "CountsBy[f[1,2],Identity]", "CountsBy",
        "CountsBy expects a list or association.");
    check_structural_collection_error(
        "ContainsOnly[f[1],g[1]]", "ContainsOnly",
        "ContainsOnly expects a list or association.");
    check_structural_collection_error(
        "ContainsOnly[{1},{1},Heads->False]", "ContainsOnly",
        "ContainsOnly currently supports only the SameTest option.");
    check_structural_collection_error(
        "ContainsOnly[{1},{1},WorkingPrecision->20]", "ContainsOnly",
        "ContainsOnly currently supports only the SameTest option.");
    check_structural_collection_error(
        "ContainsOnly[{1},{1},Rule[SameTest]]", "ContainsOnly",
        "ContainsOnly expects two arguments and an optional SameTest rule.");
    check_structural_collection_error(
        "ContainsOnly[{1},{1},1->Equal]", "ContainsOnly",
        "ContainsOnly expects two arguments and an optional SameTest rule.");
    check_structural_collection_error(
        "ContainsOnly[{1},SameTest->Equal,{1}]", "ContainsOnly",
        "ContainsOnly expects two arguments and an optional SameTest rule.");

    const std::vector<std::pair<std::string, std::string>> accumulate_contracts{
        {"Accumulate[{1,2,3,4}]", "List[1, 3, 6, 10]"},
        {"Accumulate[{1,2,3,4},Times]", "List[1, 2, 6, 24]"},
        {"Accumulate[{}]", "List[]"},
        {"Accumulate[<||>]", "Association[]"},
        {"Accumulate[<|a->1,b->2,c->3|>]",
            "Association[Rule[a, 1], Rule[b, 3], Rule[c, 6]]"},
        {"Accumulate[Association[RuleDelayed[a,1],RuleDelayed[b,2]]]",
            "Association[RuleDelayed[a, 1], RuleDelayed[b, 3]]"},
        {"Accumulate[System`Association[System`RuleDelayed[a,1],"
            "System`Rule[b,2]]]",
            "Association[System`RuleDelayed[a, 1], System`Rule[b, 3]]"},
        {"Accumulate[System`List[1,2,3]]", "List[1, 3, 6]"},
    };
    for (const auto& [source, expected] : accumulate_contracts)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "Accumulate collection contract: " + source);

    Evaluator accumulate_callbacks;
    check_equal(accumulate_callbacks.evaluate(parse_input_form(
        "Catch[Accumulate[{1,2,3},(Print[{#1,#2}];"
        "If[#2==2,Throw[x]];Plus[#1,#2])&]]"
        )).to_full_form(),
        "x", "Accumulate propagates Throw from its combiner");
    check(accumulate_callbacks.prints()
            == std::vector<std::string>{"{1, 2}"},
        "Accumulate stops invoking its combiner after Throw");
    check_equal(accumulate_callbacks.evaluate(parse_input_form(
        "CheckAbort[Accumulate[{1,2,3},(Print[{#1,#2}];"
        "If[#2==2,Abort[]];Plus[#1,#2])&],caught]"
        )).to_full_form(),
        "caught", "Accumulate propagates an immediate abort to CheckAbort");
    check(accumulate_callbacks.prints()
            == std::vector<std::string>{"{1, 2}"},
        "Accumulate stops invoking its combiner after an immediate abort");
    check_equal(accumulate_callbacks.evaluate(parse_input_form(
        "CheckAbort[AbortProtect[Abort[];Accumulate[{1,2,3},"
        "(Print[{#1,#2}];Plus[#1,#2])&];Print[\"after\"]],caught]"
        )).to_full_form(),
        "caught", "Accumulate leaves a protected abort pending");
    check(accumulate_callbacks.prints()
            == std::vector<std::string>{"{1, 2}", "{3, 3}", "after"},
        "Accumulate completes while an enclosing protected abort is pending");

    check_structural_collection_error(
        "Accumulate[f[1,2]]", "Accumulate",
        "Accumulate expects a list or association.");
    check_structural_collection_error(
        "Accumulate[Association[x]]", "Accumulate",
        "Accumulate expects a list or association.");
    check_structural_collection_error(
        "Accumulate[]", "Accumulate",
        "Accumulate expects a list and an optional binary combiner.");
    check_structural_collection_error(
        "Accumulate[{1},Plus,x]", "Accumulate",
        "Accumulate expects a list and an optional binary combiner.");

    const std::vector<std::pair<std::string, std::string>> polynomial_boundary_cases{
        {"ToExpression[\"f[a]\", InputForm, List]", "List[f[a]]"},
        {"Coefficient[2 x^2 y + 3 x y + y, x, 1]", "Times[3, y]"},
        {"CoefficientList[x y + 2 y + 3, {x, y}]", "List[List[3, 2], List[0, 1]]"},
        {"Factor[2 x y + 2 y]", "Times[2, y, Plus[1, x]]"},
        {"Decompose[(x^2 + I x + 1)^2, x]",
            "List[Plus[1, Power[x, 2], Times[2, x]], Plus[Power[x, 2], Times[Complex[0, 1], x]]]"},
        {"Expand[(x + 1)^3]",
            "Plus[1, Power[x, 3], Times[3, x], Times[3, Power[x, 2]]]"},
        {"Expand[(x + 1)^2 (y + 1)^2, x]",
            "Plus[Power[Plus[1, y], 2], Times[2, x, Power[Plus[1, y], 2]], Times[Power[x, 2], Power[Plus[1, y], 2]]]"},
        {"Expand[(x + 1)^2 (y + 1)^2, _Plus]",
            "Plus[1, Power[x, 2], Power[y, 2], Times[2, x], Times[2, x, Power[y, 2]], Times[2, y], Times[2, y, Power[x, 2]], Times[4, x, y], Times[Power[x, 2], Power[y, 2]]]"},
    };
    for (const auto& [source, expected] : polynomial_boundary_cases)
        check_equal(evaluate(parse_input_form(source)).to_full_form(), expected,
            "expanded polynomial boundary: " + source);

    struct OperatorSurfaceExpectation {
        std::string head;
        std::string escaped;
        std::string tex;
        std::string mathml;
    };
    const std::vector<OperatorSurfaceExpectation> operator_surfaces{
        {"CirclePlus", R"(\[CirclePlus])", R"(\oplus)", "&#8853;"},
        {"CircleTimes", R"(\[CircleTimes])", R"(\otimes)", "&#8855;"},
        {"Diamond", R"(\[Diamond])", R"(\diamond)", "&#8900;"},
    };
    auto operator_row_matches = [](const Expr& boxes, const std::string& token) {
        return boxes.has_head("RowBox") && boxes.args().size() == 1
            && boxes.args()[0].has_head("List") && boxes.args()[0].args().size() == 3
            && boxes.args()[0].args()[1].kind() == ExprKind::String
            && boxes.args()[0].args()[1].text() == token;
    };
    for (const auto& surface : operator_surfaces) {
        const auto expression_source = surface.head + "[a, b]";
        const auto tex = evaluate(parse_input_form(
            "ToString[" + expression_source + ", TeXForm]"));
        check(tex.kind() == ExprKind::String && tex.text() == "a" + surface.tex + " b",
            surface.head + " TeX operator rendering");
        const auto mathml = evaluate(parse_input_form(
            "ToString[" + expression_source + ", MathMLForm]"));
        check(mathml.kind() == ExprKind::String
                && mathml.text().find(surface.mathml) != std::string::npos,
            surface.head + " MathML operator rendering");
        const auto traditional = evaluate(parse_input_form(
            "ToString[" + expression_source + ", TraditionalForm]"));
        check(traditional.kind() == ExprKind::String
                && traditional.text().find(surface.escaped) != std::string::npos,
            surface.head + " TraditionalForm operator rendering");
        const auto standard_boxes_value = evaluate(parse_input_form(
            "ToBoxes[" + expression_source + ", StandardForm]"));
        check(operator_row_matches(standard_boxes_value, surface.escaped),
            surface.head + " StandardForm operator boxes");
        const auto made_traditional = evaluate(parse_input_form(
            "MakeBoxes[" + expression_source + ", TraditionalForm]"));
        check(operator_row_matches(made_traditional, surface.escaped),
            surface.head + " MakeBoxes TraditionalForm operator boxes");
        const auto traditional_boxes_value = evaluate(parse_input_form(
            "ToBoxes[" + expression_source + ", TraditionalForm]"));
        check(traditional_boxes_value.has_head("FormBox")
                && traditional_boxes_value.args().size() == 2
                && operator_row_matches(traditional_boxes_value.args()[0], surface.escaped)
                && traditional_boxes_value.args()[1] == symbol("TraditionalForm"),
            surface.head + " ToBoxes TraditionalForm wrapper");
        const auto tex_round_trip = evaluate(parse_input_form(
            "ToExpression[" + wl_string("a" + surface.tex + " b")
                + ", TeXForm, HoldComplete]"));
        check_equal(tex_round_trip.to_full_form(),
            "HoldComplete[" + surface.head + "[a, b]]",
            surface.head + " TeX operator round trip");
    }

    const auto printable_alpha = evaluate(parse_input_form(
        R"WL(ToString["\[Alpha]", InputForm, CharacterEncoding -> "PrintableASCII"])WL"));
    check(printable_alpha.kind() == ExprKind::String
            && printable_alpha.text() == R"WL("\[Alpha]")WL",
        "PrintableASCII named Alpha rendering");
    const auto printable_formal = evaluate(parse_input_form(
        R"WL(ToString["\[FormalA]", InputForm, CharacterEncoding -> "PrintableASCII"])WL"));
    check(printable_formal.kind() == ExprKind::String
            && printable_formal.text() == R"WL("\[FormalA]")WL",
        "PrintableASCII formal character rendering");
    const auto printable_controls = evaluate(parse_input_form(
        R"WL(ToString[FromCharacterCode[{0, 7, 8, 9, 10, 11, 12, 13, 27, 31, 127}], InputForm, CharacterEncoding -> "PrintableASCII"])WL"));
    check(printable_controls.kind() == ExprKind::String
            && printable_controls.text() == R"WL("\000\007\b\t\n\013\f\r\[RawEscape]\037\177")WL",
        "PrintableASCII control escapes");
    const auto printable_invalid_ascii = evaluate(parse_input_form(
        R"WL(ToString[FromCharacterCode[{162}, "ASCII"], InputForm, CharacterEncoding -> "PrintableASCII"])WL"));
    check(printable_invalid_ascii.kind() == ExprKind::String
            && printable_invalid_ascii.text() == R"WL("\:f2a2")WL",
        "ASCII invalid byte private-use mapping");
    const auto printable_mixed_utf8 = evaluate(parse_input_form(
        R"WL(ToString[FromCharacterCode[{195, 169, 945}, "UTF-8"], InputForm, CharacterEncoding -> "PrintableASCII"])WL"));
    check(printable_mixed_utf8.kind() == ExprKind::String
            && printable_mixed_utf8.text() == R"WL("\[EAcute]\[Alpha]")WL",
        "mixed UTF-8 bytes and Unicode code points");
    const auto format_type = evaluate(parse_input_form(
        "ToString[1 + x, FormatType -> TraditionalForm]"));
    check(format_type.kind() == ExprKind::String
            && format_type.text().find("TraditionalForm") != std::string::npos,
        "ToString FormatType option");
    const auto c_form_boxes = evaluate(parse_input_form("ToBoxes[CForm[x^2]]"));
    check(c_form_boxes.has_head("InterpretationBox") && c_form_boxes.args().size() == 4
            && c_form_boxes.args()[0].kind() == ExprKind::String
            && c_form_boxes.args()[0].text() == "Power(x,2)"
            && c_form_boxes.args()[1].has_head("CForm"),
        "CForm InterpretationBox surface");
    const auto mathml_form_boxes = evaluate(parse_input_form("ToBoxes[MathMLForm[1 + x]]"));
    check(mathml_form_boxes.has_head("InterpretationBox")
            && mathml_form_boxes.args().size() == 4
            && mathml_form_boxes.args()[0].kind() == ExprKind::String
            && mathml_form_boxes.args()[0].text().find("<math>") != std::string::npos
            && mathml_form_boxes.args()[1] == call("Plus", {integer(1L), symbol("x")}),
        "MathMLForm InterpretationBox surface");

    const auto shaped_tuples = evaluate(parse_input_form("Tuples[{1, 2}, {2, 3}]"));
    check(shaped_tuples.has_head("List") && shaped_tuples.args().size() == 64,
        "shaped Tuples has 64 outer combinations");
    check(shaped_tuples.has_head("List") && !shaped_tuples.args().empty()
            && shaped_tuples.args().front().to_full_form()
                == "List[List[1, 1, 1], List[1, 1, 1]]"
            && shaped_tuples.args().back().to_full_form()
                == "List[List[2, 2, 2], List[2, 2, 2]]",
        "shaped Tuples preserves tensor shape and lexical endpoints");

    check_equal(stateful.evaluate(parse_input_form("Protect[tungstenProtected]")).to_full_form(),
        "List[\"tungstenProtected\"]", "Protect reports a newly protected symbol");
    check_equal(stateful.evaluate(parse_input_form("tungstenProtected = 5")).to_full_form(),
        "Set[tungstenProtected, 5]", "Set leaves a protected assignment inert");
    check_equal(stateful.messages().empty() ? "" : stateful.messages().front().to_full_form(),
        "MessageName[Set, \"wrsym\"]", "protected Set message name");
    check_equal(stateful.message_texts().empty() ? "" : stateful.message_texts().front(),
        "Set::wrsym: Symbol tungstenProtected is Protected.", "protected Set message text");
    check_equal(stateful.evaluate(parse_input_form("Unprotect[tungstenProtected]")).to_full_form(),
        "List[\"tungstenProtected\"]", "Unprotect reports a changed symbol");
    check_equal(stateful.evaluate(parse_input_form("tungstenProtected = 5")).to_full_form(),
        "5", "Unprotect enables assignment");
    check_equal(stateful.evaluate(parse_input_form("SetAttributes[tungstenLocked, Locked]")).to_full_form(),
        "Null", "Locked attribute setup");
    check_equal(stateful.evaluate(parse_input_form("SetAttributes[tungstenLocked, HoldAll]")).to_full_form(),
        "Null", "locked attribute mutation returns Null");
    check_equal(stateful.messages().empty() ? "" : stateful.messages().front().to_full_form(),
        "MessageName[Attributes, \"locked\"]", "locked attribute message name");
    check_equal(stateful.evaluate(parse_input_form("Attributes[tungstenLocked]")).to_full_form(),
        "List[Locked]", "Locked prevents later attribute changes");
    check_equal(stateful.evaluate(parse_input_form("Plus = 5")).to_full_form(),
        "Set[Plus, 5]", "built-in Protected attribute blocks Set");
    check_equal(stateful.evaluate(parse_input_form("Plus = .")).to_full_form(),
        "$Failed", "built-in Protected attribute blocks Unset");
    check_equal(stateful.evaluate(parse_input_form("Clear[Plus]")).to_full_form(),
        "Null", "Clear of a protected symbol returns Null");
    check_equal(stateful.evaluate(parse_input_form("1 + 2")).to_full_form(),
        "3", "protected mutation attempts preserve built-ins");

    if (failures != 0) {
        std::cerr << failures << " test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all C++ expression tests passed\n";
    return EXIT_SUCCESS;
}
