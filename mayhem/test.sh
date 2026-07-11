#!/usr/bin/env bash
#
# behaviortreecpp/mayhem/test.sh — RUN BehaviorTree.CPP's own gtest suite (built by mayhem/build.sh
# with normal flags) and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: BT.CPP's gtest suite is a real behavioral test suite — gtest_factory /
# gtest_blackboard / gtest_ports / gtest_sequence / … construct trees, tick them, and ASSERT node
# statuses, blackboard values, port types and parser results (EXPECT_EQ / ASSERT_THROW / golden
# values). A no-op or `exit(0)` patch — or any change to the parser/scripting/blackboard semantics —
# breaks these assertions, so "ran without crashing" is NOT enough to pass. This script only RUNS the
# pre-built `behaviortree_cpp_test` binary directly (gtest), parsing its PASSED/FAILED tally; it never
# compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

BUILDDIR="$SRC/mayhem-tests"
TEST_BIN="$BUILDDIR/tests/behaviortree_cpp_test"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$TEST_BIN" ]; then
  echo "missing test binary $TEST_BIN — run mayhem/build.sh first" >&2
  emit_ctrf "gtest" 0 1 0; exit 2
fi

echo "=== running $TEST_BIN ==="
out="$("$TEST_BIN" 2>&1)"; rc=$?
echo "$out"

# gtest prints a final summary:  [  PASSED  ] N tests.   and (on failure)  [  FAILED  ] M tests, ...
PASSED=$(printf '%s\n' "$out" | sed -n 's/.*\[  PASSED  \] \([0-9][0-9]*\) test.*/\1/p' | tail -1)
FAILED=$(printf '%s\n' "$out" | sed -n 's/.*\[  FAILED  \] \([0-9][0-9]*\) test.*/\1/p' | tail -1)
: "${PASSED:=0}" "${FAILED:=0}"

# If gtest produced no parseable summary, fall back to the binary's exit code.
if [ "$(( PASSED + FAILED ))" -eq 0 ]; then
  echo "could not parse gtest summary; using exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "gtest" 1 0 0; exit 0; }
  emit_ctrf "gtest" 0 1 0; exit 1
fi

emit_ctrf "gtest" "$PASSED" "$FAILED" 0
