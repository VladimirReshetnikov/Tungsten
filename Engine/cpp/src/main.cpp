#include "tungsten/assistant.hpp"
#include "tungsten/detail/numeric.hpp"
#include "tungsten/discovery.hpp"
#include "tungsten/docs_index.hpp"
#include "tungsten/evaluator.hpp"
#include "tungsten/expression.hpp"
#include "tungsten/frontend.hpp"
#include "tungsten/inline_boxes.hpp"
#include "tungsten/json.hpp"
#include "tungsten/kernel.hpp"
#include "tungsten/notebook.hpp"
#include "tungsten/parser.hpp"
#include "tungsten/parser_corpus.hpp"
#include "tungsten/repl.hpp"
#include "tungsten/wolfram_strings.hpp"

#include <algorithm>
#include <cstdint>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#if defined(_WIN32) && defined(_MSC_VER)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace {

namespace fs = std::filesystem;

fs::path path_from_utf8(std::string_view value) {
    return fs::u8path(value.begin(), value.end());
}

void print_help() {
    std::cout
        << "Tungsten Engine C++ port\n\n"
        << "Usage: tungsten-cpp\n"
        << "       tungsten-cpp [--help|--version]\n"
        << "       tungsten-cpp repl [--no-banner]\n"
        << "       tungsten-cpp parse --code CODE [--form input|full|standard] "
           "[--full-form|--input-form]\n"
        << "       tungsten-cpp eval --code CODE [--input-form]\n"
        << "       tungsten-cpp expr parse (--code CODE|--file FILE) "
           "[--form input|fullform|standard]\n"
        << "       tungsten-cpp expr evaluate (--code CODE|--file FILE) "
           "[--form input|fullform|standard]\n"
        << "       tungsten-cpp env show [--probe]\n"
        << "       tungsten-cpp kernel eval (--code CODE|--file FILE) "
           "[--working-directory DIR] [--front-end] [--require-success]\n"
        << "       tungsten-cpp notebook inspect --file FILE\n"
        << "       tungsten-cpp notebook create --file FILE [--title TITLE] "
           "[--cell STYLE:TEXT ...]\n"
        << "       tungsten-cpp notebook patch --file FILE --spec SPEC [--out FILE]\n"
        << "       tungsten-cpp parser-corpus discover|compare ...\n"
        << "       tungsten-cpp docs index|search|read|open ...\n"
        << "       tungsten-cpp frontend probe|open-notebook|open-doc|run|token ...\n"
        << "       tungsten-cpp assistant ask|ask-cell|prepare-inline|capture-inline ...\n"
        << "       tungsten-cpp inline-box compose [--prefix TEXT] "
           "[--box-expr EXPR ...] [--suffix TEXT]\n"
        << "       tungsten-cpp inline-box from-cell --file FILE SELECTOR "
           "[--prefix TEXT] [--suffix TEXT] [--object-index N|--all-objects]\n"
        << "       tungsten-cpp eval-batch [--stateful]\n";
}

void print_expr_help() {
    std::cout
        << "Parse or structurally evaluate Wolfram expressions with JSON output.\n\n"
        << "Usage: tungsten-cpp expr parse (--code CODE|--file FILE) "
           "[--form input|fullform|standard]\n"
        << "       tungsten-cpp expr evaluate (--code CODE|--file FILE) "
           "[--form input|fullform|standard]\n";
}

std::string json_escape(const std::string& value) {
    return tungsten::json_escape(value);
}

std::string decode_json_string(const std::string& line) {
    const auto value = tungsten::JsonValue::parse(line);
    if (!value.is_string())
        throw std::runtime_error("eval-batch input must contain one JSON string per line");
    return value.as_string();
}

std::string string_array(const std::vector<std::string>& values) {
    std::string output = "[";
    for (std::size_t index = 0; index < values.size(); ++index) {
        if (index) output.push_back(',');
        output += json_escape(values[index]);
    }
    return output + "]";
}

std::string read_text_file(const fs::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) throw std::runtime_error("could not open file: " + path.u8string());
    std::ostringstream contents;
    contents << stream.rdbuf();
    if (!stream.good() && !stream.eof())
        throw std::runtime_error("could not read file: " + path.u8string());
    return contents.str();
}

#if defined(_WIN32) && defined(_MSC_VER)
std::string utf8_from_wide_argument(const wchar_t* value) {
    if (value == nullptr)
        throw std::runtime_error("Windows supplied an empty command-line argument pointer");
    const auto required = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, nullptr, 0, nullptr, nullptr);
    if (required <= 0)
        throw std::runtime_error("could not decode a Windows command-line argument as UTF-8");
    std::string result(static_cast<std::size_t>(required), '\0');
    const auto written = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, value, -1,
        result.data(), required, nullptr, nullptr);
    if (written != required)
        throw std::runtime_error("could not decode a Windows command-line argument as UTF-8");
    result.pop_back();
    return result;
}
#endif

std::string trim_copy(std::string value) {
    const auto first = value.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    const auto last = value.find_last_not_of(" \t\r\n");
    return value.substr(first, last - first + 1);
}

std::int64_t parse_int64_argument(
    const std::string& value, const std::string& option) {
    try {
        std::size_t consumed = 0;
        const auto parsed = std::stoll(value, &consumed);
        if (consumed != value.size()) throw std::invalid_argument("trailing text");
        return parsed;
    } catch (const std::exception&) {
        throw std::invalid_argument(option + " requires an integer: " + value);
    }
}

mpz_class parse_arbitrary_integer_argument(
    const std::string& value, const std::string& option) {
    const auto text = trim_copy(value);
    std::string normalized;
    normalized.reserve(text.size());
    std::size_t index = 0;
    if (!text.empty() && (text.front() == '+' || text.front() == '-')) {
        if (text.front() == '-') normalized.push_back('-');
        index = 1;
    }
    bool previous_digit = false;
    bool any_digit = false;
    for (; index < text.size(); ++index) {
        const auto character = text[index];
        if (character >= '0' && character <= '9') {
            normalized.push_back(character);
            previous_digit = true;
            any_digit = true;
            continue;
        }
        if (character == '_' && previous_digit && index + 1 < text.size()
            && text[index + 1] >= '0' && text[index + 1] <= '9') {
            previous_digit = false;
            continue;
        }
        throw std::invalid_argument(option + " requires an integer: " + value);
    }
    if (!any_digit || !previous_digit)
        throw std::invalid_argument(option + " requires an integer: " + value);
    try {
        return mpz_class(normalized, 10);
    } catch (const std::exception&) {
        throw std::invalid_argument(option + " requires an integer: " + value);
    }
}

std::vector<std::size_t> parse_cell_path_argument(const std::string& source) {
    const auto text = trim_copy(source);
    std::vector<std::int64_t> integers;
    if (text.size() >= 2 && text.front() == '[' && text.back() == ']') {
        const auto value = tungsten::JsonValue::parse(text);
        if (!value.is_array())
            throw std::invalid_argument("JSON cell paths must be arrays of integers");
        for (const auto& item : value.as_array()) {
            if (item.is_boolean()) {
                integers.push_back(item.as_boolean() ? 1 : 0);
                continue;
            }
            const auto integer = item.as_int64();
            if (!integer)
                throw std::invalid_argument("JSON cell paths must be arrays of integers");
            integers.push_back(*integer);
        }
    } else {
        std::size_t start = 0;
        while (start <= text.size()) {
            const auto comma = text.find(',', start);
            const auto end = comma == std::string::npos ? text.size() : comma;
            const auto part = trim_copy(text.substr(start, end - start));
            if (!part.empty())
                integers.push_back(parse_int64_argument(part, "--cell-path"));
            if (comma == std::string::npos) break;
            start = comma + 1;
        }
    }
    if (integers.empty())
        throw std::invalid_argument("Cell paths must contain at least one integer");
    std::vector<std::size_t> path;
    path.reserve(integers.size());
    for (const auto integer : integers) {
        if (integer >= 0 && static_cast<std::uint64_t>(integer)
                > std::numeric_limits<std::size_t>::max())
            throw std::invalid_argument("Cell path index is too large");
        path.push_back(static_cast<std::size_t>(integer));
    }
    return path;
}

