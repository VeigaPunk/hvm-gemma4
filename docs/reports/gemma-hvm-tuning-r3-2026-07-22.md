# Round-3 Report: Gemma-HVM Tuning
**Date:** 2026-07-22

## Inputs
- `analysis/tuning/round3-synthesis.jsonl`
- `analysis/tuning/round3-judge.jsonl`
- Current git diff in:
  - `proxy/run-proxy.sh`
  - `proxy/src/server.ts`
  - `run.sh`
  - `tests/transport_lifecycle_mutations.sh`
- Current tests today:
  - `bash tests/transport_lifecycle_mutations.sh`
  - `bash tests/generation_option_request_oracle.sh`
  - `make check`
  - `bash tests/benchmark_manifest.sh`
  - `bash tests/concurrency60.sh` *(no new run this round)*
  - `cd proxy && npm run typecheck`

## Round-3 roster
- the-judge, mutation-tester, connector, reviewer, distiller, scribe

## Rounds evidence summary
- **Lifecycle assertions:** `27/27` currently passing.
- **Request-group oracle:** `21/21` groups passing.
- **Audit hash:** `sha256:f6cbad3dcf3d7305fd2cbfc20b9d26cf64112d15ab065671332a001fd665d5f3`
- **Source-map status:** sealed (`analysis/tuning/.round3-source-map.sealed.json`)

## Blocker closures
- **M01 (selected-default lifecycle gap):** CLOSED (`R3-M01`)
  - Owned-Ollama startup now explicitly sets `OLLAMA_KV_CACHE_TYPE=q8_0`, `OLLAMA_NUM_PARALLEL=8`, `OLLAMA_MAX_LOADED_MODELS=1` and mutation test added/updated to cover this.
- **M02 (false-success blocker):** CLOSED (`R3-M02`)
  - Sentinel-guarded errors in `run.sh` now map to nonzero launcher status; proxy strips stats and throws on `HVM_GEMMA_ERROR:`.
- **M03 (proxy auth/default parity):** CLOSED as hardening (`R3-M03`)
  - Defaults now unified to `gemma4-hvm:official-q4`; loopback requires no auth while non-loopback requires an explicit bearer and exact token match.

## Metrics and tests
- **Lifecycle suite:** `1..27`, `pass=27`, `fail=0`
- **Request oracle:** `1..21`, `pass=21`, `fail=0`
- **Build/typecheck:** `make check` passes; `cd proxy && npm run typecheck` passes.
- **Manifest smoke:** `BENCHMARK_MANIFEST_OK`, `count=6`, manifest hash `d54a6ec2bcff7a9a695f774480da9c4a46bcf26049e4ac5ce6b6016d43453afb`

## Pareto verdicts (Round-3)
- Keep `official-q4` as default candidate with explicit selected serving defaults.
- Keep false-success sentinel gating and proxy auth/model default hardening.
- Keep benchmark claim ceilings (no global best claim yet).
- Explicitly treat as **retain / no universal-best** on throughput/quality claims until route-orthogonal and semantic checks are upgraded.

## Explicit remaining benchmark ceiling
- No reproduced burst/HVM-route `xbreed` benchmark lift for `p16`/higher settings.
- No universal semantic quality ranking (output format/meaning validators absent from benchmark harness).
- No repeated, counterbalanced cold/warm ordering evidence for held-out latency ranking.
- No reproducible route-orthogonal concurrency comparison of proxy/auth changes.

## Commit delta pending
- Uncommitted production deltas (relative to `d664a2f` HEAD):
  - `proxy/run-proxy.sh`
  - `proxy/src/server.ts`
  - `run.sh`
  - `tests/transport_lifecycle_mutations.sh`
  - plus this report+scribe files when added by this task.
- Untracked: `.xbreed/` (ephemeral judge metadata).