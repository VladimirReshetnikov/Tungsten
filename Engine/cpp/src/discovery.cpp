#include "tungsten/discovery.hpp"
#include "tungsten/detail/ascii.hpp"

#include <algorithm>
#include <cstdlib>
#include <gmpxx.h>
#include <limits>
#include <set>
#include <system_error>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace tungsten {
namespace {

namespace fs = std::filesystem;

struct ProductLayout {
    const char* product;
    const char* family;
    const char* program_files_name;
    const char* user_base_name;
    const char* index_prefix;
    std::size_t default_priority;
};

constexpr ProductLayout wolfram_layout{
    "Wolfram", "wolfram", "Wolfram", "Wolfram", "wolfram", 0};
constexpr ProductLayout engine_layout{
    "Wolfram Engine", "engine", "Wolfram Engine", "WolframEngine",
    "wolfram-engine", 1};
constexpr ProductLayout product_layouts[]{wolfram_layout, engine_layout};

std::string path_text(const fs::path& path) { return path.u8string(); }

JsonValue optional_path_json(const std::optional<fs::path>& path) {
    return path ? JsonValue(path_text(*path)) : JsonValue();
}

JsonValue optional_string_json(const std::optional<std::string>& value) {
    return value ? JsonValue(*value) : JsonValue();
}

JsonValue path_array_json(const std::vector<fs::path>& paths) {
    JsonValue::Array values;
    values.reserve(paths.size());
    for (const auto& path : paths) values.emplace_back(path_text(path));
    return JsonValue(std::move(values));
}

#ifdef _WIN32
std::optional<std::wstring> environment_wide(const char* name) {
    const std::wstring wide_name(name, name + std::char_traits<char>::length(name));
    for (int attempt = 0; attempt < 3; ++attempt) {
        SetLastError(ERROR_SUCCESS);
        const auto required = GetEnvironmentVariableW(wide_name.c_str(), nullptr, 0);
        if (required == 0) {
            return GetLastError() == ERROR_SUCCESS
                ? std::optional<std::wstring>(std::wstring{}) : std::nullopt;
        }
        std::wstring value(static_cast<std::size_t>(required), L'\0');
        const auto written = GetEnvironmentVariableW(
            wide_name.c_str(), value.data(), required);
        if (written < required) {
            value.resize(static_cast<std::size_t>(written));
            return value;
        }
    }
    return std::nullopt;
}

std::optional<std::string> wide_to_utf8(const std::wstring& value) {
    if (value.empty()) return std::string{};
    if (value.size() > static_cast<std::size_t>(std::numeric_limits<int>::max()))
        return std::nullopt;
    const auto source_size = static_cast<int>(value.size());
    const auto required = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), source_size,
        nullptr, 0, nullptr, nullptr);
    if (required <= 0) return std::nullopt;
    std::string result(static_cast<std::size_t>(required), '\0');
    if (WideCharToMultiByte(
            CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), source_size,
            result.data(), required, nullptr, nullptr)
        != required) {
        return std::nullopt;
    }
    return result;
}
#endif

std::optional<fs::path> environment_path(const char* name) {
#ifdef _WIN32
    const auto value = environment_wide(name);
    if (!value || value->empty()) return std::nullopt;
    return fs::path(*value);
#else
    const auto* value = std::getenv(name);
    if (value == nullptr || *value == '\0') return std::nullopt;
    return fs::path(value);
#endif
}

std::optional<std::string> environment_string(const char* name) {
#ifdef _WIN32
    const auto value = environment_wide(name);
    return value ? wide_to_utf8(*value) : std::nullopt;
#else
    const auto* value = std::getenv(name);
    if (value == nullptr) return std::nullopt;
    return std::string(value);
#endif
}

std::string lowercase(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return detail::ascii_lower(character);
    });
    return value;
}

std::string trim(std::string value) {
    const auto first = std::find_if_not(value.begin(), value.end(), [](unsigned char character) {
        return detail::ascii_is_space(character);
    });
    const auto last = std::find_if_not(value.rbegin(), value.rend(), [](unsigned char character) {
        return detail::ascii_is_space(character);
    }).base();
    if (first >= last) return {};
    return std::string(first, last);
}

