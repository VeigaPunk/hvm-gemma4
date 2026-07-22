# Gemma-HVM Tuning (xbgst2-r1) Report
**Date:** 2026-07-22

## Inputs
- `analysis/tuning/xbgst2-r1-synthesis.jsonl`
- `analysis/tuning/xbgst2-r1-judge.jsonl`
- Current diff in `benchmarks/manifest.json`, `tests/benchmark_manifest.sh`
- New mutation artifacts: `analysis/benchmark_runner_mutants.json`, `analysis/official_q4_configuration_mutant_map.jsonl`, `analysis/proxy_route_mutations.jsonl`
- New tests: `tests/benchmark_runner_mutations.sh`, `tests/proxy_route_mutations.sh`
- Executed tests: `bash tests/benchmark_manifest.sh`, `bash tests/benchmark_runner_mutations.sh`, `bash tests/generation_option_request_oracle.sh`, `bash tests/transport_lifecycle_mutations.sh`, `bash tests/proxy_route_mutations.sh`, `cd proxy && npm run typecheck`

## Axes
- semantic benchmark contract
- benchmark truthfulness
- configuration mutation frontier
- proxy route mutation frontier
- route/model confound
- experiment design
- selection + resource validity

## Roster / xask targets
- **12-lane roster:** the-planner, the-judge, scout, reviewer, labrat, connector, critic, sentinel, mutation-tester, distiller, executor, scribe
- **xask targets represented in synthesis evidence:** connector/simple/route/resource/critic/sentinel proposal artifacts (`/tmp/xbgst2-r1-*.jsonl`) and 7 synthesized moves (M01–M07).

## Current diff summary
- `benchmarks/manifest.json`: v1 → v2; prompt set expanded 6→24; 12 calibration + 12 heldout; executable-validator envelopes added; schema version 1.1 and strict hash/check fields.
- `tests/benchmark_manifest.sh`: added validator-shape enforcement for `.validator.kind` branches (`exact` with `expected`, `executable` with `language` + `script`).
- Untracked mutation artifacts added (see Inputs above) and new mutation harness scripts for benchmark-runner/proxy-route classes.

## 24-case manifest structural status
- `tests/benchmark_manifest.sh` result: `BENCHMARK_MANIFEST_OK`, `count=24`, `hash=ae063702180aa52a28d79b621d17aef9f0da97cd649b4962bafc4b10c1d04bcc`
- Structural checks passed: 12+12 split counts, unique IDs, non-empty prompts, non-overlapping calibration/heldout prompts, hash fidelity.
- **Runtime semantic execution remains absent in production benchmark runner (`benchmarks/run.sh`) for executable validators** (evidence in M01/M02).

## Mutation observed-vs-proposed (from synthesis)
- **Observed (executed / evidenced):**
  - M01: manifest schema-level contract held structurally valid.
  - M02: benchmark-runner mutation harness shows 16/16 crafted harness defects all **survive** current run semantics (designed as bad-oracle probes).
  - M03: official-q4 request-surface mutants split into current kills (request-source) and missing effective-runtime proposals (digest clamp/sample/cache/runtime-liveness).
  - M04: proxy-route mutant catalog currently reports 16 compile/survival cases.
  - M05–M07: route confound/design/resource proposals are design notes.
- **Proposed but not yet executed in this round:**
  - Runtime validator execution in `benchmarks/run.sh` (not just shape checks).
  - Deterministic digest/prompt equality and runner path hardening.
  - Effective-runtime probes for config mutations (runtime context clamp, token budgets, determinism, model unloading, keep-alive, KV type, parallelism).
  - Full proxy route semantic oracles (auth, schema, timeout, stats purity, route/model identity).
  - Counterbalanced cold/warm/one-factor-at-a-time resource experiment and sealed heldout selection pipeline.

## Test / mutation artifact status
- `bash tests/benchmark_runner_mutations.sh` → `16/16` assertions pass, `# pass=16 fail=0` (mutation classes: inversion, dropped failures, mislabels, cache/resource omission, order/sample reduction, digest edge cases).
- `bash tests/generation_option_request_oracle.sh` → `1..21`, `pass=21`, `fail=0`.
- `bash tests/transport_lifecycle_mutations.sh` → `1..27`, `pass=27`, `fail=0`.
- `bash tests/proxy_route_mutations.sh` → `1..16`, `# generated=16 failed=0` (all labeled `SURVIVED compile oracle`).
- `cd proxy && npm run typecheck` → pass.
- New artifacts captured:
  - `analysis/benchmark_runner_mutants.json` (16 benchmark runner mutant descriptions)
  - `analysis/official_q4_configuration_mutant_map.jsonl` (16 config mutants; 8 current-kill, 8 missing-kill proposals)
  - `analysis/proxy_route_mutations.jsonl` (16 proxy-route mutants; expected semantic-kill list + compile-only status)

## Audit hash
- `sha256:af32db1f56de61c5213a0eda3c1b300aa811c888946b5ac34cba2d78319afe49`
- `analysis/tuning/xbgst2-r1-judge.jsonl`: `with=7`, `without=0`, `dropped=0`, `spoof_flagged=0`

## Pareto verdicts (provisional)
- **Retain / safe:** manifest structural expansion to 24-case split and validator schema hardening.
- **Retain w/ blocking:** benchmark truthfulness claims; no quality/latency Pareto claims until production `run.sh` executes exact validators and semantic config/route/oracle checks.
- **Retain as proposed frontier:** configuration/proxy/model confound handling in proposal-only state (no kills yet, high-value next work).
- **Do not claim:** direct universal Pareto winner across quality/latency/throughput for this round.

## Next execution batch
1) Implement harness truthfulness in `benchmarks/run.sh`: execute executable validators, capture failures distinctly from cache/digest fetch errors, persist runner/route/digest metadata, and separate route-path selection logs.
2) Add and run route+sentinel semantic tests for all 16 proxy-route mutants (instead of compile-only).
3) Add effective-runtime probes for 8 config survivors (C02,C04,C06,C08,C10,C12,C14,C16), then rerun mutation summaries.
4) Run sealed heldout calibration/selection pipeline with explicit model-digest pinning and compare top-2 runners-up on shared prompt batches.

## Production edit policy
- No production files edited in this task; only report + scribe artifacts were added.