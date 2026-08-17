#!/usr/bin/env bash
# scripts/record_baseline.sh — capture the current bench result as
# the new baseline. Writes benchmarks/baseline_m3pro.json (override
# via GRD_BASELINE_JSON).
#
# Usage:
#   GRD_BASELINE_JSON=path/to/file.json bash scripts/record_baseline.sh
#
# The bench's emitted JSON is captured verbatim into the baseline
# file, with only the 'date' field updated.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILD_DIR="${REPO_ROOT}/build"
BENCH="${BUILD_DIR}/sweep_bench"
BASELINE="${GRD_BASELINE_JSON:-${REPO_ROOT}/benchmarks/baseline_m3pro.json}"

if [[ ! -x "${BENCH}" ]]; then
  printf "[record] sweep_bench not built; building it\n" >&2
  cmake --build "${BUILD_DIR}" --target sweep_bench >&2
fi

TMP_OUT="$(mktemp -t grd-bench.XXXXXX)"
trap 'rm -f "${TMP_OUT}"' EXIT

"${BENCH}" >"${TMP_OUT}" 2>&1 || true
json_line="$(grep -E '^\{"bench":' "${TMP_OUT}" | tail -n1 || true)"
if [[ -z "${json_line}" ]]; then
  printf "[record] bench did not emit a JSON line\n" >&2
  cat "${TMP_OUT}" >&2
  exit 1
fi

date_str="$(date +%F)"
python3 - <<PY
import json
with open("${BASELINE}", "r") as f:
    base = json.load(f)
new = json.loads('''${json_line}''')
base.update(new)
base["date"] = "${date_str}"
with open("${BASELINE}", "w") as f:
    json.dump(base, f, indent=2)
    f.write("\n")
PY

printf "[record] wrote %s\n" "${BASELINE}"