std::vector<mpz_class> parse_version(std::string_view value) {
    std::vector<mpz_class> parts;
    std::size_t start = 0;
    while (start <= value.size()) {
        const auto separator = value.find('.', start);
        const auto fragment = trim(std::string(value.substr(
            start, separator == std::string_view::npos ? value.size() - start
                                                       : separator - start)));
        if (!fragment.empty()) {
            mpz_class part;
            if (mpz_set_str(part.get_mpz_t(), fragment.c_str(), 10) != 0) break;
            parts.push_back(std::move(part));
        }
        if (separator == std::string_view::npos) break;
        start = separator + 1;
    }
    return parts;
}

std::vector<fs::path> read_entries(const fs::path& path) {
    std::vector<fs::path> output;
    std::error_code error;
    for (fs::directory_iterator iterator(path, error), end; !error && iterator != end;
         iterator.increment(error)) {
        output.push_back(iterator->path());
    }
    return output;
}

std::vector<fs::path> read_directories(const fs::path& path) {
    auto entries = read_entries(path);
    entries.erase(std::remove_if(entries.begin(), entries.end(), [](const fs::path& entry) {
        std::error_code error;
        return !fs::is_directory(entry, error);
    }), entries.end());
    return entries;
}

bool path_exists(const fs::path& path) {
    std::error_code error;
    return fs::exists(path, error);
}

bool path_is_directory(const fs::path& path) {
    std::error_code error;
    return fs::is_directory(path, error);
}

bool path_is_file(const fs::path& path) {
    std::error_code error;
    return fs::is_regular_file(path, error);
}

const ProductLayout& infer_layout(const fs::path& path) {
    const auto normalized = lowercase(path_text(path));
    if (normalized.find("wolfram engine") != std::string::npos
        || normalized.find("wolframengine") != std::string::npos)
        return engine_layout;
    return wolfram_layout;
}

const ProductLayout& layout_for_family(std::string_view family) {
    return family == "wolfram" ? wolfram_layout : engine_layout;
}

std::optional<std::string> requested_product_family(
    const std::optional<std::string>& value) {
    if (!value) return std::nullopt;
    const auto normalized = lowercase(trim(*value));
    if (normalized.empty()) return std::nullopt;
    if (normalized == "wolfram" || normalized == "desktop" || normalized == "paid"
        || normalized == "mathematica") return std::string("wolfram");
    if (normalized == "engine" || normalized == "wolframengine"
        || normalized == "wolfram-engine" || normalized == "wefd")
        return std::string("engine");
    return normalized;
}

fs::path research_root(const DiscoveryEnvironment& environment) {
    return environment.program_files / "Wolfram Research";
}

std::optional<fs::path> first_existing_file(
    std::initializer_list<fs::path> candidates) {
    for (const auto& candidate : candidates) {
        if (path_is_file(candidate)) return candidate;
    }
    return std::nullopt;
}

struct InstallationExecutables {
    std::optional<fs::path> kernel_cli;
    std::optional<fs::path> kernel_executable;
    std::optional<fs::path> frontend_executable;
    std::optional<fs::path> wolframscript;
};

InstallationExecutables installation_executables(const fs::path& install_dir) {
    const auto macos = install_dir / "Contents" / "MacOS";
    const auto executables = install_dir / "Executables";
    auto kernel_executable = first_existing_file({
        install_dir / "WolframKernel.exe",
        macos / "WolframKernel",
        macos / "MathKernel",
        executables / "WolframKernel",
        install_dir / "WolframKernel",
        executables / "MathKernel",
        install_dir / "MathKernel",
    });
    auto kernel_cli = first_existing_file({
        install_dir / "wolfram.exe",
        macos / "wolfram",
        executables / "wolfram",
        install_dir / "wolfram",
    });
    if (!kernel_cli) kernel_cli = kernel_executable;
    return {
        std::move(kernel_cli),
        std::move(kernel_executable),
        first_existing_file({
            install_dir / "WolframNB.exe",
            macos / "Mathematica",
            macos / "WolframDesktop",
            macos / "Wolfram",
            executables / "Mathematica",
        }),
        first_existing_file({
            install_dir / "wolframscript.exe",
            macos / "wolframscript",
            executables / "wolframscript",
            install_dir / "wolframscript",
        }),
    };
}