bool json_success_is_false(const tungsten::JsonValue& payload) {
    const auto* value = payload.is_object() ? payload.find("success") : nullptr;
    return value && value->is_boolean() && !value->as_boolean();
}

bool is_assistant_selector_argument(const std::string& argument) {
    return argument == "--cell-index" || argument == "--cell-path"
        || argument == "--expression-uuid" || argument == "--cell-id"
        || argument == "--cell-tag";
}

void set_assistant_selector_argument(
    std::optional<tungsten::AssistantCellSelector>& selector,
    const std::string& argument,
    const std::string& value) {
    if (selector)
        throw std::invalid_argument(
            "exactly one notebook cell selector is required");
    if (argument == "--cell-index") {
        const auto parsed = parse_int64_argument(value, argument);
        if (parsed >= 0 && static_cast<std::uint64_t>(parsed)
                > std::numeric_limits<std::size_t>::max())
            throw std::invalid_argument("--cell-index is too large");
        selector = tungsten::AssistantFlatIndexSelector{
            static_cast<std::size_t>(parsed)};
    } else if (argument == "--cell-path") {
        selector = tungsten::AssistantPathSelector{
            parse_cell_path_argument(value)};
    } else if (argument == "--expression-uuid") {
        selector = tungsten::AssistantExpressionUuidSelector{value};
    } else if (argument == "--cell-id") {
        selector = tungsten::AssistantCellIdSelector{
            parse_int64_argument(value, argument)};
    } else {
        selector = tungsten::AssistantCellTagSelector{value};
    }
}

bool parse_form_argument(
    const std::string& value, tungsten::ParseForm& form, std::string& label) {
    if (value == "input") {
        form = tungsten::ParseForm::Input;
        label = "input";
        return true;
    }
    if (value == "full" || value == "fullform") {
        form = tungsten::ParseForm::Full;
        label = "fullform";
        return true;
    }
    if (value == "standard") {
        form = tungsten::ParseForm::Standard;
        label = "standard";
        return true;
    }
    return false;
}

std::string expression_payload(const tungsten::Expr& expression) {
    return "{\"input_form\":" + json_escape(expression.to_input_form())
        + ",\"full_form\":" + json_escape(expression.to_full_form())
        + ",\"depth\":" + std::to_string(expression.depth())
        + ",\"length\":" + std::to_string(expression.length())
        + ",\"tree\":" + expression.to_json() + "}";
}

std::string message_name(const tungsten::Expr& message) {
    if (message.has_head("MessageName") && message.args().size() == 2) {
        const auto* symbol = message.args()[0].symbol_name();
        if (symbol != nullptr && message.args()[1].kind() == tungsten::ExprKind::String)
            return *symbol + "::" + message.args()[1].text();
    }
    return message.to_input_form();
}

std::string message_payloads(
    const std::vector<tungsten::Expr>& names,
    const std::vector<std::string>& texts) {
    std::string output = "[";
    for (std::size_t index = 0; index < names.size(); ++index) {
        if (index) output.push_back(',');
        const auto& message = names[index];
        const auto text = index < texts.size() ? texts[index] : std::string{};
        output += "{\"name\":" + json_escape(message_name(message))
            + ",\"full_name\":" + json_escape(message.to_full_form())
            + ",\"text\":" + json_escape(text) + "}";
    }
    return output + "]";
}

std::string expression_error_payload(
    const std::string& command,
    const std::string& form,
    const std::string& source,
    const std::string& error_type,
    const std::exception& error,
    const tungsten::Expr* parsed = nullptr) {
    std::string output = "{\"command\":" + json_escape(command)
        + ",\"form\":" + json_escape(form)
        + ",\"source\":" + json_escape(source)
        + ",\"success\":false,\"error_type\":" + json_escape(error_type)
        + ",\"error\":" + json_escape(error.what());
    if (parsed != nullptr) {
        output += ",\"parsed_input_form\":" + json_escape(parsed->to_input_form())
            + ",\"parsed_full_form\":" + json_escape(parsed->to_full_form())
            + ",\"parsed_tree\":" + parsed->to_json();
    }
    return output + "}";
}

int execute_expr_command(int argc, char** argv) {
    if (argc == 2) {
        std::cerr << "tungsten-cpp: expr requires a subcommand\n";
        return 2;
    }
    if (argc == 3
        && (std::string(argv[2]) == "--help" || std::string(argv[2]) == "-h")) {
        print_expr_help();
        return 0;
    }
    const std::string command = argv[2];
    if (command != "parse" && command != "evaluate") {
        std::cerr << "tungsten-cpp: unknown expr command: " << command << '\n';
        return 2;
    }
    if (argc == 4
        && (std::string(argv[3]) == "--help" || std::string(argv[3]) == "-h")) {
        print_expr_help();
        return 0;
    }

    std::string code;
    fs::path file;
    bool has_code = false;
    bool has_file = false;
    auto form = tungsten::ParseForm::Input;
    std::string form_label = "input";
    for (int index = 3; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--help" || argument == "-h") {
            print_expr_help();
            return 0;
        }
        if (argument == "--code" || argument == "--file" || argument == "--form") {
            if (index + 1 >= argc) {
                std::cerr << "tungsten-cpp: " << argument << " requires a value\n";
                return 2;
            }
            const std::string value = argv[++index];
            if (argument == "--code") {
                code = value;
                has_code = true;
            } else if (argument == "--file") {
                file = path_from_utf8(value);
                has_file = true;
            } else if (value == "full"
                || !parse_form_argument(value, form, form_label)) {
                std::cerr << "tungsten-cpp: invalid expression form: " << value << '\n';
                return 2;
            }
        } else {
            std::cerr << "tungsten-cpp: unknown expr argument: " << argument << '\n';
            return 2;
        }
    }
    if (has_code == has_file) {
        std::cerr << "tungsten-cpp: exactly one of --code or --file is required\n";
        return 2;
    }

    std::string source;
    try {
        source = has_code ? code : read_text_file(file);
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }

    tungsten::Expr parsed;
    try {
        parsed = tungsten::parse_expression(source, form);
    } catch (const std::exception& error) {
        std::cout << expression_error_payload(
            command, form_label, source, "WolframSyntaxError", error) << '\n';
        return 1;
    }

    if (command == "parse") {
        std::cout << "{\"command\":\"parse\",\"form\":" + json_escape(form_label)
            + ",\"source\":" + json_escape(source)
            + ",\"input_form\":" + json_escape(parsed.to_input_form())
            + ",\"full_form\":" + json_escape(parsed.to_full_form())
            + ",\"depth\":" + std::to_string(parsed.depth())
            + ",\"length\":" + std::to_string(parsed.length())
            + ",\"tree\":" + parsed.to_json() + "}" << '\n';
        return 0;
    }

    tungsten::EvaluationSession session;
    try {
        const auto evaluation = session.evaluate_expression(source, parsed);
        if (evaluation.is_exit()) return evaluation.exit_code;
        const auto& result = evaluation.result;
        std::cout << "{\"command\":\"evaluate\",\"form\":" + json_escape(form_label)
            + ",\"source\":" + json_escape(source)
            + ",\"parsed_input_form\":" + json_escape(parsed.to_input_form())
            + ",\"parsed_full_form\":" + json_escape(parsed.to_full_form())
            + ",\"result\":" + expression_payload(result)
            + ",\"messages\":"
            + message_payloads(evaluation.message_names, evaluation.messages)
            + ",\"prints\":" + string_array(evaluation.prints) + "}" << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cout << expression_error_payload(
            command, form_label, source, "WolframEvaluationError", error, &parsed) << '\n';
        return 1;
    }
}

