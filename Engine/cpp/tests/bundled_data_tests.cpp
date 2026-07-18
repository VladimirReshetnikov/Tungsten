#include "tungsten/bundled_data.hpp"
#include "tungsten/json.hpp"

#include <cstdlib>
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

} // namespace

int main() {
    using namespace tungsten;

    const auto system_source = bundled_system_symbols_json();
    check(system_source.size() == 550318, "system-symbol JSON byte count");
    const auto system = JsonValue::parse(system_source);
    check(system.at("symbolCount").as_uint64() == 7935,
        "system-symbol declared count");
    check(system.at("symbols").size() == 7935,
        "system-symbol array count");
    check(system.at("context").as_string() == "System`",
        "system-symbol context");

    const auto characters_source = bundled_named_characters_json();
    check(characters_source.size() == 29048,
        "named-character JSON byte count");
    const auto characters = JsonValue::parse(characters_source);
    check(characters.at("characters").size() == 1100,
        "named-character mapping count");
    check(characters.at("characters").at("Alpha").as_uint64() == 945,
        "named-character Alpha mapping");

    if (failures != 0) {
        std::cerr << failures << " test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all bundled-data tests passed\n";
    return EXIT_SUCCESS;
}
