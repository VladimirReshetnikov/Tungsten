#include "tungsten/parser.hpp"
#include "tungsten/repl.hpp"

#include <cstdlib>
#include <iostream>
#include <sstream>
#include <string>

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

void history_and_exit_tests() {
    tungsten::EvaluationSession defaults;
    check_equal(defaults.evaluate_input("$OutputSizeLimit").result.to_full_form(),
        "12000", "session output-size default");
    check_equal(defaults.evaluate_input("$HistoryLength").result.to_full_form(),
        "Infinity", "session history-length default");
    check_equal(defaults.evaluate_input("ValueQ[$MessagePrePrint]").result.to_full_form(),
        "True", "message preprint hook has its Automatic default");

    std::istringstream input("1+2\n$Line\nInString[1]\n%1 + 10\nQuit\n");
    std::ostringstream output;
    std::ostringstream error;
    const auto code = tungsten::run_repl(input, output, error, false);
    const auto transcript = output.str();
    check(code == 0, "Quit exits with code zero");
    check(transcript.find("In[1]:=") != std::string::npos, "first input prompt");
    check(transcript.find("Out[1]= 3") != std::string::npos, "first result");
    check(transcript.find("Out[2]= 2") != std::string::npos, "$Line result");
    check(transcript.find("Out[3]= 1+2") != std::string::npos, "InString result");
    check(transcript.find("Out[4]= 13") != std::string::npos, "numbered output history");
    check(error.str().empty(), "history transcript has no errors");

    tungsten::EvaluationSession session;
    check_equal(session.evaluate_input("1 + 2").result.to_full_form(), "3", "session first value");
    check_equal(session.evaluate_input("In[]").result.to_full_form(), "3", "default In history");
    check_equal(session.evaluate_input("Out[]").result.to_full_form(), "3", "default Out history");
    check_equal(session.evaluate_input("%%").result.to_full_form(), "3", "negative Out history");
    check(session.evaluate_input("DownValues[In]").result.to_full_form().find(
        "RuleDelayed[HoldPattern[In[1]], Plus[1, 2]]") != std::string::npos,
        "In history is projected through DownValues");
    const auto exit = session.evaluate_input("Exit[7]");
    check(exit.is_exit() && exit.exit_code == 7, "Exit returns requested status");

    tungsten::EvaluationSession messages;
    const auto diagnostic = messages.evaluate_input("Take[<|a->1|>, {Key[a]}]");
    check(!diagnostic.messages.empty(), "evaluator messages are exposed by the session");
    check_equal(messages.evaluate_input("MessageList[1]").result.to_full_form(),
        "List[HoldForm[MessageName[Take, \"error\"]]]", "message history lookup");
}