fs::path normalize_install_dir(const fs::path& candidate) {
    if (path_is_file(candidate)) {
        auto parent = candidate.parent_path();
        for (auto ancestor = parent; !ancestor.empty(); ancestor = ancestor.parent_path()) {
            if (lowercase(path_text(ancestor.filename())) == "systemfiles")
                return ancestor.parent_path();
            if (lowercase(path_text(ancestor.filename())) == "executables")
                return ancestor.parent_path();
            if (lowercase(path_text(ancestor.extension())) == ".app") return ancestor;
            if (ancestor == ancestor.parent_path()) break;
        }
        return parent;
    }
    if (path_exists(candidate) && !parse_version(path_text(candidate.filename())).empty())
        return candidate;
    if (path_is_directory(candidate)) {
        auto versions = read_directories(candidate);
        versions.erase(std::remove_if(versions.begin(), versions.end(), [](const fs::path& path) {
            return parse_version(path_text(path.filename())).empty();
        }), versions.end());
        std::sort(versions.begin(), versions.end(), [](const fs::path& left, const fs::path& right) {
            return parse_version(path_text(left.filename()))
                > parse_version(path_text(right.filename()));
        });
        if (!versions.empty()) return versions.front();
    }
    return candidate;
}

WolframInstallationSummary summarize_install_dir(fs::path install_dir) {
    const auto& layout = infer_layout(install_dir);
    auto executables = installation_executables(install_dir);
    const auto name = path_text(install_dir.filename());
    return {
        layout.product,
        layout.family,
        parse_version(name).empty() ? std::nullopt
                                    : std::optional<std::string>(name),
        std::move(install_dir),
        std::move(executables.kernel_cli),
        std::move(executables.wolframscript),
    };
}

void append_versioned_installations(
    const fs::path& root, std::vector<fs::path>& candidates) {
    for (const auto& child : read_directories(root)) {
        if (!parse_version(path_text(child.filename())).empty())
            candidates.push_back(child);
    }
}

std::vector<fs::path> installation_candidates(const DiscoveryEnvironment& environment) {
    if (environment.explicit_home)
        return {normalize_install_dir(*environment.explicit_home)};
    std::vector<fs::path> candidates;
    for (const auto& layout : product_layouts) {
        append_versioned_installations(
            research_root(environment) / layout.program_files_name, candidates);
    }
#ifndef _WIN32
    std::vector<fs::path> prefixes{environment.program_files};
    for (const auto& prefix : {fs::path("/usr/local"), fs::path("/opt")}) {
        if (std::find(prefixes.begin(), prefixes.end(), prefix) == prefixes.end())
            prefixes.push_back(prefix);
    }
    for (const auto& prefix : prefixes) {
        append_versioned_installations(
            prefix / "Wolfram" / "Mathematica", candidates);
        append_versioned_installations(
            prefix / "Wolfram" / "WolframEngine", candidates);
        append_versioned_installations(
            prefix / "Wolfram" / "Wolfram", candidates);
    }
#ifdef __APPLE__
    for (const auto& child : read_directories(environment.program_files)) {
        const auto name = lowercase(path_text(child.filename()));
        if (lowercase(path_text(child.extension())) == ".app"
            && (name.find("mathematica") != std::string::npos
                || name.find("wolfram") != std::string::npos)) {
            candidates.push_back(child);
        }
    }
#endif
#endif
    return candidates;
}

std::vector<WolframInstallationSummary> discover_available_installations(
    const DiscoveryEnvironment& environment) {
    std::vector<WolframInstallationSummary> discovered;
    std::set<fs::path> seen;
    for (const auto& candidate : installation_candidates(environment)) {
        const auto install_dir = normalize_install_dir(candidate);
        if (!path_is_directory(install_dir)) continue;
        std::error_code error;
        const auto resolved = fs::canonical(install_dir, error);
        if (error || !seen.insert(resolved).second) continue;
        auto summary = summarize_install_dir(resolved);
        if (summary.kernel_cli || summary.wolframscript)
            discovered.push_back(std::move(summary));
    }
    std::sort(discovered.begin(), discovered.end(), [](const auto& left, const auto& right) {
        const auto& left_layout = layout_for_family(left.product_family);
        const auto& right_layout = layout_for_family(right.product_family);
        if (left_layout.default_priority != right_layout.default_priority)
            return left_layout.default_priority < right_layout.default_priority;
        const auto left_version = parse_version(left.version.value_or(""));
        const auto right_version = parse_version(right.version.value_or(""));
        if (left_version != right_version) return left_version > right_version;
        return lowercase(path_text(left.install_dir)) < lowercase(path_text(right.install_dir));
    });
    return discovered;
}

