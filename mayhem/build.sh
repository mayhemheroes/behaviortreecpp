#!/usr/bin/env bash
#
# behaviortreecpp/mayhem/build.sh — build BehaviorTree/BehaviorTree.CPP's three OSS-Fuzz harnesses
# as sanitized libFuzzer targets (+ standalone reproducers), AND the project's own gtest suite for
# mayhem/test.sh.
#
# Fuzzed surface (all three harnesses live in fuzzing/*.cpp upstream; copies are in mayhem/harnesses/):
#   bt_fuzzer     — the XML behavior-tree parser: feeds attacker bytes to
#                   BehaviorTreeFactory::createTreeFromText / VerifyXML / registerBehaviorTreeFromText
#                   (parses <root BTCPP_format="4"><BehaviorTree>…</BehaviorTree></root> trees).
#   script_fuzzer — the embedded scripting expression language: BT::ValidateScript / ParseScript /
#                   ParseScriptAndExecute over a fuzzed script string.
#   bb_fuzzer     — the Blackboard typed key/value store + JSON import/export round-tripping.
#
# Build contract from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). The BT.CPP library ITSELF is compiled with $SANITIZER_FLAGS (via CMake flag
# injection) so the fuzzed parser/scripting/blackboard code — not just the harness — is instrumented.
#
# Strategy: the upstream CMake fuzzing path (cmake/fuzzing_build.cmake) already links each harness
# against $ENV{LIB_FUZZING_ENGINE} when an OSS-Fuzz-style env is detected. We exploit that with two
# CMake configures sharing one source tree:
#   pass 1: LIB_FUZZING_ENGINE=-fsanitize=fuzzer        -> /mayhem/<fuzzer>            (libFuzzer)
#   pass 2: LIB_FUZZING_ENGINE=<standalone main .o>     -> /mayhem/<fuzzer>-standalone (run-once repro)
# This reuses upstream's exact link line (zmq/sqlite/tinyxml2/… extra libs) for BOTH builds.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS

cd "$SRC"

FUZZERS="bt_fuzzer script_fuzzer bb_fuzzer"
# C++17 + libstdc++; SANITIZER_FLAGS instrument the BT.CPP library code (the fuzzed surface).
# DEBUG_FLAGS add DWARF < 4 symbols required for reproducers and coverage.
CXX_BUILD_FLAGS="-std=c++17 -stdlib=libstdc++ $SANITIZER_FLAGS $DEBUG_FLAGS"
C_BUILD_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"

# When LIB_FUZZING_ENGINE contains 'fuzzer' (i.e. -fsanitize=fuzzer), the library code must be
# compiled with -fsanitize=fuzzer-no-link so the fuzzed surface gets sancov edge instrumentation.
# Without this the entire BT.CPP library is uninstrumented → 0 coverage edges → Mayhem reports
# 0-edge runs.  -fsanitize=fuzzer-no-link instruments for coverage but does NOT link the fuzzer
# runtime (that comes in via LIB_FUZZING_ENGINE at link time), so it is safe to apply to the lib.
# Guard: only inject when LIB_FUZZING_ENGINE is the libFuzzer flag, not the standalone .o path.
FUZZ_INSTRUMENT_FLAG=""
if echo "${LIB_FUZZING_ENGINE}" | grep -q 'fuzzer'; then
  FUZZ_INSTRUMENT_FLAG="-fsanitize=fuzzer-no-link"
fi

CMAKE_COMMON=(
  -DCMAKE_BUILD_TYPE=Release
  -DENABLE_FUZZING=ON
  -DBUILD_TESTING=OFF
  -DCMAKE_C_COMPILER="$CC"
  -DCMAKE_CXX_COMPILER="$CXX"
  -DCMAKE_CXX_FLAGS="$CXX_BUILD_FLAGS $FUZZ_INSTRUMENT_FLAG"
  -DCMAKE_C_FLAGS="$C_BUILD_FLAGS $FUZZ_INSTRUMENT_FLAG"
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS"
)

# ── pass 1: libFuzzer targets ────────────────────────────────────────────────────────────────────
# cmake/fuzzing_build.cmake links $ENV{LIB_FUZZING_ENGINE} into each fuzzer when OSS_FUZZ is detected.
# -fsanitize=fuzzer-no-link is already in CMAKE_CXX_FLAGS above so the BT.CPP library code is
# instrumented for sancov edge coverage.
export LIB_FUZZING_ENGINE="-fsanitize=fuzzer"
BUILD_FUZZ="$SRC/mayhem-build-fuzz"
rm -rf "$BUILD_FUZZ"; mkdir -p "$BUILD_FUZZ"
( cd "$BUILD_FUZZ" && cmake "$SRC" "${CMAKE_COMMON[@]}" )
make -C "$BUILD_FUZZ" -j"$MAYHEM_JOBS" $FUZZERS
for f in $FUZZERS; do
  cp "$BUILD_FUZZ/$f" "/mayhem/$f"
  echo "built libFuzzer target /mayhem/$f"
done

# ── pass 2: standalone reproducers ───────────────────────────────────────────────────────────────
# Compile the run-once standalone main (C) as an object, then re-link the SAME harnesses against it
# by pointing LIB_FUZZING_ENGINE at the object instead of libFuzzer.
SA_OBJ="$SRC/mayhem-standalone-main.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SA_OBJ"
export LIB_FUZZING_ENGINE="$SA_OBJ"
BUILD_SA="$SRC/mayhem-build-standalone"
rm -rf "$BUILD_SA"; mkdir -p "$BUILD_SA"
( cd "$BUILD_SA" && cmake "$SRC" "${CMAKE_COMMON[@]}" )
make -C "$BUILD_SA" -j"$MAYHEM_JOBS" $FUZZERS
for f in $FUZZERS; do
  cp "$BUILD_SA/$f" "/mayhem/$f-standalone"
  echo "built standalone reproducer /mayhem/$f-standalone"
done

# ── test suite: build BT.CPP's own gtest suite with NORMAL flags (no sanitizers) so test.sh is an
#    honest PATCH oracle and only RUNS the pre-built suite. Separate tree. ─────────────────────────
BUILD_TESTS="$SRC/mayhem-tests"
rm -rf "$BUILD_TESTS"; mkdir -p "$BUILD_TESTS"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake -S "$SRC" -B "$BUILD_TESTS" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=ON \
    -DBTCPP_EXAMPLES=OFF \
    -DBTCPP_BUILD_TOOLS=OFF \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_CXX_FLAGS="-std=c++17 -stdlib=libstdc++"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake --build "$BUILD_TESTS" -j"$MAYHEM_JOBS"
echo "built BT.CPP gtest suite in mayhem-tests/"

echo "build.sh complete:"
ls -la /mayhem/bt_fuzzer /mayhem/script_fuzzer /mayhem/bb_fuzzer \
       /mayhem/bt_fuzzer-standalone /mayhem/script_fuzzer-standalone /mayhem/bb_fuzzer-standalone 2>&1 || true