void parsed_input_and_exit_diagnostic_tests() {
    tungsten::EvaluationSession parsed;
    check_equal(parsed.evaluate_expression("not valid InputForm [", tungsten::integer(42))
            .result.to_full_form(),
        "42", "parsed-expression evaluation does not reparse source text");
    check_equal(parsed.evaluate_expression(
            "InString[1]", tungsten::parse_input_form("InString[1]"))
            .result.to_full_form(),
        "\"not valid InputForm [\"", "parsed-expression source is recorded verbatim");

    tungsten::EvaluationSession line;
    check_equal(line.evaluate_expression("$Line", tungsten::symbol("$Line"))
            .result.to_full_form(),
        "1", "parsed-expression evaluation has active line state");

    tungsten::EvaluationSession exits;
    const auto exit = exits.evaluate_expression(
        "Exit[7]", tungsten::parse_input_form("Exit[7]"));
    check(exit.is_exit() && exit.exit_code == 7,
        "parsed-expression Exit returns the requested status");
    const auto quit = exits.evaluate_expression("Quit", tungsten::symbol("Quit"));
    check(quit.is_exit() && quit.exit_code == 0,
        "parsed-expression bare Quit returns status zero");

    tungsten::EvaluationSession invalid;
    const auto invalid_code = invalid.evaluate_expression(
        "Exit[x]", tungsten::parse_input_form("Exit[x]"));
    check(!invalid_code.is_exit(), "invalid Exit remains an ordinary value");
    check_equal(invalid_code.result.to_full_form(), "Exit[x]",
        "invalid Exit remains inert");
    check(invalid_code.message_names.size() == 1,
        "invalid Exit exposes one structured diagnostic name");
    if (invalid_code.message_names.size() == 1)
        check_equal(invalid_code.message_names.front().to_full_form(),
            "MessageName[Exit, \"error\"]", "invalid Exit diagnostic name");
    check(invalid_code.messages.size() == 1,
        "invalid Exit exposes one diagnostic text");
    if (invalid_code.messages.size() == 1)
        check_equal(invalid_code.messages.front(),
            "Exit::error: Exit and Quit expect an optional integer exit code.",
            "invalid Exit diagnostic text");
    check_equal(invalid.evaluate_expression(
            "MessageList[1]", tungsten::parse_input_form("MessageList[1]"))
            .result.to_full_form(),
        "List[HoldForm[MessageName[Exit, \"error\"]]]",
        "invalid Exit diagnostic is recorded in session message history");

    const auto invalid_arity = invalid.evaluate_expression(
        "Quit[1, 2]", tungsten::parse_input_form("Quit[1, 2]"));
    check_equal(invalid_arity.result.to_full_form(), "Quit[1, 2]",
        "wrong-arity Quit remains inert");
    check(invalid_arity.message_names.size() == 1,
        "wrong-arity Quit exposes one structured diagnostic name");
    if (invalid_arity.message_names.size() == 1)
        check_equal(invalid_arity.message_names.front().to_full_form(),
            "MessageName[Quit, \"error\"]", "wrong-arity Quit diagnostic name");
    check(invalid_arity.messages.size() == 1,
        "wrong-arity Quit exposes one diagnostic text");
    if (invalid_arity.messages.size() == 1)
        check_equal(invalid_arity.messages.front(),
            "Quit::error: Exit and Quit expect zero or one argument.",
            "wrong-arity Quit diagnostic text");
}

void history_pruning_tests() {
    tungsten::EvaluationSession two;
    check_equal(two.evaluate_input("$HistoryLength = 2").result.to_full_form(),
        "2", "finite history length assignment");
    check_equal(two.evaluate_input("10").result.to_full_form(), "10",
        "first finite-history value");
    check_equal(two.evaluate_input("20").result.to_full_form(), "20",
        "second finite-history value");
    check_equal(two.evaluate_input("DownValues[In]").result.to_full_form(),
        "List[RuleDelayed[HoldPattern[In[3]], 20], "
        "RuleDelayed[HoldPattern[In[4]], DownValues[In]]]",
        "history length two is pruned before the current evaluation");

    tungsten::EvaluationSession zero;
    check_equal(zero.evaluate_input("$HistoryLength = 0").result.to_full_form(),
        "0", "zero history length assignment");
    check_equal(zero.evaluate_input("10").result.to_full_form(), "10",
        "zero-history value evaluation");
    check_equal(zero.evaluate_input("DownValues[In]").result.to_full_form(),
        "List[]", "history length zero prunes the current input before evaluation");
}

