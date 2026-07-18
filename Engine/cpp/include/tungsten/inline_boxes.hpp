#pragma once

#include "tungsten/json.hpp"

#include <cstdint>
#include <filesystem>
#include <string>
#include <variant>
#include <vector>

namespace tungsten {

struct InlineBoxFlatIndexSelector { std::size_t index; };
struct InlineBoxPathSelector { std::vector<std::size_t> path; };
struct InlineBoxExpressionUuidSelector { std::string value; };
struct InlineBoxCellIdSelector { std::int64_t value; };
struct InlineBoxCellTagSelector { std::string value; };

using InlineBoxCellSelector = std::variant<
    InlineBoxFlatIndexSelector,
    InlineBoxPathSelector,
    InlineBoxExpressionUuidSelector,
    InlineBoxCellIdSelector,
    InlineBoxCellTagSelector>;

struct InlineBoxExtractionOptions {
    std::string prefix;
    std::string suffix;
    long object_index = 0;
    bool all_objects = false;
};

[[nodiscard]] JsonValue compose_inline_box_payload(
    const std::vector<std::string>& box_expressions,
    const std::string& prefix = {},
    const std::string& suffix = {});

[[nodiscard]] JsonValue extract_inline_boxes_from_notebook_cell(
    const std::filesystem::path& notebook_path,
    const InlineBoxCellSelector& selector,
    const InlineBoxExtractionOptions& options = {});

} // namespace tungsten