int execute_kernel_command(int argc, char** argv) {
    if (argc == 2) {
        std::cerr << "tungsten-cpp: kernel requires a subcommand\n";
        return 2;
    }
    if (argc == 3
        && (std::string(argv[2]) == "--help" || std::string(argv[2]) == "-h")) {
        std::cout
            << "Run Wolfram Language code through the discovered local kernel.\n\n"
            << "Usage: tungsten-cpp kernel eval (--code CODE|--file FILE) "
               "[--working-directory DIR] [--front-end] [--require-success]\n";
        return 0;
    }
    if (std::string(argv[2]) != "eval") {
        std::cerr << "tungsten-cpp: unknown kernel command: " << argv[2] << '\n';
        return 2;
    }

    std::optional<std::string> code;
    std::optional<fs::path> file;
    tungsten::KernelEvaluationOptions options;
    bool require_success = false;
    for (int index = 3; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--help" || argument == "-h") {
            std::cout
                << "Usage: tungsten-cpp kernel eval (--code CODE|--file FILE) "
                   "[--working-directory DIR] [--front-end] [--require-success]\n";
            return 0;
        }
        if (argument == "--front-end") {
            options.require_front_end = true;
            continue;
        }
        if (argument == "--require-success") {
            require_success = true;
            continue;
        }
        if (argument != "--code" && argument != "--file"
            && argument != "--working-directory") {
            std::cerr << "tungsten-cpp: unknown kernel eval argument: "
                      << argument << '\n';
            return 2;
        }
        if (index + 1 >= argc) {
            std::cerr << "tungsten-cpp: " << argument << " requires a value\n";
            return 2;
        }
        const std::string value = argv[++index];
        if (argument == "--code") code = value;
        else if (argument == "--file") file = path_from_utf8(value);
        else options.working_directory = path_from_utf8(value);
    }
    if (code.has_value() == file.has_value()) {
        std::cerr << "tungsten-cpp: exactly one of --code or --file is required\n";
        return 2;
    }

    try {
        tungsten::WolframKernelRunner runner;
        const auto result = code
            ? runner.evaluate_text(*code, options)
            : runner.evaluate_file(*file, options);
        std::cout << result.to_json().dump_pretty(2) << '\n';
        if (require_success && result.success == std::optional<bool>(false)) return 1;
        return result.evaluation_available ? 0 : 2;
    } catch (const std::exception& error) {
        std::cerr << "tungsten-cpp: kernel evaluation failed: "
                  << error.what() << '\n';
        return 2;
    }
}

int execute_notebook_command(int argc, char** argv) {
    if (argc == 2) {
        std::cerr << "tungsten-cpp: notebook requires a subcommand\n";
        return 2;
    }
    if (argc == 3
        && (std::string(argv[2]) == "--help" || std::string(argv[2]) == "-h")) {
        std::cout
            << "Inspect or edit Wolfram notebook files.\n\n"
            << "Usage: tungsten-cpp notebook inspect --file FILE\n"
            << "       tungsten-cpp notebook create --file FILE [--title TITLE] "
               "[--cell STYLE:TEXT ...]\n"
            << "       tungsten-cpp notebook patch --file FILE --spec SPEC "
               "[--out FILE]\n";
        return 0;
    }
    const std::string command = argv[2];
    if (command != "inspect" && command != "create" && command != "patch") {
        std::cerr << "tungsten-cpp: unknown notebook command: " << command << '\n';
        return 2;
    }

    std::optional<fs::path> file;
    std::optional<fs::path> spec;
    std::optional<fs::path> destination;
    std::optional<std::string> title;
    std::vector<std::string> cells;
    for (int index = 3; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--help" || argument == "-h") {
            std::cout << "Usage: tungsten-cpp notebook " << command
                      << " --file FILE";
            if (command == "create")
                std::cout << " [--title TITLE] [--cell STYLE:TEXT ...]";
            if (command == "patch") std::cout << " --spec SPEC [--out FILE]";
            std::cout << '\n';
            return 0;
        }
        if (argument != "--file" && argument != "--spec"
            && argument != "--out" && argument != "--title"
            && argument != "--cell") {
            std::cerr << "tungsten-cpp: unknown notebook " << command
                      << " argument: " << argument << '\n';
            return 2;
        }
        if (index + 1 >= argc) {
            std::cerr << "tungsten-cpp: " << argument << " requires a value\n";
            return 2;
        }
        const std::string value = argv[++index];
        if (argument == "--file") file = path_from_utf8(value);
        else if (argument == "--spec") spec = path_from_utf8(value);
        else if (argument == "--out") destination = path_from_utf8(value);
        else if (argument == "--title") title = value;
        else cells.push_back(value);
    }
    if (!file) {
        std::cerr << "tungsten-cpp: notebook " << command
                  << " requires --file\n";
        return 2;
    }
    if (command == "inspect" && (spec || destination || title || !cells.empty())) {
        std::cerr << "tungsten-cpp: notebook inspect only accepts --file\n";
        return 2;
    }
    if (command == "create" && (spec || destination)) {
        std::cerr << "tungsten-cpp: notebook create does not accept --spec or --out\n";
        return 2;
    }
    if (command == "patch" && (!spec || title || !cells.empty())) {
        std::cerr << "tungsten-cpp: notebook patch requires --spec and does not "
                     "accept --title or --cell\n";
        return 2;
    }

    try {
        if (command == "inspect") {
            const auto document = tungsten::NotebookDocument::load(*file);
            std::cout << document.to_json_value().dump_pretty(2) << '\n';
            return 0;
        }
        if (command == "create") {
            tungsten::NotebookDocument document;
            if (title && !title->empty())
                document.set_option("WindowTitle", tungsten::wl_string(*title));
            for (const auto& cell_specification : cells) {
                const auto separator = cell_specification.find(':');
                if (separator == std::string::npos)
                    throw std::invalid_argument(
                        "Invalid cell specification: " + cell_specification);
                document.append_cell(
                    cell_specification.substr(separator + 1),
                    cell_specification.substr(0, separator));
            }
            document.save(*file);
            std::cout << document.to_json_value().dump_pretty(2) << '\n';
            return 0;
        }
        auto document = tungsten::NotebookDocument::load(*file);
        tungsten::apply_patch_spec(document, tungsten::load_patch_spec(*spec));
        document.save(destination.value_or(*file));
        std::cout << document.to_json_value().dump_pretty(2) << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "tungsten-cpp: notebook " << command
                  << " failed: " << error.what() << '\n';
        return 1;
    }
}