void installed_history_api_tests() {
    tungsten::EvaluationSession retained;
    const auto expression = tungsten::call("CompoundExpression", {
        tungsten::call("Print", {tungsten::string("kept print")}),
        tungsten::call("Plus", {tungsten::integer(20), tungsten::integer(22)}),
    });
    const auto value = retained.evaluate_expression("original source spelling", expression);
    check_equal(value.result.to_full_form(), "42", "history API source evaluation");

    const auto source = retained.input_string(value.line);
    check(source.has_value(), "history API exposes a retained input string");
    if (source) check_equal(*source, "original source spelling", "retained input string snapshot");
    const auto input = retained.input(value.line);
    check(input.has_value(), "history API exposes a retained input expression");
    if (input) check_equal(input->to_full_form(), expression.to_full_form(),
        "retained input expression is the expression before evaluation");
    const auto output = retained.output(value.line);
    check(output.has_value(), "history API exposes a retained output expression");
    if (output) check_equal(output->to_full_form(), "42", "retained output snapshot");

    const auto names = retained.message_names(value.line);
    check(names.has_value() && names->empty(),
        "retained line distinguishes an empty message-name history from a missing line");
    const auto texts = retained.message_texts(value.line);
    check(texts.has_value() && texts->empty(),
        "retained line distinguishes an empty message-text history from a missing line");
    const auto empty_records = retained.evaluation_messages(value.line);
    check(empty_records.has_value() && empty_records->empty(),
        "retained line distinguishes empty message records from a missing line");
    auto prints = retained.prints(value.line);
    check(prints.has_value() && prints->size() == 1,
        "history API exposes a retained print history");
    if (prints && prints->size() == 1)
        check_equal(prints->front(), "kept print", "retained print snapshot");
    if (prints) prints->clear();
    const auto prints_again = retained.prints(value.line);
    check(prints_again.has_value() && prints_again->size() == 1,
        "history API returns independent snapshots");

    const auto diagnostic = retained.evaluate_input("Take[<|a->1|>, {Key[a]}]");
    const auto diagnostic_names = retained.message_names(diagnostic.line);
    check(diagnostic_names.has_value() && *diagnostic_names == diagnostic.message_names,
        "history API retains structured message names");
    const auto diagnostic_texts = retained.message_texts(diagnostic.line);
    check(diagnostic_texts.has_value() && *diagnostic_texts == diagnostic.messages,
        "history API retains rendered message texts");
    const auto current_records = diagnostic.evaluation_messages();
    check(current_records.size() == 1,
        "session output exposes paired evaluation message records");
    if (current_records.size() == 1) {
        check_equal(current_records.front().name.to_full_form(),
            diagnostic.message_names.front().to_full_form(),
            "session output message record preserves its structured name");
        check_equal(current_records.front().text, diagnostic.messages.front(),
            "session output message record preserves its rendered text");
        check_equal(current_records.front().name_expr().to_full_form(),
            "HoldForm[" + diagnostic.message_names.front().to_full_form() + "]",
            "evaluation message exposes its held name expression");
    }
    auto diagnostic_records = retained.evaluation_messages(diagnostic.line);
    check(diagnostic_records.has_value() && *diagnostic_records == current_records,
        "history API retains paired evaluation message records");
    if (diagnostic_records && !diagnostic_records->empty())
        diagnostic_records->front().text.clear();
    const auto diagnostic_records_again
        = retained.evaluation_messages(diagnostic.line);
    check(diagnostic_records_again.has_value()
            && *diagnostic_records_again == current_records,
        "message-record history returns independent snapshots");
    const auto diagnostic_prints = retained.prints(diagnostic.line);
    check(diagnostic_prints.has_value() && diagnostic_prints->empty(),
        "history API retains an empty print history on a diagnostic line");

    check(!retained.input_string(999).has_value(), "missing input-string history is nullopt");
    check(!retained.input(999).has_value(), "missing input-expression history is nullopt");
    check(!retained.output(999).has_value(), "missing output history is nullopt");
    check(!retained.message_names(999).has_value(), "missing message-name history is nullopt");
    check(!retained.message_texts(999).has_value(), "missing message-text history is nullopt");
    check(!retained.evaluation_messages(999).has_value(),
        "missing message-record history is nullopt");
    check(!retained.prints(999).has_value(), "missing print history is nullopt");

    const tungsten::EvaluationSession& retained_const = retained;
    (void)retained_const.evaluator();

    tungsten::SessionOutput uneven;
    uneven.message_names = {
        tungsten::call("MessageName", {
            tungsten::symbol("f"), tungsten::string("one")}),
        tungsten::call("MessageName", {
            tungsten::symbol("f"), tungsten::string("two")}),
    };
    uneven.messages = {"first"};
    const auto uneven_records = uneven.evaluation_messages();
    check(uneven_records.size() == 1 && uneven_records.front().text == "first",
        "message-record projection defensively zips parallel effect vectors");

    tungsten::EvaluationSession pruned;
    (void)pruned.evaluate_input("$HistoryLength = 1");
    const auto printed = pruned.evaluate_input("Print[\"short lived\"]; 10");
    check(pruned.prints(printed.line).has_value(), "current print history is retained");
    const auto messaged = pruned.evaluate_input("Take[<|a->1|>, {Key[a]}]");
    check(!pruned.input_string(printed.line).has_value(), "pruned input string is nullopt");
    check(!pruned.input(printed.line).has_value(), "pruned input expression is nullopt");
    check(!pruned.output(printed.line).has_value(), "pruned output is nullopt");
    check(!pruned.message_names(printed.line).has_value(), "pruned message names are nullopt");
    check(!pruned.message_texts(printed.line).has_value(), "pruned message texts are nullopt");
    check(!pruned.evaluation_messages(printed.line).has_value(),
        "pruned message records are nullopt");
    check(!pruned.prints(printed.line).has_value(), "pruned prints are nullopt");
    check(pruned.message_names(messaged.line).has_value(),
        "current message-name history survives finite pruning");
    check(pruned.message_texts(messaged.line).has_value(),
        "current message-text history survives finite pruning");

    tungsten::EvaluationSession exits;
    const auto exit_expression = tungsten::call("CompoundExpression", {
        tungsten::call("Print", {tungsten::string("before exit")}),
        tungsten::call("Exit", {tungsten::integer(7)}),
    });
    const auto exit = exits.evaluate_expression("exit source", exit_expression);
    check(exit.is_exit() && exit.exit_code == 7, "history API exit setup");
    check(exits.input_string(exit.line).has_value(), "exit line retains its input string");
    check(exits.input(exit.line).has_value(), "exit line retains its input expression");
    check(!exits.output(exit.line).has_value(), "exit line has no output history entry");
    check(exits.message_names(exit.line).has_value(), "exit line retains message-name history");
    check(exits.message_texts(exit.line).has_value(), "exit line retains message-text history");
    const auto exit_records = exits.evaluation_messages(exit.line);
    check(exit_records.has_value() && exit_records->empty(),
        "exit line retains an empty message-record history");
    const auto exit_prints = exits.prints(exit.line);
    check(exit_prints.has_value() && exit_prints->size() == 1,
        "exit line retains effects produced before exit");
    if (exit_prints && exit_prints->size() == 1)
        check_equal(exit_prints->front(), "before exit", "exit-line print history");
}

