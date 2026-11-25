cmake_minimum_required(VERSION 3.25)
project(MediaVaultNative VERSION 1.5.0 LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
include(FetchContent)

# Immutable upstream sources. SMB remains dynamically linked for LGPL relinking.
set(ENABLE_EXAMPLES OFF CACHE BOOL "" FORCE)
set(ENABLE_LIBKRB5 OFF CACHE BOOL "" FORCE)
set(ENABLE_GSSAPI OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
FetchContent_Declare(smb2 URL https://github.com/sahlberg/libsmb2/archive/4bc7ea4cdce9cce19e5b271194ae95a6b749b4d3.tar.gz
  URL_HASH SHA256=54beb282995207b5275865ea56477f76e6e5c7a17f80646621f5af598126aef0)
FetchContent_MakeAvailable(smb2)
# Vega's native packager accepts *.so files, not versioned symlink chains.
# Keep an independently replaceable shared library with an app-private SONAME.
set_property(TARGET smb2 PROPERTY VERSION)
set_property(TARGET smb2 PROPERTY SOVERSION)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(DISABLE_PACKAGE_CONFIG_AND_INSTALL ON CACHE BOOL "" FORCE)
FetchContent_Declare(mbedtls URL https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.8/mbedtls-3.6.8.tar.bz2
  URL_HASH SHA256=bc54b818e87f49c0b3281dd85d24adaede0e63b4e822e3fbd49c005a38b9595b)
FetchContent_MakeAvailable(mbedtls)

set(BUILD_CURL_EXE OFF CACHE BOOL "" FORCE)
set(CURL_DISABLE_INSTALL ON CACHE BOOL "" FORCE)
set(BUILD_LIBCURL_DOCS OFF CACHE BOOL "" FORCE)
set(BUILD_MISC_DOCS OFF CACHE BOOL "" FORCE)
set(ENABLE_CURL_MANUAL OFF CACHE BOOL "" FORCE)
set(BUILD_STATIC_LIBS ON CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(CURL_USE_OPENSSL OFF CACHE BOOL "" FORCE)
set(CURL_USE_MBEDTLS ON CACHE BOOL "" FORCE)
set(CURL_USE_LIBPSL OFF CACHE BOOL "" FORCE)
set(CURL_USE_LIBSSH2 OFF CACHE BOOL "" FORCE)
set(CURL_ZLIB OFF CACHE BOOL "" FORCE)
set(CURL_BROTLI OFF CACHE BOOL "" FORCE)
set(CURL_ZSTD OFF CACHE BOOL "" FORCE)
foreach(protocol DICT FILE FTP GOPHER IMAP LDAP LDAPS MQTT POP3 RTSP SMTP TELNET TFTP IPFS WEBSOCKETS)
  set(CURL_DISABLE_${protocol} ON CACHE BOOL "" FORCE)
endforeach()
set(MBEDTLS_INCLUDE_DIR "${mbedtls_SOURCE_DIR}/include" CACHE PATH "" FORCE)
set(MBEDTLS_LIBRARY mbedtls CACHE STRING "" FORCE)
set(MBEDX509_LIBRARY mbedx509 CACHE STRING "" FORCE)
set(MBEDCRYPTO_LIBRARY mbedcrypto CACHE STRING "" FORCE)
FetchContent_Declare(curl URL https://curl.se/download/curl-8.23.0.tar.xz
  URL_HASH SHA256=8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5)
FetchContent_MakeAvailable(curl)

set(JSON_BuildTests OFF CACHE BOOL "" FORCE)
set(JSON_Install OFF CACHE BOOL "" FORCE)
FetchContent_Declare(json URL https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz
  URL_HASH SHA256=42f6e95cad6ec532fd372391373363b62a14af6d771056dbfc86160e6dfff7aa)
FetchContent_MakeAvailable(json)
set(UTF8PROC_ENABLE_TESTING OFF CACHE BOOL "" FORCE)
FetchContent_Declare(utf8proc URL https://github.com/JuliaStrings/utf8proc/releases/download/v2.12.0/utf8proc-2.12.0.tar.gz
  URL_HASH SHA256=a393fbef160835fb315bc3e91ba8d86f7a73a7cec9e6198b6c60b848b498bfeb)
FetchContent_MakeAvailable(utf8proc)

find_package(turbomoduleAPI CONFIG REQUIRED)
find_package(Apmf REQUIRED)
find_package(Kepler REQUIRED)
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/resources/cacert.pem" MEDIAVAULT_TRUST_ROOTS)
configure_file(kepler/TrustRoots.h.in "${CMAKE_CURRENT_BINARY_DIR}/TrustRoots.h" @ONLY)
kepler_add_idl_import_library(MediaVaultPlatformInterfaces PACKAGES
  com.amazon.kepler.crypto com.amazon.kepler.keystore
  com.amazon.kepler.security com.amazon.kepler.file_system)
kepler_add_turbo_module_library(MediaVaultNative SHARED
  kepler/AutoLinkInit.cpp
  kepler/Path.cpp kepler/Vault.cpp kepler/SMB.cpp kepler/HTTP.cpp kepler/Backend.cpp kepler/Relay.cpp
  kepler/turbo-modules/generated/MediaVaultNativeSpec.cpp
  kepler/turbo-modules/MediaVaultNative.cpp)
target_link_libraries(MediaVaultNative PRIVATE MediaVaultPlatformInterfaces smb2 CURL::libcurl
  mbedcrypto utf8proc nlohmann_json::nlohmann_json)
target_include_directories(MediaVaultNative PRIVATE "${CMAKE_CURRENT_BINARY_DIR}" "${smb2_SOURCE_DIR}/include")
target_link_options(MediaVaultNative PRIVATE "LINKER:--no-undefined" "LINKER:-z,defs")
install(TARGETS MediaVaultNative)