int execute_parser_corpus_command(int argc, char** argv) {
    if (argc == 2) {
        std::cerr << "tungsten-cpp: parser-corpus requires a subcommand\n";
        return 2;
    }
    if (argc == 3
        && (std::string(argv[2]) == "--help" || std::string(argv[2]) == "-h")) {
        std::cout
            << "Discover and differentially validate Wolfram parser corpora.\n\n"
            << "Usage: tungsten-cpp parser-corpus discover [DISCOVERY OPTIONS] "
               "[--sample N]\n"
            << "       tungsten-cpp parser-corpus compare [DISCOVERY OPTIONS] "
               "[--skip-wolfram] [--no-write] [--include-results]\n";
        return 0;
    }
    const std::string command = argv[2];
    if (command != "discover" && command != "compare") {
        std::cerr << "tungsten-cpp: unknown parser-corpus command: "
                  << command << '\n';
        return 2;
    }

    fs::path corpus_root = tungsten::default_parser_corpus_root;
    tungsten::CorpusDiscoveryOptions discovery;
    std::vector<std::string> requested_extensions;
    bool shuffle = false;
    std::size_t sample = 20;
    std::optional<fs::path> out_dir;
    std::optional<mpz_class> exact_max_bytes;
    double max_file_mb = static_cast<double>(
        tungsten::default_parser_corpus_max_bytes) / 1024.0 / 1024.0;
    bool no_max_bytes = false;
    auto source_form = tungsten::ParseForm::Input;
    bool skip_wolfram = false;
    std::size_t kernel_batch_size =
        tungsten::default_parser_corpus_kernel_batch_size;
    std::size_t tungsten_workers = tungsten::default_parser_corpus_workers;
    std::size_t preview_chars = tungsten::default_parser_corpus_preview_chars;
    bool no_write = false;
    bool include_results = false;
    bool fail_on_tungsten_gap = false;
    bool fail_on_mismatch = false;

    const auto nonnegative_size = [](std::int64_t value) {
        return value <= 0 ? std::size_t{0} : static_cast<std::size_t>(value);
    };
    for (int index = 3; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--help" || argument == "-h") {
            std::cout << "Usage: tungsten-cpp parser-corpus " << command
                      << " [OPTIONS]\n";
            return 0;
        }
        const bool compare_only = argument == "--out-dir"
            || argument == "--max-file-mb" || argument == "--max-bytes"
            || argument == "--no-max-bytes" || argument == "--form"
            || argument == "--skip-wolfram"
            || argument == "--kernel-batch-size"
            || argument == "--tungsten-workers"
            || argument == "--preview-chars" || argument == "--no-write"
            || argument == "--include-results"
            || argument == "--fail-on-tungsten-gap"
            || argument == "--fail-on-mismatch";
        if ((command == "discover" && compare_only)
            || (command == "compare" && argument == "--sample")) {
            std::cerr << "tungsten-cpp: " << argument << " is not valid for "
                      << "parser-corpus " << command << '\n';
            return 2;
        }
        if (argument == "--shuffle") {
            shuffle = true;
            continue;
        }
        if (argument == "--no-max-bytes") {
            no_max_bytes = true;
            continue;
        }
        if (argument == "--skip-wolfram") {
            skip_wolfram = true;
            continue;
        }
        if (argument == "--no-write") {
            no_write = true;
            continue;
        }
        if (argument == "--include-results") {
            include_results = true;
            continue;
        }
        if (argument == "--fail-on-tungsten-gap") {
            fail_on_tungsten_gap = true;
            continue;
        }
        if (argument == "--fail-on-mismatch") {
            fail_on_mismatch = true;
            continue;
        }
        const bool takes_value = argument == "--corpus-root"
            || argument == "--extension" || argument == "--include-glob"
            || argument == "--exclude-glob" || argument == "--max-files"
            || argument == "--seed" || argument == "--sample"
            || argument == "--out-dir" || argument == "--max-file-mb"
            || argument == "--max-bytes" || argument == "--form"
            || argument == "--kernel-batch-size"
            || argument == "--tungsten-workers"
            || argument == "--preview-chars";
        if (!takes_value) {
            std::cerr << "tungsten-cpp: unknown parser-corpus " << command
                      << " argument: " << argument << '\n';
            return 2;
        }
        if (index + 1 >= argc) {
            std::cerr << "tungsten-cpp: " << argument << " requires a value\n";
            return 2;
        }
        const std::string value = argv[++index];
        try {
            if (argument == "--corpus-root") corpus_root = path_from_utf8(value);
            else if (argument == "--extension")
                requested_extensions.push_back(value);
            else if (argument == "--include-glob")
                discovery.include_globs.push_back(value);
            else if (argument == "--exclude-glob")
                discovery.exclude_globs.push_back(value);
            else if (argument == "--max-files")
                discovery.max_files = nonnegative_size(
                    parse_int64_argument(value, argument));
            else if (argument == "--seed")
                discovery.seed = parse_arbitrary_integer_argument(value, argument);
            else if (argument == "--sample")
                sample = nonnegative_size(parse_int64_argument(value, argument));
            else if (argument == "--out-dir") out_dir = path_from_utf8(value);
            else if (argument == "--max-file-mb") {
                const auto parsed = tungsten::detail::parse_ascii_double(
                    trim_copy(value));
                if (!parsed || !std::isfinite(*parsed))
                    throw std::invalid_argument("invalid floating-point value");
                max_file_mb = *parsed;
            } else if (argument == "--max-bytes")
                exact_max_bytes = parse_arbitrary_integer_argument(value, argument);
            else if (argument == "--form") {
                std::string ignored;
                if (value == "full"
                    || !parse_form_argument(value, source_form, ignored))
                    throw std::invalid_argument("invalid parser form: " + value);
            } else if (argument == "--kernel-batch-size")
                kernel_batch_size = nonnegative_size(
                    parse_int64_argument(value, argument));
            else if (argument == "--tungsten-workers")
                tungsten_workers = nonnegative_size(
                    parse_int64_argument(value, argument));
            else
                preview_chars = nonnegative_size(
                    parse_int64_argument(value, argument));
        } catch (const std::exception& error) {
            std::cerr << "tungsten-cpp: invalid " << argument
                      << ": " << error.what() << '\n';
            return 2;
        }
    }
    discovery.shuffle = shuffle;
    if (!requested_extensions.empty())
        discovery.extensions = std::move(requested_extensions);
    if (command == "discover"
        && (out_dir || exact_max_bytes || no_max_bytes || skip_wolfram
            || no_write || include_results || fail_on_tungsten_gap
            || fail_on_mismatch || kernel_batch_size
                != tungsten::default_parser_corpus_kernel_batch_size
            || tungsten_workers != tungsten::default_parser_corpus_workers
            || preview_chars != tungsten::default_parser_corpus_preview_chars
            || source_form != tungsten::ParseForm::Input
            || max_file_mb
                != static_cast<double>(tungsten::default_parser_corpus_max_bytes)
                    / 1024.0 / 1024.0)) {
        std::cerr << "tungsten-cpp: compare-only option used with "
                     "parser-corpus discover\n";
        return 2;
    }
    if (command == "compare" && sample != 20) {
        std::cerr << "tungsten-cpp: --sample is only valid for discover\n";
        return 2;
    }

    try {
        if (command == "discover") {
            const auto files = tungsten::discover_corpus_files(
                corpus_root, discovery);
            auto payload = tungsten::summarize_discovery(
                files, corpus_root);
            tungsten::JsonValue::Array sample_files;
            for (std::size_t index = 0;
                 index < std::min(sample, files.size()); ++index)
                sample_files.push_back(files[index].to_json_value());
            payload["sample_files"] = std::move(sample_files);
            std::cout << payload.dump_pretty(2) << '\n';
            return 0;
        }

        tungsten::ParserCorpusOptions options;
        options.discovery = std::move(discovery);
        options.out_dir = out_dir;
        if (no_max_bytes) options.max_bytes = std::nullopt;
        else if (exact_max_bytes) options.max_bytes = exact_max_bytes;
        else {
            const auto bytes = max_file_mb * 1024.0 * 1024.0;
            if (!std::isfinite(bytes))
                throw std::invalid_argument("--max-file-mb is too large");
            mpz_class byte_limit;
            mpz_set_d(byte_limit.get_mpz_t(), bytes);
            options.max_bytes = std::move(byte_limit);
        }
        options.source_form = source_form;
        options.compare_wolfram = !skip_wolfram;
        options.kernel_batch_size = std::max<std::size_t>(1, kernel_batch_size);
        options.tungsten_workers = std::max<std::size_t>(1, tungsten_workers);
        options.preview_chars = preview_chars;
        options.write_outputs = !no_write;
        std::optional<tungsten::WolframKernelRunner> runner;
        if (!skip_wolfram) runner.emplace();
        const auto run = tungsten::compare_parser_corpus(
            corpus_root, options, runner ? &*runner : nullptr);
        std::cout << run.to_json_value(include_results).dump_pretty(2) << '\n';

        std::uint64_t gaps = 0;
        std::uint64_t tungsten_only = 0;
        if (const auto* outcomes = run.summary.find("outcomes")) {
            if (const auto* value = outcomes->find("tungsten_gap"))
                gaps = value->as_uint64().value_or(0);
            if (const auto* value = outcomes->find("tungsten_only_success"))
                tungsten_only = value->as_uint64().value_or(0);
        }
        if (fail_on_mismatch && (gaps != 0 || tungsten_only != 0)) return 1;
        if (fail_on_tungsten_gap && gaps != 0) return 1;
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "tungsten-cpp: parser-corpus " << command
                  << " failed: " << error.what() << '\n';
        return 1;
    }
}

