#include "tungsten/frontend.hpp"

#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

void test_front_end_code_generation() {
    const std::filesystem::path path = "notebooks/example.nb";
    const auto open = tungsten::front_end_open_notebook_code(path);
    require(open.rfind("NotebookOpen[\"", 0) == 0,
        "open notebook code prefix");
    require(open.find("notebooks/example.nb") != std::string::npos,
        "open notebook normalized path");

    require(tungsten::front_end_execute_token_code("EvaluateCells")
            == "FrontEndTokenExecute[\"EvaluateCells\"]",
        "token without notebook");
    const auto selected = tungsten::front_end_execute_token_code(
        "Select\"All", path);
    require(selected.find("FrontEndTokenExecute[nb, \"Select\\\"All\"]")
            != std::string::npos,
        "token escaping");
    require(selected.size() >= 4
            && selected.compare(selected.size() - 4, 4, "; nb") == 0,
        "token notebook result");
#ifdef _WIN32
    const auto unc = tungsten::front_end_open_notebook_code(
        std::filesystem::path(LR"(\\?\UNC\server\share\unicode.nb)"));
    require(unc.find("//server/share/unicode.nb") != std::string::npos,
        "extended UNC notebook path normalization");
#endif
}

void test_missing_kernel_controller_result() {
    tungsten::WolframInstallation installation;
    installation.default_index_path =
        std::filesystem::temp_directory_path() / "tungsten-docs.sqlite";
    tungsten::FrontEndController controller{
        tungsten::WolframKernelRunner(installation)};
    const auto result = controller.run("2+2");
    require(result.failure_type == std::optional<std::string>("KernelNotFound"),
        "controller forwards structured missing-kernel result");
}

} // namespace

int main() {
    try {
        test_front_end_code_generation();
        test_missing_kernel_controller_result();
        std::cout << "all C++ FrontEnd tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FrontEnd test failure: " << error.what() << '\n';
        return 1;
    }
}
