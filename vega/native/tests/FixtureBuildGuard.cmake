# Exercise the actual production CMake entry point. Invalid combinations must
# fail before dependency downloads or any SDK packaging is attempted.
set(build_type Debug)
set(processor x86_64)
set(expected "The VVD fixture is restricted to Debug/x86_64.")
if(GUARD STREQUAL "release")
  set(build_type Release)
elseif(GUARD STREQUAL "relwithdebinfo")
  set(build_type RelWithDebInfo)
elseif(GUARD STREQUAL "armv7" OR GUARD STREQUAL "aarch64")
  set(processor "${GUARD}")
elseif(GUARD STREQUAL "package_identity")
  set(expected "A separate VVD fixture package identity is required.")
else()
  message(FATAL_ERROR "Unknown fixture build guard case")
endif()
execute_process(COMMAND "${GUARD_CMAKE}" -S "${NATIVE_SOURCE}" -B "${GUARD_BINARY}"
  -DMEDIAVAULT_VVD_FIXTURE=ON "-DCMAKE_BUILD_TYPE=${build_type}"
  -DCMAKE_SYSTEM_NAME=Linux "-DCMAKE_SYSTEM_PROCESSOR=${processor}"
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON
  RESULT_VARIABLE result OUTPUT_VARIABLE output ERROR_VARIABLE error TIMEOUT 25)
file(WRITE "${GUARD_BINARY}/guard-result.log" "${output}\n${error}")
string(FIND "${output}\n${error}" "${expected}" match)
if(result EQUAL 0 OR match EQUAL -1)
  message(FATAL_ERROR "Production fixture guard did not reject ${GUARD} as expected (${result}):\n${output}\n${error}")
endif()