int execute_docs_command(int argc, char** argv) {
    if (argc == 2) {
        std::cerr << "tungsten-cpp: docs requires a subcommand\n";
        return 2;
    }
    if (argc == 3
        && (std::string(argv[2]) == "--help" || std::string(argv[2]) == "-h")) {
        std::cout
            << "Search and read the local Wolfram documentation corpus.\n\n"
            << "Usage: tungsten-cpp docs index [--path INDEX]\n"
            << "       tungsten-cpp docs search QUERY [--limit N] "
               "[--index-path INDEX] [--rebuild]\n"
            << "       tungsten-cpp docs read IDENTIFIER "
               "[--index-path INDEX] [--rebuild]\n"
            << "       tungsten-cpp docs open IDENTIFIER [--index-path INDEX]\n";
        return 0;
    }
    const std::string command = argv[2];
    if (command != "index" && command != "search"
        && command != "read" && command != "open") {
        std::cerr << "tungsten-cpp: unknown docs command: " << command << '\n';
        return 2;
    }
    std::optional<fs::path> path;
    std::optional<fs::path> index_path;
    std::optional<std::string> positional;
    std::size_t limit = 10;
    bool limit_set = false;
    bool rebuild = false;
    for (int index = 3; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--help" || argument == "-h") {
            std::cout << "Usage: tungsten-cpp docs " << command;
            if (command == "index") std::cout << " [--path INDEX]";
            else {
                std::cout << " "
                          << (command == "search" ? "QUERY" : "IDENTIFIER")
                          << " [--index-path INDEX]";
                if (command != "open") std::cout << " [--rebuild]";
                if (command == "search") std::cout << " [--limit N]";
            }
            std::cout << '\n';
            return 0;
        }
        if (argument == "--rebuild") {
            rebuild = true;
            continue;
        }
        if (argument == "--path" || argument == "--index-path"
            || argument == "--limit") {
            if (index + 1 >= argc) {
                std::cerr << "tungsten-cpp: " << argument << " requires a value\n";
                return 2;
            }
            const std::string value = argv[++index];
            try {
                if (argument == "--path") path = path_from_utf8(value);
                else if (argument == "--index-path") index_path = path_from_utf8(value);
                else {
                    const auto parsed = parse_int64_argument(value, argument);
                    if (parsed < 0)
                        throw std::invalid_argument("--limit must be nonnegative");
                    limit = static_cast<std::size_t>(parsed);
                    limit_set = true;
                }
            } catch (const std::exception& error) {
                std::cerr << "tungsten-cpp: " << error.what() << '\n';
                return 2;
            }
            continue;
        }
        if (!argument.empty() && argument.front() == '-') {
            std::cerr << "tungsten-cpp: unknown docs " << command
                      << " argument: " << argument << '\n';
            return 2;
        }
        if (positional) {
            std::cerr << "tungsten-cpp: docs " << command
                      << " accepts one positional argument\n";
            return 2;
        }
        positional = argument;
    }
    if (command == "index") {
        if (positional || index_path || rebuild || limit_set) {
            std::cerr << "tungsten-cpp: docs index only accepts --path\n";
            return 2;
        }
    } else if (!positional) {
        std::cerr << "tungsten-cpp: docs " << command
                  << " requires an identifier or query\n";
        return 2;
    } else if (path || (command != "search" && limit_set)
        || (command == "open" && rebuild)) {
        std::cerr << "tungsten-cpp: invalid option for docs " << command << '\n';
        return 2;
    }

    try {
        const auto installation = tungsten::discover_installation();
        tungsten::DocumentationIndex docs(installation);
        if (command == "index") {
            const auto built = docs.build_index(path);
            std::cout << tungsten::JsonValue::object({
                {"index_path", built.u8string()},
            }).dump_pretty(2) << '\n';
            return 0;
        }
        if (command == "search") {
            auto hits = docs.search(*positional, index_path, limit, rebuild);
            std::cout << tungsten::JsonValue::object({
                {"hits", tungsten::JsonValue(
                    tungsten::JsonValue::Array(hits.begin(), hits.end()))},
            }).dump_pretty(2) << '\n';
            return 0;
        }
        if (command == "read") {
            std::cout << docs.read(*positional, index_path, rebuild).dump_pretty(2)
                      << '\n';
            return 0;
        }
        tungsten::FrontEndController controller(
            tungsten::WolframKernelRunner(installation), docs);
        std::cout << controller.open_documentation(*positional, index_path)
                         .to_json().dump_pretty(2)
                  << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "tungsten-cpp: docs " << command
                  << " failed: " << error.what() << '\n';
        return 1;
    }
}

int execute_frontend_command(int argc, char** argv) {
    if (argc == 2) {
        std::cerr << "tungsten-cpp: frontend requires a subcommand\n";
        return 2;
    }
    if (argc == 3
        && (std::string(argv[2]) == "--help" || std::string(argv[2]) == "-h")) {
        std::cout
            << "Programmatically drive Wolfram FrontEnd actions.\n\n"
            << "Usage: tungsten-cpp frontend probe [--require-success]\n"
            << "       tungsten-cpp frontend open-notebook --file FILE "
               "[--require-success]\n"
            << "       tungsten-cpp frontend open-doc IDENTIFIER "
               "[--index-path INDEX] [--require-success]\n"
            << "       tungsten-cpp frontend run --code CODE "
               "[--no-wrap] [--require-success]\n"
            << "       tungsten-cpp frontend token TOKEN [--file FILE] "
               "[--require-success]\n";
        return 0;
    }
    const std::string command = argv[2];
    if (command != "probe" && command != "open-notebook"
        && command != "open-doc" && command != "run" && command != "token") {
        std::cerr << "tungsten-cpp: unknown frontend command: " << command << '\n';
        return 2;
    }
    std::optional<fs::path> file;
    std::optional<fs::path> index_path;
    std::optional<std::string> code;
    std::optional<std::string> positional;
    bool no_wrap = false;
    bool require_success = false;
    for (int index = 3; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--help" || argument == "-h") {
            std::cout << "Usage: tungsten-cpp frontend " << command << " ...\n";
            return 0;
        }
        if (argument == "--require-success") {
            require_success = true;
            continue;
        }
        if (argument == "--no-wrap") {
            no_wrap = true;
            continue;
        }
        if (argument == "--file" || argument == "--index-path"
            || argument == "--code") {
            if (index + 1 >= argc) {
                std::cerr << "tungsten-cpp: " << argument << " requires a value\n";
                return 2;
            }
            const std::string value = argv[++index];
            if (argument == "--file") file = path_from_utf8(value);
            else if (argument == "--index-path") index_path = path_from_utf8(value);
            else code = value;
            continue;
        }
        if (!argument.empty() && argument.front() == '-') {
            std::cerr << "tungsten-cpp: unknown frontend " << command
                      << " argument: " << argument << '\n';
            return 2;
        }
        if (positional) {
            std::cerr << "tungsten-cpp: frontend " << command
                      << " accepts one positional argument\n";
            return 2;
        }
        positional = argument;
    }

    const bool valid = command == "probe"
        ? !file && !index_path && !code && !positional && !no_wrap
        : command == "open-notebook"
            ? file && !index_path && !code && !positional && !no_wrap
            : command == "open-doc"
                ? positional && !file && !code && !no_wrap
                : command == "run"
                    ? code && !file && !index_path && !positional
                    : positional && !index_path && !code && !no_wrap;
    if (!valid) {
        std::cerr << "tungsten-cpp: invalid or missing arguments for frontend "
                  << command << '\n';
        return 2;
    }
    try {
        const auto installation = tungsten::discover_installation();
        tungsten::FrontEndController controller{
            tungsten::WolframKernelRunner(installation),
            tungsten::DocumentationIndex(installation)};
        tungsten::KernelEvaluationResult result;
        if (command == "probe") result = controller.probe();
        else if (command == "open-notebook") result = controller.open_notebook(*file);
        else if (command == "open-doc")
            result = controller.open_documentation(*positional, index_path);
        else if (command == "run") result = controller.run(*code, !no_wrap);
        else result = controller.execute_token(*positional, file);
        std::cout << result.to_json().dump_pretty(2) << '\n';
        return require_success && result.success == std::optional<bool>(false) ? 1 : 0;
    } catch (const std::exception& error) {
        std::cerr << "tungsten-cpp: frontend " << command
                  << " failed: " << error.what() << '\n';
        return 1;
    }
}

