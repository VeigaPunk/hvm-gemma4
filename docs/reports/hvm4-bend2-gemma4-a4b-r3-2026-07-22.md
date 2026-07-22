# HVM4-Bend2 Gemma4 A4B Round-3 Protocol Evidence (Round-1 to Round-3)
**Date:** 2026-07-22
**Primary axis for this pass:** `auditability + documentation`

## Scope / axes
- Auditability of claim provenance (sealed source-map/judge/synthesis, mailbox, command evidence).
- Documentation/runtime contract consistency (README, examples/manifest/ROUTES, launcher defaults).

## Roster and model lanes
- **PEER ROSTER** (task explicit): `the-judge, the-planner, scout, reviewer, labrat, executor, connector, critic, sentinel, the-revenger, simplifier, scribe, mutation-tester, distiller`.
- **Round-1 lanes** (from `docs/reports/gemma-hvm-tuning-r1...`): model lanes `gemma4:e4b`, `12b`, `26b`, `gemma4-hvm:official-q4`; request/runtime knobs as listed in R1 report; lifecycle/request mutation probes.
- **Round-2 lanes** (`docs/reports/gemma-hvm-tuning-r2...`): model/setting lanes in `analysis/tuning/official-*.jsonl` plus direct-Ollama concurrency lanes `p1-f16`, `p4-q8`, `p8-q8` and HVM-route calibration/heldout sweeps.
- **Round-3 lanes** (`docs/reports/gemma-hvm-tuning-r3...`, `analysis/tuning/round3-*.jsonl`): selected-default mutation gap, false-success sentinel gating, proxy default/auth parity, benchmark-ceiling claims.

## Planner result (captured)
- `analysis/tuning/round3-synthesis.jsonl` contains **4 moves** (`R3-M01..R3-M04`) and canonical source-map reveal.
- `analysis/tuning/.round3-source-map.sealed.json` and matching judge hash: `sha256:f6cbad3dcf3d7305fd2cbfc20b9d26cf64112d15ab065671332a001fd665d5f3`.
- `analysis/tuning/round3-judge.jsonl`: evidence audit `with=4, without=0, dropped=0, spoof_flagged=0`; verdicts retain/safe, with no universal-best claim.
- Planner role/model lanes: `mutation-tester/xask-spark/codex` (R3-M01), `reviewer/xask-gpt55-low/codex` (R3-M02), `connector/xask-spark/codex` (R3-M03), `cross-source synthesis` (R3-M04).

## Mailbox JSONL captures
- Capture file: `.xbreed/mailbox/events.ndjson` (7 total events).
- Relevant entries:
  - `distiller-r2` evidence bundle (lane accounting + explicit aborted lanes/survivors/drops).
  - `connector-r3` mandatory coherence failures: model-contract mismatch, canonical default drift, identity-binding gap.
  - `scribe-r3` protocol report finding written via command below.
- **Written now:** `xbreed team mailbox write --from=scribe-r3 --kind=finding --payload='{"task":"round3_protocol_report","round":"3","axis":"auditability+documentation","report":"/home/arara/hvm-gemma4/docs/reports/hvm4-bend2-gemma4-a4b-r3-2026-07-22.md","status":"draft_evidence_only"}'`

## Runtime compatibility scope (explicit)
- **HVM-route path:** `run.sh` + `hvm_gemma.c` with `HVM_GEMMA_*` env, producing `mode:"runtime"` evidence traces in `analysis/tuning/*.jsonl`.
- **Direct-Ollama path:** benchmark concurrency scripts call raw `/api/generate` on `11434` (scope explicitly called out in R2 report); considered route-orthogonal to HVM bridge.
- **Proxy path:** `proxy/src/server.ts` route is `/v1/responses`; auth/defaults now set to `gemma4-hvm:official-q4` there, but cross-file docs/proxy/readme/defaults remain inconsistent (connector findings).
- Scope caveat: no fully orthogonal/provenance-tight benchmark proving claims across all three runtime paths in this round.

## Exact command/evidence log (Round-1..3)
- `bash tests/transport_lifecycle_mutations.sh` → R2/R3 evidence `pass=27/27` (from `round3` and prior reports).
- `bash tests/generation_option_request_oracle.sh` → `21/21` passing assertions.
- `bash tests/benchmark_manifest.sh` → `BENCHMARK_MANIFEST_OK`, `count=6` for this scope.
- `cd proxy && npm run typecheck` → pass.
- `make check` → pass (R3 report).
- `python` one-liner over `.xbreed/mailbox/events.ndjson` confirms event inventory (`total 7`).
- `git status --short` (current working-tree delta): modified production and test/docs files plus new untracked `hvm4/`, `benchmarks/hvm-1000-run/`, `benchmarks/hvm-metrics-proxy.ts`.

## Pareto survivors / drops
- **Survivors:**
  - R3-M01 selected-default mutation-sensitive serving defaults.
  - R3-M02 sentinel nonzero-failure path (HVM_GEMMA_ERROR gate).
  - R3-M03 proxy default/auth parity hardening.
  - R3-M04 benchmark-ceiling framing (retain claims only where evidenced).
