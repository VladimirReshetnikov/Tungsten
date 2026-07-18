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
    check(error.str().find("Evaluate::error: Exit and Quit expect") != std::string::npos,
        "evaluation errors use evaluator label");
}

} // namespace

int main() {
    history_and_exit_tests();
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