std::optional<fs::path> discover_installation_root(
    const DiscoveryEnvironment& environment,
    const std::vector<WolframInstallationSummary>& available) {
    if (available.empty()) {
        if (environment.explicit_home) return normalize_install_dir(*environment.explicit_home);
        return std::nullopt;
    }
    if (environment.explicit_home) return available.front().install_dir;
    if (const auto requested = requested_product_family(environment.requested_product)) {
        const auto found = std::find_if(available.begin(), available.end(), [&](const auto& item) {
            return item.product_family == *requested;
        });
        if (found != available.end()) return found->install_dir;
    }
    return available.front().install_dir;
}

std::vector<fs::path> discover_mathpass_candidates(
    std::string_view product_family,
    const DiscoveryEnvironment& environment) {
    std::vector<fs::path> candidates;
#ifndef _WIN32
    if (environment.home) {
        candidates.push_back(*environment.home
            / (product_family == "engine" ? ".WolframEngine" : ".Wolfram")
            / "Licensing" / "mathpass");
    }
#endif
    if (product_family == "engine") {
        if (environment.appdata)
            candidates.push_back(*environment.appdata / "WolframEngine" / "Licensing" / "mathpass");
        candidates.push_back(environment.program_data / "WolframEngine" / "Licensing" / "mathpass");
    } else {
        candidates.push_back(environment.program_data / "Wolfram" / "Licensing" / "mathpass");
        if (environment.appdata)
            candidates.push_back(*environment.appdata / "Wolfram" / "Licensing" / "mathpass");
    }
    return candidates;
}

std::vector<mpz_class> trailing_version(const fs::path& path) {
    const auto name = path_text(path.filename());
    const auto separator = name.rfind('-');
    if (separator == std::string::npos) return {};
    const auto version = name.substr(separator + 1);
    if (!std::all_of(version.begin(), version.end(), [](unsigned char character) {
            return detail::ascii_is_digit(character) || character == '.';
        })) return {};
    return parse_version(version);
}

void collect_notebooks(const fs::path& path, std::vector<fs::path>& output,
    std::set<fs::path>& visited_directories) {
    std::error_code error;
    const auto status = fs::symlink_status(path, error);
    if (error || fs::is_symlink(status)) return;
    if (fs::is_regular_file(status)) {
        if (lowercase(path_text(path.extension())) == ".nb") output.push_back(path);
        return;
    }
    if (!fs::is_directory(status)) return;
    const auto resolved = fs::canonical(path, error);
    if (error || !visited_directories.insert(resolved).second) return;
    for (const auto& child : read_entries(path))
        collect_notebooks(child, output, visited_directories);
}

} // namespace

JsonValue WolframInstallationSummary::to_json() const {
    return JsonValue::object({
        {"product", product},
        {"product_family", product_family},
        {"version", optional_string_json(version)},
        {"install_dir", path_text(install_dir)},
        {"kernel_cli", optional_path_json(kernel_cli)},
        {"wolframscript", optional_path_json(wolframscript)},
    });
}

JsonValue WolframInstallation::to_json() const {
    JsonValue::Array installations;
    installations.reserve(available_installations.size());
    for (const auto& item : available_installations) installations.push_back(item.to_json());
    return JsonValue::object({
        {"install_dir", optional_path_json(install_dir)},
        {"kernel_cli", optional_path_json(kernel_cli)},
        {"kernel_executable", optional_path_json(kernel_executable)},
        {"frontend_executable", optional_path_json(frontend_executable)},
        {"wolframscript", optional_path_json(wolframscript)},
        {"mathpass", optional_path_json(mathpass)},
        {"docs_roots", path_array_json(docs_roots)},
        {"bundled_python_client", optional_path_json(bundled_python_client)},
        {"default_index_path", path_text(default_index_path)},
        {"product", product},
        {"product_family", product_family},
        {"version", optional_string_json(version)},
        {"user_base", optional_path_json(user_base)},
        {"system_base", optional_path_json(system_base)},
        {"mathpass_candidates", path_array_json(mathpass_candidates)},
        {"available_installations", JsonValue(std::move(installations))},
        {"selection_reason", optional_string_json(selection_reason)},
    });
}

