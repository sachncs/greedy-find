#!/usr/bin/env bash
# scripts/run_bench.sh — runs bench/sweep_bench, parses the JSON
# one-liner it emits, and compares the j_per_sec against
# benchmarks/baseline_*.json. Exits non-zero on a >5% drop.
#
# Usage:
#   bash scripts/run_bench.sh
#
# Override the baseline via GRD_BASELINE_JSON. The default file is
# benchmarks/baseline_m3pro.json. The 'machine' field is a hint;
# the script does not try to detect the host.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILD_DIR="${REPO_ROOT}/build"
BENCH="${BUILD_DIR}/sweep_bench"
BASELINE="${GRD_BASELINE_JSON:-${REPO_ROOT}/benchmarks/baseline_m3pro.json}"
REGRESSION_PCT="${REGRESSION_PCT:-5}"

if [[ ! -x "${BENCH}" ]]; then
  printf "[run_bench] sweep_bench not built; building it\n" >&2
  cmake --build "${BUILD_DIR}" --target sweep_bench >&2
fi

if [[ ! -f "${BASELINE}" ]]; then
  printf "[run_bench] baseline %s not found; nothing to gate against\n" \
         "${BASELINE}" >&2
  exit 1
fi

# Build dir holds greedy.metallib; the bench links against it.
TMP_OUT="$(mktemp -t grd-bench.XXXXXX)"
trap 'rm -f "${TMP_OUT}"' EXIT

# Run the bench and capture both stdout (the JSON line is at the
# end) and stderr. The bench prints many lines, so we filter for
# the JSON one.
"${BENCH}" >"${TMP_OUT}" 2>&1 || true

json_line="$(grep -E '^\{"bench":' "${TMP_OUT}" | tail -n1 || true)"
if [[ -z "${json_line}" ]]; then
  printf "[run_bench] bench did not emit a JSON line\n" >&2
  cat "${TMP_OUT}" >&2
  exit 1
fi

# Parse the j_per_sec out of both files. We do this with python3
# (always present on macOS) to avoid pulling in jq.
measure() {
  python3 -c "
import json,sys
d = json.loads(sys.argv[1])
print(int(d['j_per_sec']))
" "$1"
}

baseline_jps="$(measure "$(cat "${BASELINE}")")"
current_jps="$(measure "${json_line}")"

# Regression: current must be >= baseline * (1 - REGRESSION_PCT/100).
threshold="$(python3 -c "
b = int('${baseline_jps}')
p = int('${REGRESSION_PCT}')
print(int(b * (100 - p) / 100))
")"

printf "[run_bench] baseline j/sec = %s, current = %s, threshold = %s " \
       "${baseline_jps}" "${current_jps}" "${threshold}"

if (( current_jps < threshold )); then
  printf "(REGRESSION)\n" >&2
  exit 1
fi
printf "(ok)\n"
