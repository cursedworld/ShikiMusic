cmake_minimum_required(VERSION 3.14)
project(shiki_taskbar_smoke LANGUAGES CXX)
get_filename_component(ROOT "../.." ABSOLUTE)
set(EPHEMERAL "${ROOT}/windows/flutter/ephemeral")
set(WRAPPER "${EPHEMERAL}/cpp_client_wrapper")
add_executable(shiki_taskbar_smoke
  taskbar_smoke.cpp
  "${ROOT}/windows/runner/taskbar_controls.cpp"
  "${WRAPPER}/core_implementations.cc"
  "${WRAPPER}/standard_codec.cc"
)
target_compile_features(shiki_taskbar_smoke PRIVATE cxx_std_17)
target_compile_definitions(shiki_taskbar_smoke PRIVATE UNICODE _UNICODE NOMINMAX)
target_include_directories(shiki_taskbar_smoke PRIVATE
  "${ROOT}/windows/runner" "${WRAPPER}/include" "${EPHEMERAL}")
target_link_libraries(shiki_taskbar_smoke PRIVATE
  "${EPHEMERAL}/flutter_windows.dll.lib" gdiplus ole32 uuid advapi32)
add_custom_command(TARGET shiki_taskbar_smoke POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${EPHEMERAL}/flutter_windows.dll"
    "$<TARGET_FILE_DIR:shiki_taskbar_smoke>"
)
