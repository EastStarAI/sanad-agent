cmake_minimum_required(VERSION 3.20)
project(sanad_agent_launcher LANGUAGES CXX)

add_executable(sanad-launcher WIN32 sanad_agent_launcher.cpp)
target_compile_features(sanad-launcher PRIVATE cxx_std_17)
target_compile_definitions(sanad-launcher PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
set_target_properties(sanad-launcher PROPERTIES
  MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
  RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}/out"
  RUNTIME_OUTPUT_DIRECTORY_DEBUG "${CMAKE_BINARY_DIR}/out"
)
