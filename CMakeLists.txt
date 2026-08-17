cmake_minimum_required(VERSION 3.25)
project(greedyfind C OBJC)

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_OBJC_STANDARD 17)
set(CMAKE_OBJC_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# Strict warnings — every Gate 1 build must show zero warnings under these.
set(GRD_WARN_FLAGS
  -Wall
  -Wextra
  -Wpedantic
  -Wshadow
  -Wconversion
  -Wsign-conversion
  -Werror
)

# Apply to host targets via target_compile_options below; do NOT append to
# CMAKE_C_FLAGS / CMAKE_OBJC_FLAGS because space-splitting misquotes them.

# Link-time optimisations on Release builds.
if(CMAKE_BUILD_TYPE STREQUAL "Release")
  set(CMAKE_INTERPROCEDURAL_OPTIMIZATION TRUE)
endif()

# ----------------------------------------------------------------------------
# Toolchain: Metal compiler
#
# Note: `metal` and `metallib` are not normally on $PATH; they live in a
# per-version cryptex mount. Always go through `xcrun` so we get the
# version-pinned path and so SDK search paths are wired correctly.
# ----------------------------------------------------------------------------
find_program(XCRUN_TOOL xcrun REQUIRED)

execute_process(
  COMMAND ${XCRUN_TOOL} --find metal
  OUTPUT_VARIABLE METAL_TOOL
  OUTPUT_STRIP_TRAILING_WHITESPACE
  RESULT_VARIABLE _metal_rc
)
if(NOT _metal_rc EQUAL 0 OR "${METAL_TOOL}" STREQUAL "")
  message(FATAL_ERROR
    "xcrun metal not found. Install the Metal Toolchain via:\n"
    "    xcodebuild -downloadComponent MetalToolchain\n"
    "or install full Xcode from the App Store.")
endif()

execute_process(
  COMMAND ${XCRUN_TOOL} --find metallib
  OUTPUT_VARIABLE METALLIB_TOOL
  OUTPUT_STRIP_TRAILING_WHITESPACE
  RESULT_VARIABLE _metallib_rc
)
if(NOT _metallib_rc EQUAL 0 OR "${METALLIB_TOOL}" STREQUAL "")
  message(FATAL_ERROR
    "xcrun metallib not found. Re-run:\n"
    "    xcodebuild -downloadComponent MetalToolchain")
endif()

message(STATUS "Metal compiler: ${METAL_TOOL}")
message(STATUS "Metallib:       ${METALLIB_TOOL}")
message(STATUS "xcrun:          ${XCRUN_TOOL}")

# ----------------------------------------------------------------------------
# Metal library
# ----------------------------------------------------------------------------
# Compile each .metal file to its own .air, then link with metallib.
# Metal's compiler takes one input per `-o` invocation; passing multiple
# files fails with "cannot specify -o when generating multiple output files".
set(METAL_SRC
  "${CMAKE_SOURCE_DIR}/metal/secp256k1.metal"
  "${CMAKE_SOURCE_DIR}/metal/ecdsa.metal"
  "${CMAKE_SOURCE_DIR}/metal/sweep.metal"
  "${CMAKE_SOURCE_DIR}/metal/sweep_pubkey.metal"
)

set(METAL_LIB "${CMAKE_BINARY_DIR}/greedy.metallib")
set(METAL_AIR_FILES "")

foreach(_metal_src ${METAL_SRC})
  get_filename_component(_metal_name "${_metal_src}" NAME_WE)
  set(_air_out "${CMAKE_BINARY_DIR}/${_metal_name}.air")
  list(APPEND METAL_AIR_FILES "${_air_out}")
  add_custom_command(
    OUTPUT "${_air_out}"
    COMMAND ${METAL_TOOL} -c -std=metal3.0 -O3
            -I "${CMAKE_SOURCE_DIR}/metal"
            -o "${_air_out}"
            "${_metal_src}"
    DEPENDS "${_metal_src}"
    COMMENT "Compiling ${_metal_name}.metal to AIR"
    VERBATIM
  )
endforeach()

add_custom_command(
  OUTPUT "${METAL_LIB}"
  COMMAND ${METALLIB_TOOL} ${METAL_AIR_FILES} -o "${METAL_LIB}"
  DEPENDS ${METAL_AIR_FILES}
  COMMENT "Linking Metal AIR to metallib"
  VERBATIM
)

add_custom_target(greedy_metallib ALL DEPENDS "${METAL_LIB}")

# ----------------------------------------------------------------------------
# Host executable
# ----------------------------------------------------------------------------
file(GLOB HOST_SRC
  "${CMAKE_SOURCE_DIR}/host/*.m"
  "${CMAKE_SOURCE_DIR}/host/*.c"
)

add_executable(greedyfind ${HOST_SRC})

target_include_directories(greedyfind PRIVATE
  "${CMAKE_SOURCE_DIR}/host"
  /opt/homebrew/Cellar/secp256k1/0.8.0/include
  /opt/homebrew/include
)

target_compile_options(greedyfind PRIVATE ${GRD_WARN_FLAGS})

# Frameworks: Foundation + Metal are the only Apple frameworks required.
find_library(METAL_FRAMEWORK Metal REQUIRED)
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)

target_link_directories(greedyfind PRIVATE
  /opt/homebrew/Cellar/secp256k1/0.8.0/lib
  /opt/homebrew/lib
)

target_link_libraries(greedyfind PRIVATE
  ${FOUNDATION_FRAMEWORK}
  ${METAL_FRAMEWORK}
  secp256k1
  tomcrypt
)

