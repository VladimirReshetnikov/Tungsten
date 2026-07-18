#pragma once

#include "tungsten/json.hpp"

#include <cstddef>
#include <filesystem>
#include <optional>
#include <string>

namespace tungsten {

struct MathpassInspection {
    std::optional<std::string> path;
    bool header_present = false;
    std::size_t original_line_count = 0;
    std::size_t unique_entry_count = 0;
    std::size_t duplicate_entry_count = 0;

    [[nodiscard]] JsonValue to_json() const;

    friend bool operator==(
        const MathpassInspection& left,
        const MathpassInspection& right) noexcept {
        return left.path == right.path
            && left.header_present == right.header_present
            && left.original_line_count == right.original_line_count
            && left.unique_entry_count == right.unique_entry_count
            && left.duplicate_entry_count == right.duplicate_entry_count;
    }
};

[[nodiscard]] MathpassInspection inspect_mathpass(
    const std::optional<std::filesystem::path>& path);
[[nodiscard]] MathpassInspection write_deduped_mathpass(
    const std::filesystem::path& source,
    const std::filesystem::path& destination);

class DedupedMathpass {
public:
    static DedupedMathpass create(
        const std::optional<std::filesystem::path>& source);

    DedupedMathpass(const DedupedMathpass&) = delete;
    DedupedMathpass& operator=(const DedupedMathpass&) = delete;
    DedupedMathpass(DedupedMathpass&& other) noexcept;
    DedupedMathpass& operator=(DedupedMathpass&& other) noexcept;
    ~DedupedMathpass();

    [[nodiscard]] const std::optional<std::filesystem::path>& path() const noexcept;
    [[nodiscard]] const MathpassInspection& inspection() const noexcept;

private:
    DedupedMathpass(
        std::optional<std::filesystem::path> path,
        MathpassInspection inspection,
        std::optional<std::filesystem::path> temporary_directory);
    void cleanup() noexcept;

    std::optional<std::filesystem::path> path_;
    MathpassInspection inspection_;
    std::optional<std::filesystem::path> temporary_directory_;
};

} // namespace tungsten
