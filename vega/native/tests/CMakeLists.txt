cmake_minimum_required(VERSION 3.20)
project(MediaVaultNativeHostTests LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
include(FetchContent)
find_package(Threads REQUIRED)

# Use the same immutable dependency versions as the shipping native module.
# This target compiles production path/relay code without the device-only APMF SDK.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(DISABLE_PACKAGE_CONFIG_AND_INSTALL ON CACHE BOOL "" FORCE)
FetchContent_Declare(mbedtls URL https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.8/mbedtls-3.6.8.tar.bz2
  URL_HASH SHA256=bc54b818e87f49c0b3281dd85d24adaede0e63b4e822e3fbd49c005a38b9595b)
FetchContent_MakeAvailable(mbedtls)
set(JSON_BuildTests OFF CACHE BOOL "" FORCE)
set(JSON_Install OFF CACHE BOOL "" FORCE)
FetchContent_Declare(json URL https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz
  URL_HASH SHA256=42f6e95cad6ec532fd372391373363b62a14af6d771056dbfc86160e6dfff7aa)
FetchContent_MakeAvailable(json)
set(UTF8PROC_ENABLE_TESTING OFF CACHE BOOL "" FORCE)
FetchContent_Declare(utf8proc URL https://github.com/JuliaStrings/utf8proc/releases/download/v2.12.0/utf8proc-2.12.0.tar.gz
  URL_HASH SHA256=a393fbef160835fb315bc3e91ba8d86f7a73a7cec9e6198b6c60b848b498bfeb)
FetchContent_MakeAvailable(utf8proc)

add_executable(mediavault_native_tests TestMain.cpp PathTests.cpp KeyPolicyTests.cpp PlatformErrorCategoryTests.cpp JellyfinPolicyTests.cpp RelayTests.cpp
  ../kepler/Path.cpp ../kepler/Relay.cpp)
target_include_directories(mediavault_native_tests PRIVATE ../kepler)
target_link_libraries(mediavault_native_tests PRIVATE mbedcrypto utf8proc nlohmann_json::nlohmann_json Threads::Threads)
target_compile_options(mediavault_native_tests PRIVATE -Wall -Wextra -Wpedantic)

enable_testing()
foreach(test IN ITEMS
  path_identifiers path_traversal path_encoding source_boundaries source_unicode_aliases source_parse_limits
  key_existing key_missing_read key_missing_records key_fresh_save key_creation_failure
  platform_error_exact platform_error_spoofed platform_error_precedence platform_error_bound platform_error_private
  jellyfin_catalog_allowed jellyfin_catalog_scope jellyfin_catalog_parameters
  jellyfin_resources_allowed jellyfin_resource_routes jellyfin_resource_parameters
  relay_get_head relay_ranges relay_invalid_ranges relay_invalid_requests relay_resource_limits
  relay_ticket_isolation relay_read_bounds relay_chunk_bounds relay_permission_before_read relay_permission_after_size
  relay_permission_after_read relay_revoke_blocked_read relay_replace_blocked_read relay_revoke_all
  relay_client_limit relay_stop relay_header_deadline)
  add_test(NAME ${test} COMMAND mediavault_native_tests ${test})
  set_tests_properties(${test} PROPERTIES TIMEOUT 15)
endforeach()

option(MEDIAVAULT_NATIVE_INTEGRATION "Build real SMB/HTTPS loopback integration cases" OFF)
if(MEDIAVAULT_NATIVE_INTEGRATION)
  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  set(ENABLE_EXAMPLES OFF CACHE BOOL "" FORCE)
  set(ENABLE_LIBKRB5 OFF CACHE BOOL "" FORCE)
  set(ENABLE_GSSAPI OFF CACHE BOOL "" FORCE)
  FetchContent_Declare(smb2 URL https://github.com/sahlberg/libsmb2/archive/4bc7ea4cdce9cce19e5b271194ae95a6b749b4d3.tar.gz
    URL_HASH SHA256=54beb282995207b5275865ea56477f76e6e5c7a17f80646621f5af598126aef0)
  FetchContent_MakeAvailable(smb2)
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

  # Only this host test executable trusts the ephemeral fixture CA. The actual
  # shipping target configures its separate header from resources/cacert.pem.
  execute_process(COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/integration_fixture.py"
    prepare "${CMAKE_CURRENT_BINARY_DIR}/fixture"
    RESULT_VARIABLE fixture_preparation)
  if(NOT fixture_preparation EQUAL 0)
    message(FATAL_ERROR "Could not generate native integration TLS fixture")
  endif()
  file(READ "${CMAKE_CURRENT_BINARY_DIR}/fixture/ca.pem" MEDIAVAULT_TRUST_ROOTS)
  configure_file(../kepler/TrustRoots.h.in "${CMAKE_CURRENT_BINARY_DIR}/fixture/TrustRoots.h" @ONLY)
  target_sources(mediavault_native_tests PRIVATE SMBTests.cpp HTTPTests.cpp ../kepler/SMB.cpp ../kepler/HTTP.cpp)
  target_include_directories(mediavault_native_tests PRIVATE "${smb2_SOURCE_DIR}/include" "${CMAKE_CURRENT_BINARY_DIR}/fixture")
  target_link_libraries(mediavault_native_tests PRIVATE smb2 CURL::libcurl)
  foreach(test IN ITEMS smb_list_stat smb_ranges smb_unicode smb_authentication smb_cancellation smb_invalid_paths
      http_get_head_range http_unicode_query http_authentication http_redirect_credentials
      http_certificate_validation http_limits http_untrusted_input http_profile_expiry http_text_decoding
      http_error_status_oversized http_error_status_encoding http_error_status_cancellation)
    add_test(NAME ${test} COMMAND mediavault_native_tests ${test})
    set_tests_properties(${test} PROPERTIES TIMEOUT 30 LABELS integration)
  endforeach()
endif()