int execute_assistant_command(int argc, char** argv) {
    if (argc == 2) {
        std::cerr << "tungsten-cpp: assistant requires a subcommand\n";
        return 2;
    }
    if (argc == 3
        && (std::string(argv[2]) == "--help" || std::string(argv[2]) == "-h")) {
        std::cout
            << "Drive the built-in Wolfram Notebook Assistant.\n\n"
            << "Usage: tungsten-cpp assistant ask --prompt TEXT [OPTIONS]\n"
            << "       tungsten-cpp assistant ask-cell --file FILE SELECTOR "
               "--question TEXT [OPTIONS]\n"
            << "       tungsten-cpp assistant prepare-inline --file FILE SELECTOR\n"
            << "       tungsten-cpp assistant capture-inline --file FILE SELECTOR "
               "[OPTIONS]\n";
        return 0;
    }
    const std::string command = argv[2];
    if (command != "ask" && command != "ask-cell"
        && command != "prepare-inline" && command != "capture-inline") {
        std::cerr << "tungsten-cpp: unknown assistant command: "
                  << command << '\n';
        return 2;
    }

    std::optional<fs::path> file;
    std::optional<tungsten::AssistantCellSelector> selector;
    std::optional<std::string> prompt;
    std::optional<std::string> question;
    std::optional<std::string> system_prompt;
    std::optional<std::string> extra_instructions;
    std::optional<std::string> model_service;
    std::optional<std::string> model_name;
    std::vector<std::string> tools;
    bool tools_set = false;
    bool insert_first = false;
    bool insert_all = false;
    bool save = false;
    bool close_assistant_notebook = false;
    bool require_success = false;

    for (int index = 3; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--help" || argument == "-h") {
            std::cout << "Usage: tungsten-cpp assistant " << command
                      << " [OPTIONS]\n";
            return 0;
        }
        if (argument == "--insert-wolfram-code-below") {
            insert_first = true;
            continue;
        }
        if (argument == "--insert-all-wolfram-code-below") {
            insert_all = true;
            continue;
        }
        if (argument == "--save") {
            save = true;
            continue;
        }
        if (argument == "--close-assistant-notebook") {
            close_assistant_notebook = true;
            continue;
        }
        if (argument == "--require-success") {
            require_success = true;
            continue;
        }
        const bool takes_value = argument == "--file"
            || is_assistant_selector_argument(argument)
            || argument == "--prompt" || argument == "--question"
            || argument == "--system-prompt"
            || argument == "--extra-instructions"
            || argument == "--model-service" || argument == "--model-name"
            || argument == "--tool";
        if (!takes_value) {
            std::cerr << "tungsten-cpp: unknown assistant " << command
                      << " argument: " << argument << '\n';
            return 2;
        }
        if (index + 1 >= argc) {
            std::cerr << "tungsten-cpp: " << argument << " requires a value\n";
            return 2;
        }
        const std::string value = argv[++index];
        try {
            if (argument == "--file") file = path_from_utf8(value);
            else if (is_assistant_selector_argument(argument))
                set_assistant_selector_argument(selector, argument, value);
            else if (argument == "--prompt") prompt = value;
            else if (argument == "--question") question = value;
            else if (argument == "--system-prompt") system_prompt = value;
            else if (argument == "--extra-instructions")
                extra_instructions = value;
            else if (argument == "--model-service") model_service = value;
            else if (argument == "--model-name") model_name = value;
            else {
                tools_set = true;
                tools.push_back(value);
            }
        } catch (const std::exception& error) {
            std::cerr << "tungsten-cpp: " << error.what() << '\n';
            return 2;
        }
    }

    const bool has_cell = file && selector;
    bool valid = false;
    if (command == "ask") {
        valid = prompt && !file && !selector && !question
            && !insert_first && !insert_all && !save
            && !close_assistant_notebook;
    } else if (command == "ask-cell") {
        valid = has_cell && question && !prompt && !system_prompt && !tools_set;
    } else if (command == "prepare-inline") {
        valid = has_cell && !prompt && !question && !system_prompt
            && !extra_instructions && !model_service && !model_name && !tools_set
            && !insert_first && !insert_all && !save
            && !close_assistant_notebook;
    } else {
        valid = has_cell && !prompt && !question && !system_prompt
            && !extra_instructions && !model_service && !model_name && !tools_set
            && !close_assistant_notebook;
    }
    if (!valid) {
        std::cerr << "tungsten-cpp: invalid or missing arguments for assistant "
                  << command << '\n';
        return 2;
    }

    try {
        tungsten::NotebookAssistantController controller;
        tungsten::NotebookAssistantResult result;
        if (command == "ask") {
            tungsten::AskOptions options;
            options.prompt = *prompt;
            options.system_prompt = system_prompt;
            options.extra_instructions = extra_instructions;
            options.model_service = model_service;
            options.model_name = model_name;
            if (tools_set) options.tools = tools;
            result = controller.ask(options);
        } else if (command == "ask-cell") {
            tungsten::AskCellOptions options;
            options.notebook_path = *file;
            options.selector = *selector;
            options.question = *question;
            options.insert_wolfram_code = insert_first;
            options.insert_all_wolfram_code = insert_all;
            options.save_notebook = save;
            options.close_assistant_notebook = close_assistant_notebook;
            options.extra_instructions = extra_instructions;
            options.model_service = model_service;
            options.model_name = model_name;
            result = controller.ask_cell(options);
        } else if (command == "prepare-inline") {
            result = controller.prepare_inline(*file, *selector);
        } else {
            result = controller.capture_inline(
                *file, *selector, insert_first, insert_all, save);
        }
        std::cout << result.to_json().dump_pretty(2) << '\n';
        return require_success && !result.assistant_success() ? 1 : 0;
    } catch (const std::exception& error) {
        std::cerr << "tungsten-cpp: assistant " << command
                  << " failed: " << error.what() << '\n';
        return 1;
    }
}

std::string box_expression_head(const std::string& source) {
    try {
        const auto expression = tungsten::parse_input_form(source);
        if (!expression.is_atom()) return expression.head().to_input_form();
        return expression.to_input_form();
    } catch (const std::exception&) {
        const auto bracket = source.find('[');
        auto head = source.substr(0, bracket);
        const auto first = head.find_first_not_of(" \t\r\n");
        if (first == std::string::npos) return {};
        head.erase(0, first);
        const auto last = head.find_last_not_of(" \t\r\n");
        head.erase(last + 1);
        return head;
    }
}

