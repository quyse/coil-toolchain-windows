cmake_minimum_required(VERSION 3.28.2)

project(get-clang-version)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
set(CMAKE_INTERPROCEDURAL_OPTIMIZAITON ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_executable(get-clang-version get-clang-version.cpp)
install(TARGETS get-clang-version)
