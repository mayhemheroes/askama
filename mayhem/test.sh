#!/usr/bin/env bash
#
# askama/mayhem/test.sh — RUN askama-rs/askama's own test suite (`cargo test`) and emit a CTRF
# summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: askama ships an extensive assertion-based suite. The `testing` workspace crate
# (testing/tests/*.rs) compiles real templates and asserts BYTE-EXACT rendered output via
# assert_eq!/assert_matches! (variables, control flow, filters, blocks, matches, inheritance, …),
# and every library crate (askama, askama_parser, askama_derive, askama_escape, askama_macros) has
# in-crate unit tests that assert concrete parse/escape/render results. A no-op / "exit(0)" /
# output-altering patch CANNOT pass — the rendered strings would no longer match. This script only
# RUNS the suite via `cargo test`; it never builds fuzz targets.
#
# We run with the crate's NORMAL flags (default feature resolution) — no sanitizer RUSTFLAGS — to
# keep the oracle honest and fast. --workspace runs every crate's tests.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

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

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

echo "=== running cargo test (askama workspace, default features) ==="
# Use the image's DEFAULT toolchain (the Dockerfile pins it to the same nightly the fuzz build uses),
# so no `+toolchain` override — that would make rustup try to install a different channel into the
# read-only shared /opt/rust. --no-fail-fast so we count every test; RUSTFLAGS cleared so it inherits
# nothing from the sanitizer build. --workspace runs every crate's tests.
out="$(RUSTFLAGS="" cargo test --workspace --no-fail-fast --jobs "$MAYHEM_JOBS" 2>&1)"; rc=$?
echo "$out"

# libtest prints one line per test binary:
#   test result: ok. 12 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; ...
# Sum across all binaries.
PASSED=0; FAILED=0; IGNORED=0
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
done < <(printf '%s\n' "$out" \
  | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')

# If we parsed no result lines, fall back to the cargo exit code (e.g. compile error).
if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
  echo "could not parse any 'test result:' lines; using cargo exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "cargo-test" 1 0 0; exit 0; }
  emit_ctrf "cargo-test" 0 1 0; exit 1
fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"
