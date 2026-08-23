#!/usr/bin/env bash
# scripts/reliability.sh — black-box end-to-end correctness test.
#
# For each test case, computes the compressed pubkey for a known private
# scalar d using tools/gen_pubkey, then runs ./build/greedyfind over a
# range that contains d, and asserts that the tool emits a match line
# referencing d. Exits non-zero on the first failure.
#
# Usage:
#   bash scripts/reliability.sh                  # fast default cases
#   RELIABILITY_SLOW=1 bash scripts/reliability.sh   # add puzzle-size cases
#
# Env:
#   RELIABILITY_SLOW=1   include cases in the 2^70 magnitude range
#                        (these take seconds-to-minutes depending on GPU)
#   GRD_BIN             override greedyfind path (default ./build/greedyfind)
#   GEN_PUBKEY_BIN      override gen_pubkey path  (default ./build/gen_pubkey)
#   KEEP_OUTPUT=1       do not delete per-case --output-dir on success

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILD_DIR="${REPO_ROOT}/build"
GRD="${GRD_BIN:-${BUILD_DIR}/greedyfind}"
GEN="${GEN_PUBKEY_BIN:-${BUILD_DIR}/gen_pubkey}"
OUT_ROOT="${REPO_ROOT}/reliability-out"

if [[ ! -x "${GRD}" ]]; then
  printf "[reliability] greedyfind not built at %s; abort\n" "${GRD}" >&2
  exit 1
fi
if [[ ! -x "${GEN}" ]]; then
  printf "[reliability] gen_pubkey not built at %s; abort\n" "${GEN}" >&2
  exit 1
fi

# --- test matrix -------------------------------------------------------------
# Each row: "d  from  to  description"
# d is a known private scalar; [from, to) is the sweep range; the test
# passes iff greedyfind emits a match line that names d.
#
# d = 1 is intentionally NOT in the matrix. The pubkey-mode variant
# table contains no V=0, so the algorithm cannot recover d = 1 via
# x(j·G) == x(d·G - V·G) for any j in a small range; only d >= 2
# is reachable. The smallest recoverable scalar is d = 2 (j=0, V=2).
#
# The SLOW case exercises the u128 range path with a 1000-j band at
# 2^70 (the puzzle #71 reference range), wide enough to prove the
# u128 range encoding works but narrow enough to keep wall time
# bounded.

DEFAULT_CASES=(
  "2               0           16                  smoke (d=2, [0,16))"
  "2               0           4096                small range loop"
  "4095            0           4096                upper edge (to-1)"
  "100000          0           1000001             mid-range, 100k in 1M"
  "8675309         0           10000000            random-ish middle"
  "4294967313      4294967296  4294968320          2^32+17, narrow band"
)

SLOW_CASES=(
  "1180591620717411303424  1180591620717411303424  1180591620717411304424  2^70+12345, 1000-j narrow band"
)

# --- runner -----------------------------------------------------------------

pass=0
fail=0
failed_names=()

run_case() {
  local d="$1"
  local from="$2"
  local to="$3"
  local desc="$4"
  local case_name="d=${d}_[${from},${to})"

  printf "[reliability] %-50s " "${case_name}"
  local pubkey
  if ! pubkey="$("${GEN}" "${d}" 2>/dev/null)"; then
    printf "FAIL (gen_pubkey error)\n"
    fail=$((fail + 1))
    failed_names+=("${case_name}: gen_pubkey failed for d=${d}")
    return
  fi
  if [[ ! "${pubkey}" =~ ^[0-9a-fA-F]{66}$ ]]; then
    printf "FAIL (bad pubkey hex)\n"
    fail=$((fail + 1))
    failed_names+=("${case_name}: bad pubkey hex from gen_pubkey")
    return
  fi

  local case_out="${OUT_ROOT}/$(echo "${case_name}" | tr -c '[:alnum:]_.-' '_')"
  mkdir -p "${case_out}"

  local t0
  t0="$(date +%s)"
  local grd_out
  if ! grd_out="$("${GRD}" \
        --pubkey "${pubkey}" \
        --from "${from}" \
        --to "${to}" \
        --output-dir "${case_out}" 2>&1)"; then
    printf "FAIL (greedyfind exited non-zero)\n"
    printf "%s\n" "${grd_out}" >&2
    fail=$((fail + 1))
    failed_names+=("${case_name}: greedyfind exit != 0")
    return
  fi
  local t1
  t1="$(date +%s)"
  local elapsed=$((t1 - t0))

  # Match-line format: see cli.md and examples/run.sh. The tool emits one
  # of "MATCH j=<d>" / "MATCH ... privkey=<d>" / "j=<d>" depending on the
  # variant-offset path it took. Anchor on the bare decimal d with a word
  # boundary so d=1 cannot match d=10.
  if grep -qE "MATCH[[:space:]].*j=${d}\\b|privkey=${d}\\b|j=${d}\\b" \
        <<<"${grd_out}"; then
    printf "PASS (%ds)\n" "${elapsed}"
    pass=$((pass + 1))
    if [[ "${KEEP_OUTPUT:-0}" != "1" ]]; then
      rm -rf "${case_out}"
    fi
  else
    printf "FAIL (no MATCH line for d=%s)\n" "${d}"
    printf "%s\n" "${grd_out}" >&2
    fail=$((fail + 1))
    failed_names+=("${case_name}: no MATCH line for d=${d}")
  fi
}

mkdir -p "${OUT_ROOT}"
trap 'rm -rf "${OUT_ROOT}"' EXIT

for row in "${DEFAULT_CASES[@]}"; do
  # shellcheck disable=SC2086
  run_case ${row}
done

if [[ "${RELIABILITY_SLOW:-0}" == "1" ]]; then
  for row in "${SLOW_CASES[@]}"; do
    # shellcheck disable=SC2086
    run_case ${row}
  done
fi

total=$((pass + fail))
printf "[reliability] %d/%d cases passed\n" "${pass}" "${total}"

if (( fail > 0 )); then
  printf "[reliability] failed cases:\n" >&2
  for name in "${failed_names[@]}"; do
    printf "  - %s\n" "${name}" >&2
  done
  exit 1
fi