void display_and_print_tests() {
    std::istringstream input(
        "InputForm[1 + x]\n"
        "FullForm[1 + x]\n"
        "TeXForm[1 + x]\n"
        "TraditionalForm[1 + x]\n"
        "CForm[x^2]\n"
        "NumberForm[1.2345, 3]\n"
        "Print[InputForm[1 + x]]\n"
        "Print[FullForm[1 + x]]\n"
        "Print[TeXForm[1 + x]]\n"
        "Print[FortranForm[x^2]]\n"
        "Quit\n");
    std::ostringstream output;
    std::ostringstream error;
    check(tungsten::run_repl(input, output, error, false) == 0, "display transcript exits");
    const auto transcript = output.str();
    check(transcript.find("Out[1]//InputForm= 1 + x") != std::string::npos,
        "InputForm output label");
    check(transcript.find("Out[2]//FullForm= Plus[1, x]") != std::string::npos,
        "FullForm output label");
    check(transcript.find("Out[3]//TeXForm= x+1") != std::string::npos,
        "TeXForm output label");
    check(transcript.find("Out[4]//TraditionalForm= \\!\\(\\*FormBox") != std::string::npos,
        "TraditionalForm output label");
    check(transcript.find("Out[5]//CForm= Power(x,2)") != std::string::npos,
        "CForm output label");
    check(transcript.find("Out[6]//NumberForm= 1.23") != std::string::npos,
        "NumberForm output label");
    check(transcript.find("In[7]:= 1 + x") != std::string::npos,
        "InputForm Print text");
    check(transcript.find("In[8]:= Plus[1, x]") != std::string::npos,
        "FullForm Print text");
    check(transcript.find("In[9]:= x+1") != std::string::npos,
        "TeXForm Print text");
    check(transcript.find("In[10]:= x**2") != std::string::npos,
        "FortranForm Print text");
    check(error.str().empty(), "display transcript has no errors");

    using tungsten::display_output_parts;
    check_equal(display_output_parts(tungsten::parse_input_form("BaseForm[31, 16]")).second,
        "16^^1f", "BaseForm rendering");
    check_equal(display_output_parts(tungsten::call("BaseForm", {
        tungsten::integer(31), tungsten::integer(mpz_class("4294967296", 10))})).second,
        "36^^v", "BaseForm size conversion is portable across LP64 and LLP64");
    check_equal(display_output_parts(tungsten::parse_input_form(
        "MatrixForm[{{1, 22}, {333, 4}}]")).second,
        "1     22\n333   4", "MatrixForm rendering");
    check_equal(display_output_parts(tungsten::call(
        "CForm", {tungsten::rational(1, 10000)})).second,
        "0.0001", "CForm rational conversion is correctly rounded");
    check_equal(display_output_parts(tungsten::call(
        "NumberForm", {tungsten::rational(1, 3)})).second,
        "1/3", "NumberForm retains exact rational atoms");
    check_equal(display_output_parts(tungsten::call(
        "ScientificForm", {tungsten::rational(1, 3)})).second,
        "1/3", "ScientificForm retains exact rational atoms");
    check_equal(display_output_parts(tungsten::call(
        "NumberForm", {tungsten::integer(mpz_class("9007199254740993", 10))})).second,
        "9007199254740993", "NumberForm retains arbitrary-width integers exactly");
    check_equal(display_output_parts(tungsten::call("NumberForm", {
        tungsten::list({tungsten::rational(1, 3), tungsten::real("1.2345")}),
        tungsten::integer(3)})).second,
        "{1/3, 1.23}", "NumberForm formats inexact atoms recursively");
    check_equal(display_output_parts(tungsten::call("PaddedForm", {
        tungsten::integer(1), tungsten::integer(4097)})).second,
        "1", "huge padding specifications use bounded default formatting");
    check(display_output_parts(tungsten::call("ScientificForm", {
        tungsten::real("1.2345"), tungsten::integer(4097)})).second.size() < 100,
        "huge precision specifications cannot force unbounded stream output");
}

