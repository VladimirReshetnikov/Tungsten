#include "tungsten/discovery.hpp"
#include "tungsten/licensing.hpp"

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

#ifndef _WIN32
#include <sys/stat.h>
#endif

namespace {

namespace fs = std::filesystem;
int failures = 0;

void check(bool condition, const std::string& message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

void check_equal(
    const std::string& actual,
    const std::string& expected,
    const std::string& message) {
    if (actual != expected) {
        std::cerr << "FAIL: " << message << "\n  expected: " << expected
                  << "\n  actual:   " << actual << '\n';
        ++failures;
    }
}

fs::path temporary_root(std::string_view prefix) {
    const auto stamp = std::chrono::high_resolution_clock::now()
        .time_since_epoch().count();
    const auto path = fs::temp_directory_path()
        / (std::string(prefix) + "-" + std::to_string(stamp));
    fs::create_directories(path);
    return path;
}

void touch(const fs::path& path) {
    fs::create_directories(path.parent_path());
    std::ofstream(path, std::ios::binary) << "";
}

void discovery_tests() {
    using namespace tungsten;

    const auto root = temporary_root("tungsten-cpp-discovery");
    DiscoveryEnvironment environment{
        root / "Program Files",
        root / "AppData" / "Roaming",
        root / "ProgramData",
        root / "AppData" / "Local",
        root / "Home",
        std::nullopt,
        std::nullopt,
    };
    const auto paid = environment.program_files
        / "Wolfram Research" / "Wolfram" / "15.0";
    const auto older_paid = environment.program_files
        / "Wolfram Research" / "Wolfram" / "14.2";
    const auto engine = environment.program_files
        / "Wolfram Research" / "Wolfram Engine" / "14.3";
    const std::string extreme_version_text =
        "-999999999999999999999999999999999999999999999999999999999999";
    const auto extreme_version = environment.program_files
        / "Wolfram Research" / "Wolfram"
        / extreme_version_text;
    touch(paid / "wolfram.exe");
    touch(paid / "wolframscript.exe");
    touch(older_paid / "wolfram.exe");
    touch(engine / "wolfram.exe");
    touch(extreme_version / "wolfram.exe");
    touch(environment.program_data / "Wolfram" / "Licensing" / "mathpass");

    auto installation = discover_installation(environment);
    check(installation.product == "Wolfram", "default discovery selects paid product");
    check(installation.product_family == "wolfram", "paid product family");
    check(installation.version == "15.0", "latest paid version selected");
    check(installation.install_dir == fs::canonical(paid), "canonical install directory");
    check(installation.kernel_cli == fs::canonical(paid) / "wolfram.exe",
        "kernel CLI discovery");
    check(installation.default_index_path
            == *environment.local_app_data / "Tungsten" / "docs" / "wolfram-15.0.sqlite3",
        "paid documentation index path");
    check(installation.available_installations.size() == 4,
        "all installations retained");
    check(installation.available_installations.size() == 4
            && installation.available_installations[0].version == "15.0"
            && installation.available_installations[1].version == "14.2"
            && installation.available_installations[2].version == extreme_version_text
            && installation.available_installations[3].product_family == "engine",
        "product priority and overflow-safe descending version ordering");

    const auto engine_mathpass = *environment.appdata
        / "WolframEngine" / "Licensing" / "mathpass";
    touch(engine_mathpass);
    environment.requested_product = "engine";
    installation = discover_installation(environment);
    check(installation.product == "Wolfram Engine", "product override selects engine");
    check(installation.install_dir == fs::canonical(engine), "engine install directory");
    check(installation.mathpass == engine_mathpass, "engine license priority");
    check(installation.default_index_path
            == *environment.local_app_data / "Tungsten" / "docs"
                / "wolfram-engine-14.3.sqlite3",
        "engine documentation index path");
    check(installation.selection_reason == "TUNGSTEN_WOLFRAM_PRODUCT=engine",
        "selection reason");

    const auto documentation_install = root / "Wolfram" / "14.3";
    fs::create_directories(documentation_install);
    const auto current = *environment.appdata / "Wolfram" / "Paclets" / "Repository"
        / "SystemDocsUpdate3-14.3.0.3" / "Documentation" / "English";
    const auto stale = *environment.appdata / "Wolfram" / "Paclets" / "Repository"
        / "SystemDocsUpdate2-14.2.0.2" / "Documentation" / "English";
    const auto common = environment.program_files / "Common Files" / "Wolfram Research"
        / "Documentation.en-us" / "14.3" / "Documentation" / "English" / "System";
    fs::create_directories(current);
    fs::create_directories(stale);
    fs::create_directories(common);
    const auto roots = discover_docs_roots(
        documentation_install, std::nullopt, environment);
    check(roots.size() == 2, "documentation root count");
    check(roots.size() == 2 && roots[0] == fs::canonical(current)
            && roots[1] == fs::canonical(common),
        "documentation roots filter version and preserve priority");

    const auto notebooks = root / "notebooks";
    touch(notebooks / "a.nb");
    touch(notebooks / "nested" / "b.nb");
    touch(notebooks / "nested" / "ignore.wl");
    check(notebook_files({notebooks}).size() == 2, "recursive notebook discovery");
    std::error_code symlink_error;
    fs::create_directory_symlink(notebooks, notebooks / "cycle", symlink_error);
    if (!symlink_error)
        check(notebook_files({notebooks}).size() == 2,
            "notebook discovery does not follow directory-symlink cycles");

    const auto json = installation.to_json();
    check(json.at("product_family").as_string() == "engine",
        "installation JSON projection");
    check(json.at("available_installations").size() == 4,
        "installation summary JSON projection");

    std::error_code error;
    fs::remove_all(root, error);
}

#ifndef _WIN32
void posix_discovery_tests() {
    using namespace tungsten;
    const auto root = temporary_root("tungsten-cpp-posix-discovery");
    DiscoveryEnvironment environment{
        root / "usr-local",
        root / "home" / ".local" / "share",
        root / "usr-share",
        root / "home" / ".cache",
        root / "home",
        std::nullopt,
        std::optional<std::string>("engine"),
    };
#ifdef __APPLE__
    environment.program_files = root / "Applications";
    const auto install = environment.program_files / "Wolfram Engine.app";
    touch(install / "Contents" / "MacOS" / "WolframKernel");
#else
    const auto install = environment.program_files
        / "Wolfram" / "WolframEngine" / "15.1";
    touch(install / "Executables" / "wolfram");
#endif
    const auto license = *environment.home
        / ".WolframEngine" / "Licensing" / "mathpass";
    touch(license);
    const auto installation = discover_installation(environment);
    check(installation.install_dir == fs::canonical(install),
        "POSIX discovery finds the native Wolfram installation layout");
    check(installation.kernel_cli.has_value()
            && installation.kernel_cli->filename() != "wolfram.exe",
        "POSIX discovery uses an extensionless kernel executable");
    check(installation.mathpass == license,
        "POSIX discovery finds the per-user mathpass");
    check(installation.default_index_path.parent_path().parent_path()
            == *environment.local_app_data / "Tungsten",
        "POSIX documentation index uses the per-user cache root");
    std::error_code error;
    fs::remove_all(root, error);
}
#endif

void licensing_tests() {
    using namespace tungsten;

    const auto root = temporary_root("tungsten-cpp-license");
    const auto source = root / "mathpass";
    {
        std::ofstream stream(source, std::ios::binary);
        stream << "% header\nalpha\nbeta\nalpha\n\n";
    }
    const auto inspection = inspect_mathpass(source);
    check(inspection.path == source.u8string(), "mathpass inspection path");
    check(inspection.header_present, "mathpass header detection");
    check(inspection.original_line_count == 5, "mathpass line count");
    check(inspection.unique_entry_count == 3, "mathpass unique entry count");
    check(inspection.duplicate_entry_count == 1, "mathpass duplicate count");
    check(inspection.to_json().at("duplicate_entry_count").as_uint64() == 1,
        "mathpass JSON projection");

    fs::path temporary_path;
    {
        auto deduped = DedupedMathpass::create(source);
        check(deduped.path().has_value(), "temporary mathpass path created");
        temporary_path = *deduped.path();
        std::ifstream stream(temporary_path, std::ios::binary);
        const std::string contents{
            std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
        check_equal(contents, "% header\nalpha\nbeta\n\n",
            "mathpass de-duplication preserves header, order, and blank entry");
#ifndef _WIN32
        struct stat file_status {};
        struct stat directory_status {};
        check(::stat(temporary_path.c_str(), &file_status) == 0
                && (file_status.st_mode & 0777) == 0600,
            "temporary mathpass file is owner-readable only");
        check(::stat(temporary_path.parent_path().c_str(), &directory_status) == 0
                && (directory_status.st_mode & 0777) == 0700,
            "temporary mathpass directory is owner-accessible only");
#endif
    }
    check(!fs::exists(temporary_path), "temporary mathpass is removed by RAII");

    const auto missing = inspect_mathpass(std::nullopt);
    check(!missing.path && missing.original_line_count == 0,
        "missing mathpass inspection is a valid noop");
    auto absent = DedupedMathpass::create(std::nullopt);
    check(!absent.path(), "missing mathpass does not create a temporary file");

    const auto alternate_breaks = root / "mathpass-alternate-breaks";
    {
        std::ofstream stream(alternate_breaks, std::ios::binary);
        stream << "% header\ralpha\vbeta\xC2\x85gamma\xE2\x80\xA8"
                  "alpha\r\n";
    }
    const auto alternate = inspect_mathpass(alternate_breaks);
    check(alternate.header_present && alternate.original_line_count == 5,
        "mathpass line splitting matches Python splitlines across line boundaries");
    check(alternate.unique_entry_count == 3
            && alternate.duplicate_entry_count == 1,
        "mathpass de-duplication handles alternate Unicode line boundaries");

    const auto invalid_utf8 = root / "mathpass-invalid-utf8";
    {
        std::ofstream stream(invalid_utf8, std::ios::binary);
        stream << "% header\n\xe2\x82\n\xef\xbf\xbd\n";
    }
    const auto invalid = inspect_mathpass(invalid_utf8);
    check(invalid.unique_entry_count == 1 && invalid.duplicate_entry_count == 1,
        "mathpass decoding uses Python-compatible malformed UTF-8 replacement boundaries");

    std::error_code error;
    fs::remove_all(root, error);
}

} // namespace

int main() {
    discovery_tests();
#ifndef _WIN32
    posix_discovery_tests();
#endif
    licensing_tests();
    if (failures != 0) {
        std::cerr << failures << " runtime foundation test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all C++ runtime foundation tests passed\n";
    return EXIT_SUCCESS;
}
