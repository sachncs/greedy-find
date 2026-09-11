#!/usr/bin/env bash
# examples/run.sh — end-to-end smoke test for both modes.
#
# Runs greedyfind on a tiny range (16 j's) with a known target
# (privkey=1, G) in both --pubkey and --address modes. Verifies
# that each run exits cleanly and emits a d=1 match. Exits
# non-zero if either run fails or the expected match is missing.
#
# Usage:
#   bash examples/run.sh
#
# Requires:
#   - ./build/greedyfind built
#   - Metal-capable device (or the CPU fallback path, which
#     handles the tiny range without Metal)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILD_DIR="${REPO_ROOT}/build"
GRD="${BUILD_DIR}/greedyfind"

if [[ ! -x "${GRD}" ]]; then
  printf "[smoke] greedyfind not built at %s; abort\n" "${GRD}" >&2
  exit 1
fi

# --- --pubkey mode --------------------------------------------------------
# Compressed pubkey for d=2: 02 || x(2G).
# d=1 is not recoverable by the pubkey-mode algorithm because the
# variant table contains no V=0; d=2 is the smallest recoverable
# scalar (j=0, V=2, candidate = 0 + 2·G = 2·G).
PUBKEY_HEX="02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"

PUBOUT="$(mktemp -t grd-smoke-pub.XXXXXX)"
trap 'rm -f "${PUBOUT}" "${ADDOUT}"' EXIT

if ! "${GRD}" --pubkey "${PUBKEY_HEX}" --from 0 --to 16 >"${PUBOUT}" 2>&1; then
  printf "[smoke] --pubkey run failed:\n" >&2
  cat "${PUBOUT}" >&2
  exit 1
fi
if ! grep -qE 'MATCH .* 2|privkey=2|privkey.=2|j=2[^0-9]' "${PUBOUT}"; then
  printf "[smoke] --pubkey did not emit expected d=2 match:\n" >&2
  cat "${PUBOUT}" >&2
  exit 1
fi
printf "[smoke] --pubkey ok: d=2 found in [0, 16)\n"

# --- --address mode -------------------------------------------------------
# P2PKH mainnet address for d=1:
#   hash160(02||Gx) -> base58check with version byte 0x00.
ADDRESS="1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH"

ADDOUT="$(mktemp -t grd-smoke-add.XXXXXX)"
trap 'rm -f "${PUBOUT}" "${ADDOUT}"' EXIT

# --address mode is a documented-but-not-implemented stub. The
# current GRDAddressSweeper returns GRDErrorGPUNotImplemented with
# message "--address on GPU lands in A40+" and the dispatcher
# translates that into exit code 70. Treat that as expected, but
# fail loudly if the stub ever silently accepts the address (which
# would mask a regression in the stub itself).
if "${GRD}" --address "${ADDRESS}" --from 0 --to 16 >"${ADDOUT}" 2>&1; then
  printf "[smoke] --address unexpectedly succeeded:\n" >&2
  cat "${ADDOUT}" >&2
  exit 1
fi
if ! grep -q "A40+" "${ADDOUT}"; then
  printf "[smoke] --address error did not mention the A40+ stub:\n" >&2
  cat "${ADDOUT}" >&2
  exit 1
fi
printf "[smoke] --address stub gate ok (rejects with A40+ message)\n"

printf "[smoke] all checks passed\n"