void hook_and_limit_tests() {
    std::istringstream input(
        "$OutputSizeLimit = 80\n"
        "Range[100]\n"
        "$OutputSizeLimit = Infinity\n"
        "$OutputSizeLimit = 12000\n"
        "$PreRead = Function[s, StringReplace[s, \"aa\" -> \"1+2\"]]\n"
        "aa\n"
        "InString[6]\n"
        "$PreRead =.\n"
        "$PrePrint = FullForm\n"
        "1+x\n"
        "$PrePrint =.\n"
        "Quit\n");
    std::ostringstream output;
    std::ostringstream error;
    check(tungsten::run_repl(input, output, error, false) == 0, "hook transcript exits");
    const auto transcript = output.str();
    check(transcript.find(
        "Out[2]= {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, <<85>>, 96, 97, 98, 99, 100}")
        != std::string::npos, "large output shortened structurally");
    check(transcript.find("Out[6]= 3") != std::string::npos, "$PreRead transforms source");
    check(transcript.find("Out[7]= 1+2") != std::string::npos,
        "transformed source is stored in InString");
    check(transcript.find("Out[10]= Plus[1, x]") != std::string::npos,
        "$PrePrint transforms display without changing output label");
    check(error.str().empty(), "hook transcript has no errors");
}

void error_and_banner_tests() {
    std::istringstream input("1 +\nExit[x]\nExit[5]\n");
    std::ostringstream output;
    std::ostringstream error;
    check(tungsten::run_repl(input, output, error, true) == 5,
        "REPL continues after errors and returns later exit status");
    check(output.str().find("Tungsten 0.1.0 Kernel-free Wolfram Language Interpreter") == 0,
        "banner includes version and interpreter description");
    check(output.str().find("In[3]:=") != std::string::npos,
        "syntax and evaluation failures both consume line numbers");
    check(error.str().find("Syntax::sntxi:") != std::string::npos,
        "syntax errors use Wolfram console label");
    check(error.str().find(
        "Exit::error: Exit and Quit expect an optional integer exit code.")
        != std::string::npos, "invalid Exit uses a head-specific diagnostic");
    check(output.str().find("Out[2]= Exit[x]") != std::string::npos,
        "invalid Exit remains inert and leaves the session running");
}

} // namespace

int main() {
    history_and_exit_tests();
    parsed_input_and_exit_diagnostic_tests();
    history_pruning_tests();
    installed_history_api_tests();
    display_and_print_tests();
    hook_and_limit_tests();
    error_and_banner_tests();
    if (failures != 0) {
        std::cerr << failures << " C++ REPL test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all C++ REPL tests passed\n";
    return EXIT_SUCCESS;
}
