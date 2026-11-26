cmake_minimum_required(VERSION 3.16)
project(MediaVaultNFSProbe LANGUAGES C)

if(NOT IS_DIRECTORY "${LIBNFS_SOURCE}")
  message(FATAL_ERROR "Provide the pinned libnfs source tree.")
endif()

# A static executable is enough to verify the SDK link. It stays in the probe
# build directory and is never linked into the application.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(ENABLE_UTILS OFF CACHE BOOL "" FORCE)
set(ENABLE_EXAMPLES OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(ENABLE_DOCUMENTATION OFF CACHE BOOL "" FORCE)
add_subdirectory("${LIBNFS_SOURCE}" libnfs)
target_compile_options(nfs PRIVATE -include sys/uio.h)

add_executable(nfs_readonly_probe ../nfs_readonly_probe.c)
target_include_directories(nfs_readonly_probe PRIVATE "${LIBNFS_SOURCE}/include")
target_compile_options(nfs_readonly_probe PRIVATE -Wall -Wextra -Werror)
target_link_libraries(nfs_readonly_probe PRIVATE nfs)
