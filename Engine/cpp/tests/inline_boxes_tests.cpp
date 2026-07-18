#include "tungsten/inline_boxes.hpp"

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

namespace {

int failures = 0;

void check(bool condition, const std::string& message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

const char* sample_notebook = R"NB(Notebook[{
Cell[BoxData[GraphicsBox[{CircleBox[]}]], "Output", ExpressionUUID->"uuid-graphic"],
Cell["prefix \!\(\*StyleBox[\"Hello\", FontWeight->Bold]\) suffix", "Text", CellID->2001]
}])NB";

} // namespace

int main() {
    using namespace tungsten;

    const auto composed = compose_inline_box_payload(
        {"GraphicsBox[{CircleBox[]}]"}, "icon: ", ".");
    check(composed.at("success").as_boolean(), "composition succeeds");
    check(composed.at("box_count").as_uint64() == 1, "composition box count");
    check(composed.at("boxes").at(0).at("head").as_string() == "GraphicsBox",
        "composition box head");
    check(composed.at("string_value").as_string()
            == R"(icon: \!\(\*GraphicsBox[{CircleBox[]}]\).)",
        "composition string value");
    check(composed.at("string_literal").as_string()
            == R"("icon: \\!\\(\\*GraphicsBox[{CircleBox[]}]\\).")",
        "composition string literal");
    check(composed.at("string_segments").size() == 3,
        "composition segment projection");

    const auto stamp = std::chrono::high_resolution_clock::now()
        .time_since_epoch().count();
    const auto path = std::filesystem::temp_directory_path()
        / ("tungsten-inline-box-cpp-" + std::to_string(stamp) + ".nb");
    {
        std::ofstream stream(path, std::ios::binary);
        stream << sample_notebook;
    }

    const auto by_uuid = extract_inline_boxes_from_notebook_cell(
        path,
        InlineBoxExpressionUuidSelector{"uuid-graphic"},
        InlineBoxExtractionOptions{"icon: ", "", 0, false});
    check(by_uuid.at("success").as_boolean(), "UUID extraction succeeds");
    check(by_uuid.at("available_box_count").as_uint64() == 1,
        "UUID extraction available count");
    check(by_uuid.at("selected_boxes").at(0).at("head").as_string() == "GraphicsBox",
        "UUID extraction selected head");

    InlineBoxExtractionOptions all;
    all.prefix = "rendered: ";
    all.all_objects = true;
    const auto by_id = extract_inline_boxes_from_notebook_cell(
        path, InlineBoxCellIdSelector{2001}, all);
    check(by_id.at("success").as_boolean(), "CellID extraction succeeds");
    check(by_id.at("object_index").is_null(), "all-object index is null");
    check(by_id.at("selected_boxes").at(0).at("head").as_string() == "StyleBox",
        "CellID extraction selected head");

    InlineBoxExtractionOptions invalid;
    invalid.object_index = -1;
    const auto out_of_range = extract_inline_boxes_from_notebook_cell(
        path, InlineBoxFlatIndexSelector{0}, invalid);
    check(!out_of_range.at("success").as_boolean(), "negative object index rejected");
    check(out_of_range.at("error_type").as_string()
            == "InlineBoxObjectIndexOutOfRange",
        "object index error type");

    std::error_code error;
    std::filesystem::remove(path, error);
    check(!error, "temporary notebook cleanup");

    if (failures != 0) {
        std::cerr << failures << " inline-box test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all C++ inline-box tests passed\n";
    return EXIT_SUCCESS;
}