- **Drops / holds:**
  - R1 latency cold/warm inference claim (spoof-flagged/withdrawn).
  - Universal quality/throughput/route-overhead winner not retained.
  - Exact GGUF digest binding as runtime-enforced kill still unresolved.

## Aborted lanes
- As explicitly recorded in `analysis/tuning/r2-scribe.jsonl` via `distiller-r2` payload: **2 aborted lanes** (`executor duplicate lane`, `mutation-tester`).
- Current report also withholds any unverified direct proxy-runtime semantic claims.

## Current verification state
- Evidence-backed audit surface is largely source-test + artifact-backed; several contract/documentation mismatches remain open and uncorrected.
- **Do not claim completion**: cross-file default coherence and identity-binding gaps persist in docs/README/proxy/launcher consistency, and benchmark quality semantics are still route/oracle-limited.
- This file is evidence-only and should be treated as draft protocol trace, not a release-ready closure.

## Final Round 4 (Audit Trail)
- **Actual final diffs since Round-3 evidence snapshot:**
  - Tracked files changed in this final pass: `benchmarks/manifest.json`, `benchmarks/run.sh`, `hvm_gemma.c`, `proxy/run-proxy.sh`, `proxy/src/server.ts`, `tests/benchmark_runner_mutations.sh`, `tests/generation_option_mutations.sh`, `tests/generation_option_request_oracle.sh`, `tests/semantic_runner_mutant_catalog.sh`, `tuned.env`, `benchmarks/measure-1000-hvm.sh`, `benchmarks/hvm-metrics-proxy.ts`.
  - `.xbreed/mailbox/events.ndjson` is untracked evidence capture (mailbox trail extension).
  - `git diff --stat` on the tracked files is `173 insertions(+), 100 deletions(-)` across 10 files.
- **Verification commands executed (this final round):**
  - `cd proxy && npm run typecheck` → **pass** (exit 0).
  - `bash tests/run_hvm4_request_shape.sh` → **pass=13 fail=0**.
  - `bash tests/transport_lifecycle_mutations.sh` → **pass=27 fail=0**.
  - `bash tests/generation_option_request_oracle.sh` → **pass=21 fail=0**.
  - `bash tests/benchmark_manifest.sh` → `BENCHMARK_MANIFEST_OK count=24 hash=...`
  - `bash tests/generation_option_mutations.sh` → **pass=18 fail=0** (all mutations currently survived).
  - `bash tests/benchmark_runner_mutations.sh` → **pass=16 fail=0**.
  - `bash tests/semantic_runner_mutant_catalog.sh` → **no diff output** (empty file changed in round marker only).
  - `bash check-hvm4-provenance.sh` → **fail**: `HVM4_PROVENANCE_ERROR: source GGUF missing: /home/arara/.local/share/hvm-gemma4/models/google-gemma-4-26B-A4B-it-qat-q4_0/gemma-4-26B_q4_0-it.gguf`.
- **Mailbox capture (final):**
  - Command written: `xbreed team mailbox write --from=scribe-r4 --kind=finding --payload='{ "task": "hvm4-bend2-gemma4-a4b-final-round-4", "round": "4", "axis": "final_audit_trail", "report": "/home/arara/hvm-gemma4/docs/reports/hvm4-bend2-gemma4-a4b-r3-2026-07-22.md", "status": "final_round_audit" }'`
  - Captured entry in `.xbreed/mailbox/events.ndjson` from `scribe-r4` with `from=scribe-r4`, `event_type=finding`, `status=final_round_audit`.
- **End-to-end result (Round-4):**
  - `labrat-r4` live probe recorded `proxy` default-model path responding 200 on `/v1/responses`, `/v1/models` count=7, and 400 for invalid model; `responses` returned model `gemma4:26b-hvm4` with output `OK`.
  - Route/auth/shape/lifecycle checks are passing, but **not all final gates are closed** (see remaining limitations).
- **Remaining limitations (honest, open):**
  - `run_hvm4_request_shape.sh` TAP plan corrected by execution but still historically reported a plan mismatch history; current Round-4 evidence run emits 13 assertions.
  - **Canonical model contract is still split** across `run-hvm4.sh`, `proxy/run-proxy.sh`, `proxy/src/server.ts` (`DEFAULT_MODEL`), and docs/examples (connector r4 findings).
  - `check-hvm4-provenance.sh` fails in this environment due missing expected GGUF source path.
  - `generation_option_mutations.sh` and `benchmark_runner_mutations.sh` are mutation harnesses; they indicate potential probe/observability gaps rather than production-safe closure.
  - No universal performance/quality claims retained for Round-4; evidence remains route-scoped.
- **Honest Bend 0.2.38 / HVM4 scope statement:**
  - Scope covered is **runtime-path, startup/auth/lifecycle/proxy-call integrity** and test-harness signal correctness for Bend 0.2.38 + HVM4 integration.
  - Scope explicitly excludes claimed global benchmark dominance and excludes fully proven artifact binding of model tag→local GGUF→runtime digest; this remains open until provenance script is satisfied in the same environment.