DiscoveryEnvironment DiscoveryEnvironment::current() {
    auto home = environment_path("HOME");
    if (!home) home = environment_path("USERPROFILE");
#ifdef _WIN32
    return {
        environment_path("ProgramFiles").value_or(fs::path(R"(C:\Program Files)")),
        environment_path("APPDATA"),
        environment_path("ProgramData").value_or(fs::path(R"(C:\ProgramData)")),
        environment_path("LOCALAPPDATA"),
        std::move(home),
        environment_path("TUNGSTEN_WOLFRAM_HOME"),
        environment_string("TUNGSTEN_WOLFRAM_PRODUCT"),
    };
#elif defined(__APPLE__)
    const auto application_support = home
        ? std::optional<fs::path>(*home / "Library" / "Application Support")
        : std::nullopt;
    const auto caches = home
        ? std::optional<fs::path>(*home / "Library" / "Caches")
        : std::nullopt;
    return {
        fs::path("/Applications"),
        application_support,
        fs::path("/Library/Application Support"),
        caches,
        std::move(home),
        environment_path("TUNGSTEN_WOLFRAM_HOME"),
        environment_string("TUNGSTEN_WOLFRAM_PRODUCT"),
    };
#else
    auto data_home = environment_path("XDG_DATA_HOME");
    if (!data_home && home) data_home = *home / ".local" / "share";
    auto cache_home = environment_path("XDG_CACHE_HOME");
    if (!cache_home && home) cache_home = *home / ".cache";
    return {
        fs::path("/usr/local"),
        std::move(data_home),
        fs::path("/usr/share"),
        std::move(cache_home),
        std::move(home),
        environment_path("TUNGSTEN_WOLFRAM_HOME"),
        environment_string("TUNGSTEN_WOLFRAM_PRODUCT"),
    };
#endif
}

WolframInstallation discover_installation() {
    return discover_installation(DiscoveryEnvironment::current());
}

WolframInstallation discover_installation(const DiscoveryEnvironment& environment) {
    auto available = discover_available_installations(environment);
    const auto requested = requested_product_family(environment.requested_product);
    std::optional<WolframInstallationSummary> selected;
    std::optional<std::string> selection_reason;
    if (environment.explicit_home && !available.empty()) {
        selected = available.front();
        selection_reason = "TUNGSTEN_WOLFRAM_HOME";
    } else if (requested) {
        const auto found = std::find_if(available.begin(), available.end(), [&](const auto& item) {
            return item.product_family == *requested;
        });
        if (found != available.end()) {
            selected = *found;
            selection_reason = "TUNGSTEN_WOLFRAM_PRODUCT=" + *requested;
        }
    }
    if (!selected && !available.empty()) {
        selected = available.front();
        selection_reason = "default-product-preference";
    }

    auto install_dir = selected ? std::optional<fs::path>(selected->install_dir)
                                : discover_installation_root(environment, available);
    const auto& layout = install_dir ? infer_layout(*install_dir) : wolfram_layout;
    const auto product = selected ? selected->product : std::string(layout.product);
    const auto product_family = selected ? selected->product_family : std::string(layout.family);
    auto version = selected ? selected->version : std::optional<std::string>{};
    if (!version && install_dir) {
        const auto name = path_text(install_dir->filename());
        if (!parse_version(name).empty()) version = name;
    }

    const auto executables = install_dir
        ? installation_executables(*install_dir) : InstallationExecutables{};
    std::optional<fs::path> bundled_python_client;
    if (install_dir) {
        for (const auto& candidate : {
                 *install_dir / "SystemFiles" / "Components"
                     / "WolframClientForPython",
                 *install_dir / "Contents" / "SystemFiles" / "Components"
                     / "WolframClientForPython"}) {
            if (path_exists(candidate)) {
                bundled_python_client = candidate;
                break;
            }
        }
    }
    const auto user_base = environment.appdata
        ? std::optional<fs::path>(*environment.appdata / layout.user_base_name)
        : std::nullopt;
    const auto system_base = std::optional<fs::path>(
        environment.program_data / layout.user_base_name);
    const auto docs_roots = discover_docs_roots(
        install_dir, std::string(layout.user_base_name), environment);
    auto mathpass_candidates = discover_mathpass_candidates(product_family, environment);
    std::optional<fs::path> mathpass;
    const auto license = std::find_if(mathpass_candidates.begin(), mathpass_candidates.end(),
        [](const fs::path& path) { return path_exists(path); });
    if (license != mathpass_candidates.end()) mathpass = *license;

    auto local_app_data = environment.local_app_data;
    if (!local_app_data) {
#ifdef _WIN32
        local_app_data = environment.home.value_or(fs::path(".")) / "AppData" / "Local";
#elif defined(__APPLE__)
        local_app_data = environment.home.value_or(fs::path("."))
            / "Library" / "Caches";
#else
        local_app_data = environment.home.value_or(fs::path(".")) / ".cache";
#endif
    }
    const auto index_version = version.value_or(
        install_dir ? path_text(install_dir->filename()) : std::string("unknown"));
    const auto default_index_path = *local_app_data / "Tungsten" / "docs"
        / (std::string(layout.index_prefix) + "-" + index_version + ".sqlite3");

    if (install_dir && !path_exists(*install_dir)) install_dir.reset();
    return {
        install_dir,
        executables.kernel_cli,
        executables.kernel_executable,
        executables.frontend_executable,
        executables.wolframscript,
        mathpass,
        docs_roots,
        bundled_python_client,
        default_index_path,
        product,
        product_family,
        version,
        user_base,
        system_base,
        std::move(mathpass_candidates),
        std::move(available),
        selection_reason,
    };
}