int execute_inline_box_from_cell(int argc, char** argv) {
    std::optional<fs::path> file;
    std::optional<tungsten::InlineBoxCellSelector> selector;
    tungsten::InlineBoxExtractionOptions options;
    bool require_success = false;
    for (int index = 3; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--help" || argument == "-h") {
            std::cout
                << "Usage: tungsten-cpp inline-box from-cell --file FILE "
                   "(--cell-index N|--cell-path PATH|--expression-uuid UUID|"
                   "--cell-id ID|--cell-tag TAG) [--prefix TEXT] [--suffix TEXT] "
                   "[--object-index N] [--all-objects] [--require-success]\n";
            return 0;
        }
        if (argument == "--all-objects") {
            options.all_objects = true;
            continue;
        }
        if (argument == "--require-success") {
            require_success = true;
            continue;
        }
        const bool selector_argument = argument == "--cell-index"
            || argument == "--cell-path" || argument == "--expression-uuid"
            || argument == "--cell-id" || argument == "--cell-tag";
        if (argument != "--file" && argument != "--prefix"
            && argument != "--suffix" && argument != "--object-index"
            && !selector_argument) {
            std::cerr << "tungsten-cpp: unknown inline-box from-cell argument: "
                      << argument << '\n';
            return 2;
        }
        if (index + 1 >= argc) {
            std::cerr << "tungsten-cpp: " << argument << " requires a value\n";
            return 2;
        }
        const std::string value = argv[++index];
        try {
            if (argument == "--file") file = path_from_utf8(value);
            else if (argument == "--prefix") options.prefix = value;
            else if (argument == "--suffix") options.suffix = value;
            else if (argument == "--object-index") {
                const auto parsed = parse_int64_argument(value, argument);
                if (parsed < std::numeric_limits<long>::min()
                    || parsed > std::numeric_limits<long>::max())
                    throw std::invalid_argument(
                        "--object-index is outside the supported integer range");
                options.object_index = static_cast<long>(parsed);
            }
            else {
                if (selector) {
                    std::cerr << "tungsten-cpp: exactly one notebook cell "
                                 "selector is required\n";
                    return 2;
                }
                if (argument == "--cell-index") {
                    const auto parsed = parse_int64_argument(value, argument);
                    if (parsed >= 0 && static_cast<std::uint64_t>(parsed)
                            > std::numeric_limits<std::size_t>::max())
                        throw std::invalid_argument(
                            "--cell-index is too large");
                    selector = tungsten::InlineBoxFlatIndexSelector{
                        static_cast<std::size_t>(parsed)};
                } else if (argument == "--cell-path") {
                    selector = tungsten::InlineBoxPathSelector{
                        parse_cell_path_argument(value)};
                } else if (argument == "--expression-uuid") {
                    selector = tungsten::InlineBoxExpressionUuidSelector{value};
                } else if (argument == "--cell-id") {
                    selector = tungsten::InlineBoxCellIdSelector{
                        parse_int64_argument(value, argument)};
                } else {
                    selector = tungsten::InlineBoxCellTagSelector{value};
                }
            }
        } catch (const std::exception& error) {
            std::cerr << "tungsten-cpp: " << error.what() << '\n';
            return 2;
        }
    }
    if (!file || !selector) {
        std::cerr << "tungsten-cpp: inline-box from-cell requires --file and "
                     "exactly one cell selector\n";
        return 2;
    }
    try {
        const auto payload = tungsten::extract_inline_boxes_from_notebook_cell(
            *file, *selector, options);
        std::cout << payload.dump_pretty(2) << '\n';
        return require_success && json_success_is_false(payload) ? 1 : 0;
    } catch (const std::exception& error) {
        std::cerr << "tungsten-cpp: inline-box extraction failed: "
                  << error.what() << '\n';
        return 1;
    }
}

int execute_inline_box_command(int argc, char** argv) {
    if (argc == 2) {
        std::cerr << "tungsten-cpp: inline-box requires a subcommand\n";
        return 2;
    }
    if (argc == 3
        && (std::string(argv[2]) == "--help" || std::string(argv[2]) == "-h")) {
        std::cout
            << "Compose or extract Wolfram strings containing embedded box expressions.\n\n"
            << "Usage: tungsten-cpp inline-box compose [--prefix TEXT] "
               "[--box-expr EXPR ...] [--suffix TEXT]\n"
            << "       tungsten-cpp inline-box from-cell --file FILE SELECTOR "
               "[--prefix TEXT] [--suffix TEXT]\n";
        return 0;
    }
    const std::string command = argv[2];
    if (command == "from-cell") return execute_inline_box_from_cell(argc, argv);
    if (command != "compose") {
        std::cerr << "tungsten-cpp: unknown inline-box command: " << command << '\n';
        return 2;
    }
    if (argc == 4
        && (std::string(argv[3]) == "--help" || std::string(argv[3]) == "-h")) {
        std::cout
            << "Usage: tungsten-cpp inline-box compose [--prefix TEXT] "
               "[--box-expr EXPR ...] [--suffix TEXT]\n";
        return 0;
    }

    std::string prefix;
    std::string suffix;
    std::vector<std::string> boxes;
    for (int index = 3; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--help" || argument == "-h") {
            std::cout
                << "Usage: tungsten-cpp inline-box compose [--prefix TEXT] "
                   "[--box-expr EXPR ...] [--suffix TEXT]\n";
            return 0;
        }
        if (argument != "--prefix" && argument != "--suffix" && argument != "--box-expr") {
            std::cerr << "tungsten-cpp: unknown inline-box argument: " << argument << '\n';
            return 2;
        }
        if (index + 1 >= argc) {
            std::cerr << "tungsten-cpp: " << argument << " requires a value\n";
            return 2;
        }
        const std::string value = argv[++index];
        if (argument == "--prefix") prefix = value;
        else if (argument == "--suffix") suffix = value;
        else boxes.push_back(value);
    }

    const auto string_value = tungsten::compose_inline_box_string(prefix, boxes, suffix);
    std::string box_payload = "[";
    for (std::size_t index = 0; index < boxes.size(); ++index) {
        if (index) box_payload.push_back(',');
        const auto escaped = tungsten::inline_box_escape(boxes[index]);
        const auto head = box_expression_head(boxes[index]);
        box_payload += "{\"index\":" + std::to_string(index)
            + ",\"head\":" + (head.empty() ? "null" : json_escape(head))
            + ",\"box_expression\":" + json_escape(boxes[index])
            + ",\"inline_box_escape\":" + json_escape(escaped)
            + ",\"string_literal\":" + json_escape(tungsten::wl_string(escaped)) + "}";
    }
    box_payload.push_back(']');

    std::string segment_payload = "[";
    const auto segments = tungsten::split_inline_boxes(string_value);
    for (std::size_t index = 0; index < segments.size(); ++index) {
        if (index) segment_payload.push_back(',');
        const auto& segment = segments[index];
        if (segment.kind == tungsten::WolframStringSegment::Kind::Text) {
            segment_payload += "{\"kind\":\"text\",\"text\":"
                + json_escape(segment.text) + "}";
        } else {
            segment_payload += "{\"kind\":\"inline_box\",\"box_expression\":"
                + json_escape(segment.text) + ",\"inline_box_escape\":"
                + json_escape(segment.source) + "}";
        }
    }
    segment_payload.push_back(']');

    std::cout << "{\"success\":true,\"prefix\":" + json_escape(prefix)
        + ",\"suffix\":" + json_escape(suffix)
        + ",\"box_count\":" + std::to_string(boxes.size())
        + ",\"boxes\":" + box_payload
        + ",\"string_value\":" + json_escape(string_value)
        + ",\"string_literal\":"
        + json_escape(tungsten::compose_inline_box_string_literal(prefix, boxes, suffix))
        + ",\"string_segments\":" + segment_payload + "}" << '\n';
    return 0;
}

