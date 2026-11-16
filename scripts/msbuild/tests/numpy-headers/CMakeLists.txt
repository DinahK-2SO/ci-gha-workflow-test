cmake_minimum_required(VERSION 3.16)
project(numpy_header_abi_probe LANGUAGES CXX)

if(NOT MSVC OR NOT CMAKE_GENERATOR_PLATFORM MATCHES "^(ARM64|x64)$")
    message(FATAL_ERROR "This probe requires ARM64 or x64 MSVC")
endif()
foreach(input IN ITEMS
    "${PYTHON_DEVELOPMENT_ROOT}/include/Python.h"
    "${PYTHON_DEVELOPMENT_ROOT}/libs/python313.lib"
    "${NUMPY_INCLUDE_DIR}/numpy/_numpyconfig.h")
    if(NOT EXISTS "${input}")
        message(FATAL_ERROR "Missing dependency input: ${input}")
    endif()
endforeach()

add_executable(numpy_header_abi_probe main.cpp)
target_compile_features(numpy_header_abi_probe PRIVATE cxx_std_17)
target_include_directories(numpy_header_abi_probe PRIVATE
    "${PYTHON_DEVELOPMENT_ROOT}/include" "${NUMPY_INCLUDE_DIR}")
target_link_libraries(numpy_header_abi_probe PRIVATE
    "${PYTHON_DEVELOPMENT_ROOT}/libs/python313.lib")
