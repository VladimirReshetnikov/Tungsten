#pragma once

#include "tungsten/json.hpp"

#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace tungsten {

struct WolframInstallationSummary {
    std::string product;
    std::string product_family;
    std::optional<std::string> version;
    std::filesystem::path install_dir;
    std::optional<std::filesystem::path> kernel_cli;
    std::optional<std::filesystem::path> wolframscript;

    [[nodiscard]] JsonValue to_json() const;
};

struct WolframInstallation {
    std::optional<std::filesystem::path> install_dir;
    std::optional<std::filesystem::path> kernel_cli;
    std::optional<std::filesystem::path> kernel_executable;
    std::optional<std::filesystem::path> frontend_executable;
    std::optional<std::filesystem::path> wolframscript;
    std::optional<std::filesystem::path> mathpass;
    std::vector<std::filesystem::path> docs_roots;
    std::optional<std::filesystem::path> bundled_python_client;
    std::filesystem::path default_index_path;
    std::string product = "unknown";
    std::string product_family = "unknown";
    std::optional<std::string> version;
    std::optional<std::filesystem::path> user_base;
    std::optional<std::filesystem::path> system_base;
    std::vector<std::filesystem::path> mathpass_candidates;
    std::vector<WolframInstallationSummary> available_installations;
    std::optional<std::string> selection_reason;

    [[nodiscard]] JsonValue to_json() const;
};

struct DiscoveryEnvironment {
    std::filesystem::path program_files;
    std::optional<std::filesystem::path> appdata;
    std::filesystem::path program_data;
    std::optional<std::filesystem::path> local_app_data;
    std::optional<std::filesystem::path> home;
    std::optional<std::filesystem::path> explicit_home;
    std::optional<std::string> requested_product;

    [[nodiscard]] static DiscoveryEnvironment current();
};

[[nodiscard]] WolframInstallation discover_installation();
[[nodiscard]] WolframInstallation discover_installation(
    const DiscoveryEnvironment& environment);

[[nodiscard]] std::vector<std::filesystem::path> discover_docs_roots(
    const std::optional<std::filesystem::path>& install_dir = std::nullopt);
[[nodiscard]] std::vector<std::filesystem::path> discover_docs_roots(
    const std::optional<std::filesystem::path>& install_dir,
    const std::optional<std::string>& user_base_name,
    const DiscoveryEnvironment& environment);

void ensure_parent_directory(const std::filesystem::path& path);
[[nodiscard]] std::vector<std::filesystem::path> notebook_files(
    const std::vector<std::filesystem::path>& roots);

} // namespace tungsten
