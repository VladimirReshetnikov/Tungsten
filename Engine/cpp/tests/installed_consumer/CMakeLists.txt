cmake_minimum_required(VERSION 3.20)

project(TungstenInstalledConsumer LANGUAGES CXX)

find_package(TungstenEngine CONFIG REQUIRED)

add_executable(tungsten-installed-consumer main.cpp)
target_link_libraries(tungsten-installed-consumer PRIVATE Tungsten::Engine)

enable_testing()
add_test(NAME tungsten_installed_consumer_run COMMAND tungsten-installed-consumer)
