#include "tungsten/notebook.hpp"

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace {

int failures = 0;

void check(bool condition, const std::string& message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

template <typename Actual, typename Expected>
void check_equal(const Actual& actual, const Expected& expected, const std::string& message) {
    if (!(actual == expected)) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

template <typename Function>
void check_notebook_error(Function&& function, tungsten::NotebookErrorCode code,
    const std::string& message_fragment, const std::string& message) {
    try {
        std::forward<Function>(function)();
        check(false, message + " (no exception)");
    } catch (const tungsten::NotebookError& error) {
        check(error.code() == code, message + " (wrong error code)");
        check(std::string(error.what()).find(message_fragment) != std::string::npos,
            message + " (wrong error text)");
    } catch (const std::exception&) {
        check(false, message + " (wrong exception type)");
    }
}

const char* sample_notebook = R"NB((* sample header *)
Notebook[{
Cell["Welcome", "Title", CellID->1001, ExpressionUUID->"uuid-title", CellTags->{"intro", "top"}],
Cell[CellGroupData[{
Cell["Section A", "Section"],
Cell["Body text", "Text"]
}, Open]],
Cell["2+2", "Input"]
}, WindowTitle->"Sample Notebook"]
)NB";

} // namespace

int main() {
    using namespace tungsten;
    const auto unique = std::chrono::steady_clock::now().time_since_epoch().count();

    auto shared_source = std::make_shared<const std::string>(u8"\u2003  alpha β  \u3000");
    const SourceSpan untrimmed(shared_source, 0, shared_source->size());
    auto trimmed = untrimmed.strip();
    check_equal(trimmed.text(), std::string("alpha β"), "SourceSpan Unicode strip");
    check(trimmed.starts_with("alpha"), "SourceSpan starts_with");
    check(trimmed.ends_with("β"), "SourceSpan ends_with");
    check(static_cast<bool>(trimmed), "non-empty SourceSpan truth value");
    check(trimmed.shared_source().get() == shared_source.get(),
        "SourceSpan strip shares source storage");
    auto moved_span = std::move(trimmed);
    check_equal(moved_span.text(), std::string("alpha β"),
        "SourceSpan move destination retains its range");
    check_equal(trimmed.text(), std::string("alpha β"),
        "moved-from SourceSpan remains a valid value");
    SourceText lazy_text(trimmed);
    check(lazy_text.is_span(), "SourceText retains span storage");
    check(!lazy_text.is_materialized(), "SourceText starts lazy");
    check_equal(lazy_text.view(), std::string_view("alpha β"), "SourceText view");
    check(!lazy_text.is_materialized(), "SourceText view does not materialize");
    check_equal(lazy_text.text(), std::string("alpha β"), "SourceText text");
    check(lazy_text.is_materialized(), "SourceText text materializes on demand");
    SourceText move_source(trimmed);
    auto moved_text = std::move(move_source);
    check_equal(moved_text.text(), std::string("alpha β"),
        "SourceText move destination retains span text");
    check_equal(move_source.text(), std::string("alpha β"),
        "moved-from span-backed SourceText remains valid");
    check_equal(lazy_text.find("β"), std::string("alpha ").size(), "SourceText find");
    check_equal(lazy_text.substr(0, 5), std::string("alpha"), "SourceText substr");
    check_equal(collapse_text(u8"  α\u2003β\nγ  "), std::string("α β γ"),
        "collapse_text Unicode whitespace");
    check_equal(collapse_text("abcdef", 4), std::string(u8"abc…"),
        "collapse_text character limit");
    check_notebook_error(
        [&] { static_cast<void>(SourceSpan(shared_source, 4, shared_source->size() + 1)); },
        NotebookErrorCode::InvalidOperation, "out of bounds", "invalid SourceSpan range");

    const auto parsed = parse_call(
        R"WL(f[a, g[1, 2], {x, y}, "literal, comma", (* comment, *) h])WL");
    check_equal(parsed.first, std::string("f"), "parse_call head");
    check_equal(parsed.second,
        std::vector<std::string>{"a", "g[1, 2]", "{x, y}",
            R"WL("literal, comma")WL", "(* comment, *) h"},
        "parse_call arguments");
    check(parse_call("f[]").second.empty(), "empty call arguments");
    check_equal(parse_call("f[a,]").second, std::vector<std::string>{"a"},
        "trailing comma");
    check_equal(parse_call("f[,a]").second, std::vector<std::string>{"", "a"},
        "leading empty argument");
    check_equal(parse_call("f[a] trailing"),
        std::make_pair(std::string("f[a] trailing"), std::vector<std::string>{}),
        "trailing expression text");
    check_equal(parse_call(u8"\u2003f[a]\u3000"),
        std::make_pair(std::string("f"), std::vector<std::string>{"a"}),
        "Unicode whitespace around call");

    auto document = NotebookDocument::from_text(sample_notebook);
    const auto* parsed_title_cell = document.items[0].as_cell();
    const auto* parsed_group = document.items[1].as_group();
    check(parsed_title_cell != nullptr && parsed_group != nullptr,
        "parsed cell and group model");
    if (parsed_title_cell != nullptr && parsed_group != nullptr) {
        check(parsed_title_cell->content_expr.is_span(), "parsed cell content uses span");
        check(!parsed_title_cell->content_expr.is_materialized(),
            "parsed cell content remains lazy");
        check(parsed_title_cell->raw && parsed_title_cell->raw->is_span(),
            "parsed cell raw source uses span");
        check(!parsed_title_cell->options.empty() && parsed_title_cell->options[0].is_span(),
            "parsed cell options use spans");
        check(parsed_group->raw && parsed_group->raw->is_span(),
            "parsed group raw source uses span");
        check(!parsed_group->group_tail.empty() && parsed_group->group_tail[0].is_span(),
            "parsed group tail uses span");
        check(!document.options.empty() && document.options[0].is_span(),
            "parsed document options use spans");
        const auto* content_span = parsed_title_cell->content_expr.span();
        const auto* option_span = document.options[0].span();
        check(content_span != nullptr && option_span != nullptr
                && content_span->shared_source().get() == option_span->shared_source().get(),
            "parsed values share one notebook source buffer");
        check_equal(parsed_title_cell->content_expr.text(), std::string(R"WL("Welcome")WL"),
            "public cell content text");
        check_equal(parsed_title_cell->raw->str(), parsed_title_cell->render(),
            "raw cell render uses exact source slice");
    }
    const auto walked = document.walk_items();
    check(walked.size() == 5, "walk_items includes group rows");
    if (walked.size() == 5) {
        check_equal(walked[0].path, std::vector<std::size_t>{0},
            "walk_items first path");
        check(walked[1].item != nullptr
                && walked[1].item->kind() == NotebookItemKind::Group,
            "walk_items group preorder entry");
        check_equal(walked[2].path, std::vector<std::size_t>({1, 0}),
            "walk_items nested path");
        check(walked[2].depth == 1, "walk_items nested depth");
        check_equal(walked[4].path, std::vector<std::size_t>{2},
            "walk_items final path");
    }
    const auto& const_document = static_cast<const NotebookDocument&>(document);
    const auto const_walked = const_document.walk_items();
    check(const_walked.size() == walked.size() && const_walked[1].item != nullptr,
        "const walk_items traversal");
    if (auto* group = document.items[1].as_group()) {
        const auto subtree = document.walk_items(&group->children, {7}, 3);
        check(subtree.size() == 2 && subtree[0].path == std::vector<std::size_t>({7, 0})
                && subtree[0].depth == 3,
            "walk_items custom subtree, prefix, and depth");
    }
    check_equal(document.title(), std::optional<std::string>("Sample Notebook"), "title");
    check_equal(document.summary(),
        NotebookSummary{std::optional<std::string>("Sample Notebook"), 4, 1, 1},
        "summary counts");
    const auto rows = document.flattened_cells();
    check(rows.size() == 4, "flattened cell count");
    check(rows[0].kind == NotebookItemKind::Cell, "cell row kind");
    check_equal(rows[0].style, std::optional<std::string>("Title"), "cell style");
    check_equal(rows[0].cell_id, std::optional<std::int64_t>(1001), "CellID");
    check_equal(rows[0].expression_uuid, std::optional<std::string>("uuid-title"),
        "ExpressionUUID");
    check_equal(rows[0].cell_tags, std::vector<std::string>{"intro", "top"},
        "CellTags");
    check_equal(rows[1].path, std::vector<std::size_t>{1, 0}, "group child path");
    check_equal(document.cell_at_path({1, 1}).preview, std::string("Body text"),
        "cell path lookup");
    check(document.item_at_flat_index(0).as_cell() != nullptr, "flat item lookup");
    check(document.item_at_path({1}).as_group() != nullptr, "group item path lookup");
    check(document.to_json().find("\"cell_count\":4") != std::string::npos,
        "document JSON data");

    const auto unicode_notebook_path = std::filesystem::u8path(u8"notebooks/βeta.nb");
    const auto unicode_document = NotebookDocument::from_text(
        "Notebook[{}]", unicode_notebook_path);
    check_equal(unicode_document.title(), std::optional<std::string>(u8"βeta"),
        "notebook fallback title preserves a UTF-8 path stem");
    check_equal(unicode_document.to_json_value().at("path").as_string(),
        unicode_notebook_path.u8string(),
        "notebook JSON preserves a UTF-8 source path");

    NotebookRow maximum_row;
    maximum_row.index = std::numeric_limits<std::size_t>::max();
    maximum_row.path = {std::numeric_limits<std::size_t>::max()};
    maximum_row.depth = std::numeric_limits<std::size_t>::max();
    const auto maximum_json = maximum_row.to_json_value();
    const auto maximum = static_cast<std::uint64_t>(
        std::numeric_limits<std::size_t>::max());
    check(maximum_json.at("index").as_uint64() == maximum
            && maximum_json.at("path").at(0).as_uint64() == maximum
            && maximum_json.at("depth").as_uint64() == maximum,
        "notebook row JSON preserves unsigned size_t values");

    const auto raw_document = NotebookDocument::from_text(
        "Notebook[{marker[ 1 ], Cell[\"text\", \"Text\"]}]");
    const auto raw_rows = raw_document.flattened_cells();
    check(raw_rows.size() == 2 && raw_rows[0].kind == NotebookItemKind::Raw,
        "raw notebook items participate in flattened selectors");
    check_equal(raw_rows[0].preview, std::string("marker[ 1 ]"), "raw item preview");
    check_equal(raw_document.item_at_flat_index(0).render(), std::string("marker[ 1 ]"),
        "raw item flat lookup");

    check_notebook_error(
        [] { static_cast<void>(NotebookDocument::from_text("no notebook here")); },
        NotebookErrorCode::NotebookExpressionNotFound, "Notebook expression not found",
        "notebook expression missing error");
    check_notebook_error(
        [] { static_cast<void>(NotebookDocument::from_text("Notebook[{}] trailing")); },
        NotebookErrorCode::NotNotebook, "Top-level expression is not a Notebook",
        "not-notebook error");
    check_notebook_error(
        [] { static_cast<void>(parse_call("f[\"unterminated]")); },
        NotebookErrorCode::Syntax, "Unterminated Wolfram string", "syntax error taxonomy");
    check_notebook_error(
        [&] { static_cast<void>(document.cell_at_flat_index(99)); },
        NotebookErrorCode::InvalidOperation, "99 is out of range",
        "flat selector out-of-range error");
    check_notebook_error(
        [&] { static_cast<void>(document.cell_at_path({1, 9})); },
        NotebookErrorCode::InvalidOperation, "[1, 9] was not found",
        "cell path selector error");
    check_notebook_error(
        [&] { static_cast<void>(document.item_at_path({})); },
        NotebookErrorCode::InvalidOperation, "requires a non-empty path",
        "empty item path error");
    check_notebook_error(
        [&] { static_cast<void>(document.item_at_path({0, 0})); },
        NotebookErrorCode::InvalidOperation, "[0, 0] does not resolve through a group",
        "non-group item path error");
    check_notebook_error(
        [&] { static_cast<void>(document.insert_cell(99)); },
        NotebookErrorCode::InvalidOperation, "index 99 is out of range",
        "insert index error");
    check_notebook_error(
        [&] { static_cast<void>(document.replace_cell({1}, "not a group")); },
        NotebookErrorCode::InvalidOperation, "expects a cell or raw item",
        "replace group error");
    check_notebook_error(
        [&] { document.delete_item({99}); }, NotebookErrorCode::InvalidOperation,
        "[99] was not found", "delete path error");
    check_notebook_error(
        [&] { static_cast<void>(document.append_cell("x", "Text", std::nullopt, {0})); },
        NotebookErrorCode::InvalidOperation, "[0] does not identify a notebook group",
        "container selector error");
    NotebookDocument unsaved;
    check_notebook_error(
        [&] { static_cast<void>(unsaved.save()); }, NotebookErrorCode::InvalidOperation,
        "destination path is required", "save destination error");
    check_notebook_error(
        [&] { static_cast<void>(unsaved.save(std::filesystem::temp_directory_path())); },
        NotebookErrorCode::Io, "Could not open notebook for writing",
        "save I/O error taxonomy");
    const auto missing_notebook = std::filesystem::temp_directory_path()
        / ("tungsten-notebook-missing-" + std::to_string(unique) + ".nb");
    check_notebook_error(
        [&] { static_cast<void>(NotebookDocument::load(missing_notebook)); },
        NotebookErrorCode::Io, "Could not open notebook", "load I/O error taxonomy");
    check_notebook_error(
        [] { static_cast<void>(parse_json("{not-json")); }, NotebookErrorCode::Json,
        "expected", "JSON error taxonomy");

    const auto fallback_path = std::filesystem::temp_directory_path() / "FallbackTitle.nb";
    const auto fallback_title_document = NotebookDocument::from_text(
        "Notebook[{}]", fallback_path);
    check_equal(fallback_title_document.title(), std::optional<std::string>("FallbackTitle"),
        "path stem title fallback");
    check(NotebookDocument::from_text("Notebook[{}] (* trailing comment *)").items.empty(),
        "trailing Wolfram comments accepted");

    const auto original_title_cell = document.items[0].render();
    const auto original_group = document.items[1].render();
    const auto patch = parse_json(R"JSON({
      "operations": [
        {"op":"append_cell", "style":"Text", "text":"Tail cell"},
        {"op":"insert_cell", "index":0, "container_path":[1], "style":"Text", "text":"Lead nested"},
        {"op":"replace_cell", "path":[2], "style":"Input", "text":"Expand[2 (a+b)]"},
        {"op":"delete_item", "path":[1,1]},
        {"op":"append_cell", "container_path":[1], "style":"Text", "text":"Nested tail"},
        {"op":"set_option", "name":"WindowTitle", "value_expr":"\"Patched Notebook\""}
      ]
    })JSON");
    check_equal(parse_json(patch.dump()), patch, "JSON parse/dump round trip");
    apply_patch_spec(document, patch);
    check_equal(document.title(), std::optional<std::string>("Patched Notebook"),
        "patched title");
    check(document.summary().cell_count == 6, "patched cell count");
    check_equal(document.items[0].render(), original_title_cell,
        "unmodified raw cell remains source-preserved");
    check(document.items[1].render() != original_group, "edited group raw source invalidated");
    const auto patched_text = document.render();
    check(patched_text.find("Tail cell") != std::string::npos, "append patch rendered");
    check(patched_text.find("Lead nested") != std::string::npos, "insert patch rendered");
    check(patched_text.find("Expand[2 (a+b)]") != std::string::npos,
        "replace patch rendered");
    check(patched_text.find("Nested tail") != std::string::npos,
        "nested append rendered");

    const auto reparsed = NotebookDocument::from_text(patched_text);
    check(reparsed.summary() == document.summary(), "rendered notebook reparses");
    check(reparsed.render().find("(* sample header *)\nNotebook[") == 0,
        "preamble preserved");

    const auto irregular = NotebookDocument::from_text(
        "header\nNotebook[{\n  Cell[ \"x\" , \"Text\" ],\n  marker[ 1 ]\n}, WindowTitle -> \"Irregular\"]   \n");
    check_equal(irregular.items[0].render(), std::string("Cell[ \"x\" , \"Text\" ]"),
        "cell raw formatting preserved exactly");
    check_equal(irregular.items[1].render(), std::string("marker[ 1 ]"),
        "raw expression formatting preserved exactly");
    check(irregular.render().find("header\nNotebook[{\nCell[ \"x\" , \"Text\" ],\nmarker[ 1 ]\n}, WindowTitle -> \"Irregular\"]\n") == 0,
        "document render canonicalizes only outer separators");

    auto inheritance_document = NotebookDocument::from_text(
        "Notebook[{Cell[\"old\", \"Title\"], marker[]}]");
    const auto& inherited = inheritance_document.replace_cell({0}, "new");
    check_equal(inherited.style, std::optional<std::string>("Title"),
        "replace_cell inherits an existing cell style");
    const auto& replaced_raw = inheritance_document.replace_cell(
        {1}, std::nullopt, std::nullopt, std::string("2+2"));
    check(!replaced_raw.style && replaced_raw.content_expr == std::string_view("2+2"),
        "replace_cell accepts raw items and explicit content expressions");

    auto defaults_document = NotebookDocument::from_text("Notebook[{}]");
    apply_patch_spec(defaults_document, parse_json(R"JSON({"operations":[
      {"op":"append_cell", "style":17, "text":"ignored", "content_expr":"HoldForm[x]"},
      {"op":"insert_cell", "index":0, "text":"first"}
    ]})JSON"));
    const auto defaults_rows = defaults_document.flattened_cells();
    check(defaults_rows.size() == 2, "append and insert patch operations");
    const auto* defaults_first = defaults_document.item_at_path({0}).as_cell();
    const auto* defaults_second = defaults_document.item_at_path({1}).as_cell();
    check(defaults_first != nullptr && defaults_first->style == "Text",
        "insert patch default style");
    check(defaults_second != nullptr && defaults_second->style == "Text"
            && defaults_second->content_expr == std::string_view("HoldForm[x]"),
        "append patch content_expr precedence and default style");

    auto validation_document = NotebookDocument::from_text("Notebook[{}]");
    const auto validation_before = validation_document.render();
    apply_patch_spec(validation_document, parse_json("{}"));
    check_equal(validation_document.render(), validation_before,
        "missing operations defaults to an empty patch");
    check_notebook_error(
        [&] { apply_patch_spec(validation_document,
            parse_json(R"JSON({"operations":{}})JSON")); },
        NotebookErrorCode::InvalidOperation, "operations list", "non-array operations error");
    check_notebook_error(
        [&] { apply_patch_spec(validation_document,
            parse_json(R"JSON({"operations":[1]})JSON")); },
        NotebookErrorCode::InvalidOperation, "must be JSON objects",
        "non-object patch operation error");
    check_notebook_error(
        [&] { apply_patch_spec(validation_document,
            parse_json(R"JSON({"operations":[{"op":"delete_item","path":1}]})JSON")); },
        NotebookErrorCode::InvalidOperation, "arrays of integers",
        "non-array patch path error");
    check_notebook_error(
        [&] { apply_patch_spec(validation_document,
            parse_json(R"JSON({"operations":[{"op":"delete_item","path":[-1]}]})JSON")); },
        NotebookErrorCode::InvalidOperation, "non-negative integers",
        "negative patch path error");
    check_notebook_error(
        [&] { apply_patch_spec(validation_document,
            parse_json(R"JSON({"operations":[{"op":"insert_cell"}]})JSON")); },
        NotebookErrorCode::InvalidOperation, "insert_cell requires",
        "missing insert index error");
    check_notebook_error(
        [&] { apply_patch_spec(validation_document,
            parse_json(R"JSON({"operations":[{"op":"replace_cell"}]})JSON")); },
        NotebookErrorCode::InvalidOperation, "replace_cell requires a path",
        "missing replace path error");
    check_notebook_error(
        [&] { apply_patch_spec(validation_document,
            parse_json(R"JSON({"operations":[{"op":"set_option","value_expr":"1"}]})JSON")); },
        NotebookErrorCode::InvalidOperation, "set_option requires a name",
        "missing option name error");

    const auto inline_document = NotebookDocument::from_text(
        R"NB(Notebook[{Cell[BoxData[GraphicsBox[{CircleBox[]}]], "Output"], Cell["hello \!\(\*StyleBox[\"Hello\", FontWeight->Bold]\)", "Text"]}])NB");
    check_equal(inline_document.flattened_cells()[1].preview,
        std::string("hello [InlineBox]"), "inline box preview");
    const auto* graphic_cell = inline_document.item_at_flat_index(0).as_cell();
    const auto* styled_cell = inline_document.item_at_flat_index(1).as_cell();
    check(graphic_cell != nullptr && styled_cell != nullptr, "inline box cells parsed");
    if (graphic_cell != nullptr && styled_cell != nullptr) {
        check_equal(extract_box_expressions(graphic_cell->content_expr),
            std::vector<std::string>{"GraphicsBox[{CircleBox[]}]"},
            "BoxData extraction");
        check_equal(extract_box_expressions(styled_cell->content_expr),
            std::vector<std::string>{R"WL(StyleBox["Hello", FontWeight->Bold])WL"},
            "inline string box extraction");
    }

    const auto temporary = std::filesystem::temp_directory_path()
        / ("tungsten-notebook-cpp-" + std::to_string(unique) + ".nb");
    auto saved = document;
    check_equal(saved.save(temporary), temporary, "save destination");
    const auto loaded = NotebookDocument::load(temporary);
    check(loaded.summary() == document.summary(), "saved notebook loads");
    saved.append_cell("saved again");
    check_equal(saved.save(), temporary, "save reuses document path");
    check(NotebookDocument::load(temporary).summary().cell_count
            == document.summary().cell_count + 1,
        "save without destination writes updated document");
    std::error_code remove_error;
    std::filesystem::remove(temporary, remove_error);
    check(!remove_error, "temporary notebook removed");

    const auto lossy_path = std::filesystem::temp_directory_path()
        / ("tungsten-notebook-lossy-" + std::to_string(unique) + ".nb");
    {
        std::ofstream output(lossy_path, std::ios::binary | std::ios::trunc);
        output << "invalid ";
        output.put(static_cast<char>(0xff));
        output.put(' ');
        output.put(static_cast<char>(0xe2));
        output.put(static_cast<char>(0x82));
        output << "\nNotebook[{}]";
    }
    const auto lossy_document = NotebookDocument::load(lossy_path);
    check_equal(lossy_document.preamble, std::string(u8"invalid � �\n"),
        "load replaces malformed UTF-8");
    remove_error.clear();
    std::filesystem::remove(lossy_path, remove_error);
    check(!remove_error, "lossy UTF-8 test notebook removed");

    const auto patch_path = std::filesystem::temp_directory_path()
        / ("tungsten-notebook-patch-" + std::to_string(unique) + ".json");
    {
        std::ofstream output(patch_path, std::ios::binary | std::ios::trunc);
        output << R"JSON({"operations":[]})JSON";
    }
    check_equal(load_patch_spec(patch_path), parse_json(R"JSON({"operations":[]})JSON"),
        "load_patch_spec JSON file");
    {
        std::ofstream output(patch_path, std::ios::binary | std::ios::trunc);
        output << "{";
    }
    check_notebook_error(
        [&] { static_cast<void>(load_patch_spec(patch_path)); }, NotebookErrorCode::Json,
        "expected", "load_patch_spec JSON error taxonomy");
    {
        std::ofstream output(patch_path, std::ios::binary | std::ios::trunc);
        output << "{\"operations\":[],\"bad\":\"";
        output.put(static_cast<char>(0xff));
        output << "\"}";
    }
    check_notebook_error(
        [&] { static_cast<void>(load_patch_spec(patch_path)); }, NotebookErrorCode::Io,
        "not valid UTF-8", "load_patch_spec UTF-8 error taxonomy");
    remove_error.clear();
    std::filesystem::remove(patch_path, remove_error);
    check(!remove_error, "temporary patch file removed");

    check_notebook_error(
        [&] { apply_patch_spec(document,
            parse_json(R"JSON({"operations":[{"op":"unknown"}]})JSON")); },
        NotebookErrorCode::InvalidOperation, "Unsupported patch operation",
        "unknown patch operation rejected");

    if (failures != 0) {
        std::cerr << failures << " notebook test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all C++ notebook tests passed\n";
    return EXIT_SUCCESS;
}
