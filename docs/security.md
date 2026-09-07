# security.md — threat model and research-only disclaimer

> **Educational and research use only.** See
> [`DISCLAIMER.md`](../DISCLAIMER.md) at the repository root.

## 1. Threat model

`greedyfind` is a search tool, not a wallet. The threat model
mirrors the [`find`](https://github.com/sachncs/find) crate's:

| Property | Status |
|---|---|
| Constant-time EC ops | No — inner loop is data-dependent on the search input |
| Side-channel resistant | No — Metal kernel timing is observable |
| Suitable for signing-key recovery | No |
| Suitable for academic / puzzle search | Yes |
| Suitable for adversarial / unknown-target search | No |

The search is purely public: the operator knows the public
target, the public range, and is looking for a private key.
There is no secret input that crosses a trust boundary.

## 2. What this tool can do

- Search a public range `[from, to)` for a private key whose
  associated pubkey or address matches a target.
- Persist the next-j position to a checkpoint file that
  survives crash / SIGTERM.
- Reuse precomputed X-coordinates from the `find` crate's
  cache (and vice versa) via the byte-compatible `FIND-CAC`
  format.

## 3. What this tool cannot do

- Recover a private key from a signer's wallet. The tool has
  no signing primitives and never will.
- Operate without the explicit `--from` and `--to` range
  bounds. There is no "scan the whole keyspace" mode.
- Search a keyspace that the operator does not have a public
  reason to search. The 2^256 keyspace is not addressable;
  this tool is for sweeps over a known, bounded range.
- Provide any guarantee about side-channel resistance. The
  Metal kernel's timing reflects the search input.

## 4. Specific risks

### 4.1 Misuse against live wallets

This tool can, in principle, be used to search for a private
key belonging to a Bitcoin address. The repository authors
do not condone this use. The `--address` and `--pubkey`
modes are present to support:

- **Public puzzles** (e.g. Bitcoin Puzzle #N, where the
  address is published and a reward is offered).
- **Cryptographic research** (e.g. studying range-splitting
  performance on Apple Silicon).
- **Recovery of a key the operator has legitimately lost**,
  with appropriate jurisdiction and proof-of-ownership.

Use outside these contexts is at the operator's risk and may
violate computer-misuse statutes in your jurisdiction.

### 4.2 Telemetry leaks

The NDJSON telemetry file (`events.ndjson`) records the
target descriptor, the from/to range, and the throughput.
This is information about the search, not the result: a
match's j-value is not in the telemetry. Still, treat the
output directory as sensitive: it tells an observer what you
were searching for and how aggressively.

### 4.3 Checkpoint integrity

The checkpoint file is integrity-checked (SHA-256) on load,
but a tampered checkpoint is rejected with an error — not
silently re-derived. A crash mid-write is safe (the temp
file is atomically renamed) but a maliciously modified
checkpoint file will halt the run. This is the intended
behaviour.

## 5. Reporting security issues

The repository has no public security-contact address. For
research-related questions, file an issue on the upstream
`find` crate or contact the author through the channels
listed in the repository metadata.

## 6. License and warranty

`greedyfind` is MIT-licensed. See [`LICENSE-MIT`](../LICENSE-MIT).
There is no warranty of any kind. The authors are not liable
for any damages arising from the use or misuse of this tool.
