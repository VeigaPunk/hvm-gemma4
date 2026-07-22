# Round-1 Report: Gemma-HVM Tuning
**Date:** 2026-07-22

## Axes / Roster / Xask / Wall-time
- Axes: quality, latency, resource, reliability (maximize/minimize per planner).
- Roster: the-planner, the-judge, scout, reviewer, labrat, connector, critic, sentinel, mutation-tester, distiller, executor, scribe.
- Xask targets: model (`gemma4:e4b`, `12b`, `26b`, `gemma4-hvm:official-q4`), request knobs (`num_ctx`, `num_predict`, `temperature`, `seed`, `top_k`, `top_p`, `min_p`, `repeat_penalty`), runtime flags (`OLLAMA_FLASH_ATTENTION`, `OLLAMA_KV_CACHE_TYPE`, `OLLAMA_NUM_PARALLEL`, keep-alive/cache, placement), build knobs.
- Persisted wall-time observed: cold=11300.944 ms; warm=40836.344/40038.898/39723.938 ms (from `baseline_gemma4_hvm_probe.jsonl`).

## Per-move claim / evidence / confidence
- **R1-control**: claim—single authoritative request layer + log effective JSON. evidence—duplicate knob defaults in `hvm_gemma.c` and `Modelfile.official`; baseline hard-codes options. confidence: strong.
- **R1-mut-survivors**: claim—mutation sensitivity baseline: all 18 generation-option mutants survive compile-only oracle. evidence—`analysis/generation_option_mutation_finding.jsonl`, `analysis/generation_option_mutations.md`. confidence: certain (survival), strong (expected-kill proposals).
- **R1-lifecycle**: claim—reliability defects (M08, M09, M16). evidence—`tests/TRANSPORT_LIFECYCLE_MUTATIONS.md`, script states. confidence: certain, verdict blocking-fix.
- **R1-exit-boundary**: claim—loader/runtime fault may be misclassified. evidence—M18 shows missing dylib but command returned 0+IO/Done; M10 nonzero Bend propagates. confidence: certain.
- **R1-latency-conflict**: claim—cold/warm inference blocked. evidence—4-row JSONL persisted; warm probe slower, outputs differ, exactness=1 but snippet not literal `pong`. confidence: certain on files, low on inference.
- **R1-design**: claim—prompt-cluster validity control needed. evidence—deterministic prompt/repeat settings (`temperature=0`, `seed=42`) not independent samples. confidence: strong.
- **R1-rejected**: claim—reject first-step concurrency (`OLLAMA_NUM_PARALLEL>1`). evidence—`OLLAMA_NUM_PARALLEL=1` removes contention, alters scope. confidence: strong.

## Conflicts
1) Mailbox latency narrative conflicts with persisted JSONL: persisted cold is slower than warm (opposite).
2) Persisted rows are non-comparable: cold `eval_count=703`, warm `1739`; output lengths differ substantially.
3) `exactness=1` conflicts with snippets (`Ping! 🏓`, `**Ping!** 🏓`); exact-oracle mismatch.
4) `eval_count` exceeds fixed `num_predict=256`; provenance/count semantics uncertain.

## Mutation results (observed vs proposed)
- Observed: generation mutation campaign 18/18 compile-survived; transport lifecycle mutations observed defects in M08, M09, M16, M18; script passed 16/16.
- Proposed (not observed): intercepted-request AST key/type/value assertions, bounded API rejection tests, duplicate-key checks, ASan/LSan ownership/early-return injection.

## Provisional Pareto verdicts
- Retain: R1-control, R1-mut-survivors, R1-design, R1-rejected
- Retain+blocking-fix: R1-lifecycle, R1-exit-boundary
- Block original inference only: R1-latency-conflict

## Spoof flag
- `R1-latency-conflict`: spoof_flagged/blocked.

## audit_hash
- `fca93e2a46d0a99830ce76a99dfbcf5a29adcd63fca8eb0063301724f38455e2`

## Optimization routes surveyed
- Confirmed surfaces from evidence: model/request/runtime/build knobs and their conflicts; cold/warm and keep-alive/state confounds were included.

## Commit delta pending
- No tracked code change applied in this step. Untracked experiment artifacts present: `.xbreed/`, `analysis/`, `tests/`, `baseline_gemma4_hvm_probe.jsonl`, `KNOBS.md`, `registry/`.