# Embed the metallib via rpath so the executable can find it next to itself.
set_target_properties(greedyfind PROPERTIES
  BUILD_RPATH "${CMAKE_BINARY_DIR}"
  INSTALL_RPATH "${CMAKE_BINARY_DIR}"
)

add_dependencies(greedyfind greedy_metallib)

# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------
option(GRD_BUILD_TESTS "Build unit and KAT tests" ON)

if(GRD_BUILD_TESTS)
  enable_testing()

file(GLOB KAT_SRC
  "${CMAKE_SOURCE_DIR}/tests/kat/*.c"
  "${CMAKE_SOURCE_DIR}/tests/kat/*.m"
)
  foreach(KAT_FILE ${KAT_SRC})
    get_filename_component(KAT_NAME "${KAT_FILE}" NAME_WE)
    # KATs need the host-side helpers from host/ecc.c and friends.
    # Note: host/main.m is excluded (defines main, conflicts with KAT
    # main). KATs expose their own main.
    add_executable("${KAT_NAME}" "${KAT_FILE}"
      "${CMAKE_SOURCE_DIR}/host/ecc.c"
      "${CMAKE_SOURCE_DIR}/host/hash.c"
      "${CMAKE_SOURCE_DIR}/host/pubkey.m"
      "${CMAKE_SOURCE_DIR}/host/address.m"
      "${CMAKE_SOURCE_DIR}/host/sweep.m")
    target_include_directories("${KAT_NAME}" PRIVATE
      "${CMAKE_SOURCE_DIR}/host"
      "${CMAKE_SOURCE_DIR}/tests"
    )
    file(READ "${KAT_FILE}" HEAD_BYTES LIMIT 4096)
    string(FIND "${HEAD_BYTES}" "#import" HAS_OBJC)
    if(HAS_OBJC GREATER -1)
      target_link_libraries("${KAT_NAME}" PRIVATE
        ${FOUNDATION_FRAMEWORK}
        ${METAL_FRAMEWORK}
      )
    endif()
    target_compile_options("${KAT_NAME}" PRIVATE ${GRD_WARN_FLAGS})
    # Link against the third-party crypto libraries we use for the
    # host reference. secp256k1 comes from Homebrew (v0.8.0).
    # libtomcrypt comes from Homebrew. Override via environment if
    # installed elsewhere.
    target_include_directories("${KAT_NAME}" PRIVATE
      /opt/homebrew/Cellar/secp256k1/0.8.0/include
      /opt/homebrew/include
    )
    target_link_directories("${KAT_NAME}" PRIVATE
      /opt/homebrew/Cellar/secp256k1/0.8.0/lib
      /opt/homebrew/lib
    )
    target_link_libraries("${KAT_NAME}" PRIVATE
      secp256k1
      tomcrypt
    )
    add_test(NAME "kat_${KAT_NAME}" COMMAND "${KAT_NAME}")
  endforeach()

  file(GLOB UNIT_SRC "${CMAKE_SOURCE_DIR}/tests/unit/*.c")
  foreach(UNIT_FILE ${UNIT_SRC})
    get_filename_component(UNIT_NAME "${UNIT_FILE}" NAME_WE)
    add_executable("${UNIT_NAME}" "${UNIT_FILE}"
      "${CMAKE_SOURCE_DIR}/host/ecc.c")
    target_include_directories("${UNIT_NAME}" PRIVATE
      "${CMAKE_SOURCE_DIR}/host"
      "${CMAKE_SOURCE_DIR}/tests"
    )
    file(READ "${UNIT_FILE}" HEAD_BYTES LIMIT 4096)
    string(FIND "${HEAD_BYTES}" "#import" HAS_OBJC)
    if(HAS_OBJC GREATER -1)
      target_link_libraries("${UNIT_NAME}" PRIVATE
        ${FOUNDATION_FRAMEWORK}
        ${METAL_FRAMEWORK}
      )
    endif()
    target_compile_options("${UNIT_NAME}" PRIVATE ${GRD_WARN_FLAGS})
    add_test(NAME "unit_${UNIT_NAME}" COMMAND "${UNIT_NAME}")
  endforeach()
endif()

# ----------------------------------------------------------------------------
# Bench
# ----------------------------------------------------------------------------
option(GRD_BUILD_BENCH "Build throughput microbench" ON)

if(GRD_BUILD_BENCH)
  file(GLOB BENCH_SRC "${CMAKE_SOURCE_DIR}/bench/*.m")
  foreach(BENCH_FILE ${BENCH_SRC})
    get_filename_component(BENCH_NAME "${BENCH_FILE}" NAME_WE)
    add_executable("${BENCH_NAME}" "${BENCH_FILE}")
    target_include_directories("${BENCH_NAME}" PRIVATE
      "${CMAKE_SOURCE_DIR}/host"
    )
    target_link_libraries("${BENCH_NAME}" PRIVATE
      ${FOUNDATION_FRAMEWORK}
      ${METAL_FRAMEWORK}
    )
    target_compile_options("${BENCH_NAME}" PRIVATE ${GRD_WARN_FLAGS})
    add_dependencies("${BENCH_NAME}" greedy_metallib)
  endforeach()
endif()

message(STATUS "Build type:      ${CMAKE_BUILD_TYPE}")
message(STATUS "Host sources:    ${HOST_SRC}")
message(STATUS "Metal sources:   ${METAL_SRC}")