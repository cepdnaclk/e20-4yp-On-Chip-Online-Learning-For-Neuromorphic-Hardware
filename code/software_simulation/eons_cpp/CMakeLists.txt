cmake_minimum_required(VERSION 3.16)
project(NOMAD_EONS VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# ── Include paths ──────────────────────────────────────────────
include_directories(${PROJECT_SOURCE_DIR}/include)

# ── Core library ───────────────────────────────────────────────
add_library(nomad_core
    src/core/module.cpp
)

# ── Neuro library ──────────────────────────────────────────────
# add_library(nomad_neuro
#     src/neuro/neuron_lif.cpp
#     src/neuro/synapse.cpp
# )
# target_link_libraries(nomad_neuro PUBLIC nomad_core)

# ── NOC library ────────────────────────────────────────────────
# add_library(nomad_noc
#     src/noc/router.cpp
#     src/noc/arbiter.cpp
#     src/noc/noc_mesh.cpp
# )
# target_link_libraries(nomad_noc PUBLIC nomad_core)

# ── Memory library ─────────────────────────────────────────────
# add_library(nomad_memory
#     src/memory/memory_cluster.cpp
# )
# target_link_libraries(nomad_memory PUBLIC nomad_core)

# ── Evolution library (header-only) ────────────────────────────
add_library(nomad_evo INTERFACE)
target_link_libraries(nomad_evo INTERFACE nomad_core)

# ── Simulation executable ─────────────────────────────────────
add_executable(nomad_eons sim/main.cpp)
target_link_libraries(nomad_eons PRIVATE nomad_core)

# ── Tests ──────────────────────────────────────────────────────
enable_testing()

add_executable(test_fixed_point tests/test_fixed_point.cpp)
target_link_libraries(test_fixed_point PRIVATE nomad_core)
add_test(NAME FixedPointTests COMMAND test_fixed_point)

add_executable(test_signal tests/test_signal.cpp)
target_link_libraries(test_signal PRIVATE nomad_core)
add_test(NAME SignalTests COMMAND test_signal)

add_executable(test_prng tests/test_prng.cpp)
target_link_libraries(test_prng PRIVATE nomad_core)
add_test(NAME PRNGTests COMMAND test_prng)

add_executable(test_evolution tests/test_evolution.cpp)
target_link_libraries(test_evolution PRIVATE nomad_core)
add_test(NAME EvolutionTests COMMAND test_evolution)

add_executable(test_integration tests/test_integration.cpp)
target_link_libraries(test_integration PRIVATE nomad_core)
add_test(NAME IntegrationTests COMMAND test_integration)
