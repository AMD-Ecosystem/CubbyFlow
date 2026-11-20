#
# HIP + C++23 <cmath> workaround for older ROCm clang
#
# C++23 (P0533R9) makes isfinite/isinf/isnan/isnormal constexpr, and HIP treats
# a constexpr function as __host__ __device__. Clang's HIP runtime wrapper
# header declares __device__-only overloads of them after including <cmath>, so
# every HIP source fails with "__device__ function 'isfinite' cannot overload
# __host__ __device__ function". llvm/llvm-project#201563 fixes it by including
# the declarations before <cmath>.
#
# On an affected toolchain this generates a copy of the installed wrapper with
# that include order and sets OUT_DIR to its directory, which goes on the HIP
# include path ahead of the compiler's own headers. The language standard and
# standard library configuration stay the same as for C++ sources. OUT_DIR is
# empty when HIP already compiles at C++23 (a fixed ROCm, or a standard library
# without constexpr <cmath>), so nothing is added there.
#

function(cubbyflow_hip_cxx23_shim OUT_DIR)
    set(${OUT_DIR} "" PARENT_SCOPE)
    set(PROBE_SOURCE "#include <hip/hip_runtime.h>\n#include <cmath>\n__global__ void Probe(float* p) { *p = 1.0f; }\n")
    set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

    try_compile(PROBE_OK SOURCE_FROM_CONTENT probe.hip "${PROBE_SOURCE}"
        NO_CACHE HIP_STANDARD 23 HIP_STANDARD_REQUIRED ON
        OUTPUT_VARIABLE PROBE_LOG)
    if (PROBE_OK OR NOT PROBE_LOG MATCHES "cannot overload __host__ __device__")
        return()
    endif ()

    execute_process(COMMAND ${CMAKE_HIP_COMPILER} -print-resource-dir
        OUTPUT_VARIABLE RESOURCE_DIR OUTPUT_STRIP_TRAILING_WHITESPACE)
    file(TO_CMAKE_PATH "${RESOURCE_DIR}" RESOURCE_DIR)
    set(WRAPPER "${RESOURCE_DIR}/include/__clang_hip_runtime_wrapper.h")
    set(FORWARD_DECLARES "#include <__clang_cuda_math_forward_declares.h>")
    file(READ "${WRAPPER}" CONTENT)
    string(FIND "${CONTENT}" "#include <cmath>" CMATH_POS)
    string(FIND "${CONTENT}" "${FORWARD_DECLARES}" FORWARD_POS)
    if (CMATH_POS EQUAL -1 OR FORWARD_POS LESS CMATH_POS)
        message(WARNING "HIP fails at C++23 but ${WRAPPER} has an unexpected layout")
        return()
    endif ()
    string(REPLACE "${FORWARD_DECLARES}" "" CONTENT "${CONTENT}")
    string(REPLACE "#include <cmath>" "${FORWARD_DECLARES}\n#include <cmath>"
        CONTENT "${CONTENT}")
    set(SHIM_DIR "${CMAKE_BINARY_DIR}/HipCxx23Shim")
    file(WRITE "${SHIM_DIR}/__clang_hip_runtime_wrapper.h" "${CONTENT}")

    try_compile(SHIM_OK SOURCE_FROM_CONTENT probe.hip "${PROBE_SOURCE}"
        NO_CACHE HIP_STANDARD 23 HIP_STANDARD_REQUIRED ON
        COMPILE_DEFINITIONS "-I${SHIM_DIR}" OUTPUT_VARIABLE SHIM_LOG)
    if (NOT SHIM_OK)
        file(REMOVE_RECURSE "${SHIM_DIR}")
        message(WARNING "HIP fails at C++23 and the reordered wrapper does not fix it:\n${SHIM_LOG}")
        return()
    endif ()
    message(STATUS "Using reordered HIP runtime wrapper for C++23: ${SHIM_DIR}")
    set(${OUT_DIR} "${SHIM_DIR}" PARENT_SCOPE)
endfunction()
