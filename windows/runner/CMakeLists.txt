cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)






add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "windows_app_catalog_channel.cpp"
  "windows_runtime_channel.cpp"
  "windows_runtime_channel_config.cpp"
  "windows_runtime_channel_controller.cpp"
  "windows_runtime_channel_support.cpp"
  "windows_tun_channel.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

add_library(entropy_vpn_windows_native STATIC
  "entropy_vpn_killswitch.cpp"
  "entropy_vpn_native_tun.cpp"
  "entropy_vpn_service_common.cpp"
  "entropy_vpn_service_protocol.cpp"
)

add_executable(entropy_vpn_service
  "entropy_vpn_service.cpp"
  "entropy_vpn_service_commands.cpp"
  "entropy_vpn_service_pipe.cpp"
  "entropy_vpn_service_tun.cpp"
)



apply_standard_settings(${BINARY_NAME})
apply_standard_settings(entropy_vpn_windows_native)
apply_standard_settings(entropy_vpn_service)


target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")


target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")
target_compile_definitions(entropy_vpn_windows_native PRIVATE "NOMINMAX")
target_compile_definitions(entropy_vpn_service PRIVATE "NOMINMAX")



target_link_libraries(entropy_vpn_windows_native PUBLIC "dnsapi.lib")
target_link_libraries(entropy_vpn_windows_native PUBLIC "fwpuclnt.lib")
target_link_libraries(entropy_vpn_windows_native PUBLIC "iphlpapi.lib")
target_link_libraries(entropy_vpn_windows_native PUBLIC "rpcrt4.lib")
target_link_libraries(entropy_vpn_windows_native PUBLIC "ws2_32.lib")

target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE entropy_vpn_windows_native)
target_link_libraries(${BINARY_NAME} PRIVATE "advapi32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "d2d1.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "dwrite.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "dnsapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "gdiplus.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "iphlpapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "ole32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "shell32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "wininet.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "ws2_32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

target_link_libraries(entropy_vpn_service PRIVATE entropy_vpn_windows_native)
target_link_libraries(entropy_vpn_service PRIVATE "advapi32.lib")
target_link_libraries(entropy_vpn_service PRIVATE "iphlpapi.lib")
target_link_libraries(entropy_vpn_service PRIVATE "shell32.lib")
target_link_libraries(entropy_vpn_service PRIVATE "ws2_32.lib")

add_dependencies(${BINARY_NAME} flutter_assemble)
