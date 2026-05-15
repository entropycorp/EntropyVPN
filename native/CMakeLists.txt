cmake_minimum_required(VERSION 3.14)
project(entropy_vpn_native LANGUAGES CXX)

add_library(entropy_vpn_native SHARED
  "share_link_parser.cpp"
)

target_include_directories(entropy_vpn_native PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_features(entropy_vpn_native PUBLIC cxx_std_17)

if(WIN32)
  target_link_libraries(entropy_vpn_native PRIVATE ws2_32)
endif()

if(MSVC)
  target_compile_options(entropy_vpn_native PRIVATE /W4 /WX /EHsc)
else()
  target_compile_options(entropy_vpn_native PRIVATE -Wall -Wextra -Werror)
endif()