std::vector<fs::path> discover_docs_roots(
    const std::optional<fs::path>& install_dir) {
    return discover_docs_roots(install_dir, std::nullopt, DiscoveryEnvironment::current());
}

std::vector<fs::path> discover_docs_roots(
    const std::optional<fs::path>& install_dir,
    const std::optional<std::string>& user_base_name,
    const DiscoveryEnvironment& environment) {
    const auto& layout = install_dir ? infer_layout(*install_dir) : wolfram_layout;
    const auto install_version = install_dir
        ? parse_version(path_text(install_dir->filename())) : std::vector<mpz_class>{};
    std::vector<std::string> base_names{
        user_base_name.value_or(layout.user_base_name)};
    if (std::string(layout.user_base_name) != "Wolfram") base_names.push_back("Wolfram");

    std::vector<fs::path> roots;
    if (environment.appdata) {
        for (const auto& base_name : base_names) {
            auto updates = read_directories(
                *environment.appdata / base_name / "Paclets" / "Repository");
            updates.erase(std::remove_if(updates.begin(), updates.end(), [](const fs::path& path) {
                return path_text(path.filename()).rfind("SystemDocsUpdate", 0) != 0;
            }), updates.end());
            std::sort(updates.begin(), updates.end(), [](const fs::path& left, const fs::path& right) {
                return path_text(left) > path_text(right);
            });
            for (const auto& update : updates) {
                if (!install_version.empty()) {
                    const auto update_version = trailing_version(update);
                    if (update_version.size() < install_version.size()
                        || !std::equal(install_version.begin(), install_version.end(),
                            update_version.begin())) continue;
                }
                const auto candidate = update / "Documentation" / "English";
                if (path_exists(candidate)) roots.push_back(candidate);
            }
        }
    }
    if (install_dir) {
        const auto common = research_root(environment).parent_path() / "Common Files"
            / "Wolfram Research" / "Documentation.en-us" / install_dir->filename()
            / "Documentation" / "English" / "System";
        if (path_exists(common)) roots.push_back(common);
        for (const auto& candidate : {
                 *install_dir / "Documentation" / "English",
                 *install_dir / "SystemFiles" / "Documentation" / "English",
                 *install_dir / "Contents" / "Documentation" / "English",
                 *install_dir / "Contents" / "Resources" / "Documentation"
                     / "English"}) {
            if (path_exists(candidate)) roots.push_back(candidate);
        }
    }

    std::set<fs::path> seen;
    std::vector<fs::path> result;
    for (const auto& root : roots) {
        std::error_code error;
        const auto resolved = fs::canonical(root, error);
        if (!error && seen.insert(resolved).second) result.push_back(resolved);
    }
    return result;
}

void ensure_parent_directory(const fs::path& path) {
    const auto parent = path.parent_path();
    if (parent.empty()) return;
    std::error_code error;
    fs::create_directories(parent, error);
    if (error) throw fs::filesystem_error("could not create parent directory", parent, error);
}

std::vector<fs::path> notebook_files(const std::vector<fs::path>& roots) {
    std::vector<fs::path> output;
    std::set<fs::path> visited_directories;
    for (const auto& root : roots)
        collect_notebooks(root, output, visited_directories);
    return output;
}

} // namespace tungsten
