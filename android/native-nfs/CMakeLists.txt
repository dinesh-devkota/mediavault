cmake_minimum_required(VERSION 3.22)
project(MediaVaultNFS LANGUAGES C)

if(NOT ANDROID OR NOT IS_DIRECTORY "${LIBNFS_SOURCE}")
  message(FATAL_ERROR "Provide the Android NDK toolchain and a pinned libnfs source tree.")
endif()

set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
set(ENABLE_UTILS OFF CACHE BOOL "" FORCE)
set(ENABLE_EXAMPLES OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(ENABLE_DOCUMENTATION OFF CACHE BOOL "" FORCE)
add_subdirectory("${LIBNFS_SOURCE}" libnfs)
# APK library filenames and the dependency SONAME must agree.
set_property(TARGET nfs PROPERTY VERSION)
set_property(TARGET nfs PROPERTY SOVERSION)
target_compile_options(nfs PRIVATE -include sys/uio.h)

add_library(mediavaultnfs SHARED bridge.c)
target_include_directories(mediavaultnfs PRIVATE "${LIBNFS_SOURCE}/include")
target_compile_options(mediavaultnfs PRIVATE -Wall -Wextra -Werror)
target_link_libraries(mediavaultnfs PRIVATE nfs)