int execute_env_command(int argc, char** argv) {
    if (argc == 2) {
        std::cerr << "tungsten-cpp: env requires a subcommand\n";
        return 2;
    }
    if (argc == 3
        && (std::string(argv[2]) == "--help" || std::string(argv[2]) == "-h")) {
        std::cout
            << "Inspect the local Tungsten and Wolfram environment.\n\n"
            << "Usage: tungsten-cpp env show [--probe]\n";
        return 0;
    }
    if (std::string(argv[2]) != "show") {
        std::cerr << "tungsten-cpp: unknown env command: " << argv[2] << '\n';
        return 2;
    }
    bool probe = false;
    for (int index = 3; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--help" || argument == "-h") {
            std::cout << "Usage: tungsten-cpp env show [--probe]\n";
            return 0;
        }
        if (argument == "--probe") probe = true;
        else {
            std::cerr << "tungsten-cpp: unknown env show argument: " << argument << '\n';
            return 2;
        }
    }
    try {
        const auto installation = tungsten::discover_installation();
        auto payload = installation.to_json();
        if (probe)
            payload["probe"] = tungsten::WolframKernelRunner(installation).probe();
        std::cout << payload.dump_pretty(2) << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "tungsten-cpp: environment inspection failed: "
                  << error.what() << '\n';
        return 2;
    }
}

std::string evaluation_json(tungsten::Evaluator& evaluator, const std::string& source) {
    try {
        const auto value = evaluator.evaluate(tungsten::parse_input_form(source));
        std::vector<std::string> messages;
        for (const auto& message : evaluator.messages()) messages.push_back(message.to_full_form());
        return "{\"success\":true,\"full_form\":" + json_escape(value.to_full_form())
            + ",\"messages\":" + string_array(messages)
            + ",\"message_texts\":" + string_array(evaluator.message_texts())
            + ",\"prints\":" + string_array(evaluator.prints()) + "}";
    } catch (const std::exception& error) {
        return "{\"success\":false,\"error\":" + json_escape(error.what())
            + ",\"messages\":[],\"message_texts\":[],\"prints\":[]}";
    }
}

} // namespace

int tungsten_main(int argc, char** argv) {
    if (argc == 1)
        return tungsten::run_repl(std::cin, std::cout, std::cerr, true);
    if (argc == 2
        && (std::string(argv[1]) == "--help" || std::string(argv[1]) == "-h")) {
        print_help();
        return 0;
    }
    if (argc == 2 && std::string(argv[1]) == "--version") {
        std::cout << "tungsten-cpp 0.1.0\n";
        return 0;
    }
    if (argc >= 2 && std::string(argv[1]) == "repl") {
        bool show_banner = true;
        for (int index = 2; index < argc; ++index) {
            const std::string argument = argv[index];
            if (argument == "--no-banner") show_banner = false;
            else if (argument == "--help" || argument == "-h") {
                std::cout << "Usage: tungsten-cpp repl [--no-banner]\n";
                return 0;
            } else {
                std::cerr << "tungsten-cpp: unknown repl argument: " << argument << '\n';
                return 2;
            }
        }
        return tungsten::run_repl(std::cin, std::cout, std::cerr, show_banner);
    }
    if (argc >= 2 && std::string(argv[1]) == "expr")
        return execute_expr_command(argc, argv);
    if (argc >= 2 && std::string(argv[1]) == "kernel")
        return execute_kernel_command(argc, argv);
    if (argc >= 2 && std::string(argv[1]) == "notebook")
        return execute_notebook_command(argc, argv);
    if (argc >= 2 && std::string(argv[1]) == "parser-corpus")
        return execute_parser_corpus_command(argc, argv);
    if (argc >= 2 && std::string(argv[1]) == "docs")
        return execute_docs_command(argc, argv);
    if (argc >= 2 && std::string(argv[1]) == "frontend")
        return execute_frontend_command(argc, argv);
    if (argc >= 2 && std::string(argv[1]) == "assistant")
        return execute_assistant_command(argc, argv);
    if (argc >= 2 && std::string(argv[1]) == "inline-box")
        return execute_inline_box_command(argc, argv);
    if (argc >= 2 && std::string(argv[1]) == "env")
        return execute_env_command(argc, argv);
    if (argc >= 2 && std::string(argv[1]) == "parse") {
        std::string code;
        auto form = tungsten::ParseForm::Input;
        std::string form_label = "input";
        bool input_form = false;
        bool full_form = false;
        bool has_code = false;
        for (int index = 2; index < argc; ++index) {
            const std::string argument = argv[index];
            if (argument == "--help") { print_help(); return 0; }
            if (argument == "--code" && index + 1 < argc) {
                code = argv[++index];
                has_code = true;
            }
            else if (argument == "--form" && index + 1 < argc) {
                const std::string value = argv[++index];
                if (!parse_form_argument(value, form, form_label)) {
                    std::cerr << "tungsten-cpp: invalid parse form: " << value << '\n';
                    return 2;
                }
            } else if (argument == "--input-form") input_form = true;
            else if (argument == "--full-form") full_form = true;
            else { std::cerr << "tungsten-cpp: unknown parse argument: " << argument << '\n'; return 2; }
        }
        if (!has_code) {
            std::cerr << "tungsten-cpp: --code is required\n";
            return 2;
        }
        if (input_form && full_form) {
            std::cerr << "tungsten-cpp: --input-form conflicts with --full-form\n";
            return 2;
        }
        try {
            const auto expression = tungsten::parse_expression(code, form);
            std::cout << (input_form && !full_form
                ? expression.to_input_form() : expression.to_full_form()) << '\n';
            return 0;
        } catch (const std::exception& error) {
            std::cerr << error.what() << '\n';
            return 1;
        }
    }
    if (argc >= 2 && std::string(argv[1]) == "eval") {
        std::string code; bool input_form = false; bool has_code = false;
        for (int index = 2; index < argc; ++index) {
            const std::string argument = argv[index];
            if (argument == "--help") { print_help(); return 0; }
            if (argument == "--code" && index + 1 < argc) {
                code = argv[++index];
                has_code = true;
            }
            else if (argument == "--input-form") input_form = true;
            else { std::cerr << "tungsten-cpp: unknown eval argument: " << argument << '\n'; return 2; }
        }
        if (!has_code) {
            std::cerr << "tungsten-cpp: --code is required\n";
            return 2;
        }
        try {
            const auto value = tungsten::evaluate(tungsten::parse_input_form(code));
            std::cout << (input_form ? value.to_input_form() : value.to_full_form()) << '\n';
            return 0;
        } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
    }
    if (argc >= 2 && std::string(argv[1]) == "eval-batch") {
        bool stateful = false;
        for (int index = 2; index < argc; ++index) {
            if (std::string(argv[index]) == "--stateful") stateful = true;
            else { std::cerr << "tungsten-cpp: unknown eval-batch argument\n"; return 2; }
        }
        tungsten::Evaluator shared;
        std::string line;
        while (std::getline(std::cin, line)) {
            tungsten::Evaluator fresh;
            auto& evaluator = stateful ? shared : fresh;
            try { std::cout << evaluation_json(evaluator, decode_json_string(line)) << '\n'; }
            catch (const std::exception& error) {
                std::cout << "{\"success\":false,\"error\":" << json_escape(error.what())
                          << ",\"messages\":[],\"message_texts\":[],\"prints\":[]}" << '\n';
            }
        }
        return 0;
    }
    std::cerr << "tungsten-cpp: unknown command: " << argv[1] << '\n';
    return 2;
}

#if defined(_WIN32) && defined(_MSC_VER)
int wmain(int argc, wchar_t** argv) {
    try {
        std::vector<std::string> utf8_arguments;
        utf8_arguments.reserve(static_cast<std::size_t>(argc));
        for (int index = 0; index < argc; ++index)
            utf8_arguments.push_back(utf8_from_wide_argument(argv[index]));

        std::vector<char*> argument_pointers;
        argument_pointers.reserve(static_cast<std::size_t>(argc) + 1);
        for (auto& argument : utf8_arguments)
            argument_pointers.push_back(argument.data());
        argument_pointers.push_back(nullptr);
        return tungsten_main(argc, argument_pointers.data());
    } catch (const std::exception& error) {
        std::cerr << "tungsten-cpp: " << error.what() << '\n';
        return 2;
    }
}
#else
int main(int argc, char** argv) { return tungsten_main(argc, argv); }
#endif
