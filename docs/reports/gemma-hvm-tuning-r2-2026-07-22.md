# Round-2 Report: Gemma-HVM Tuning
**Date:** 2026-07-22

## Inputs
- Evidence: `analysis/tuning/round2-synthesis-rerun.jsonl`, `analysis/tuning/round2-judge-rerun.jsonl`, `tests/hvm_gemma_validation_evidence.jsonl`, current bounded test output, JSONL under `analysis/tuning/`, `git log --oneline d142bae..HEAD`, and working-tree status.

## Axes / Roster
- Axes: quality, latency, throughput, reliability, mutation sensitivity, benchmark validity.
- Roster: the-judge, distiller, scribe.

## Mutation & hardening summary
- **Request mutation**: current request oracle passes 21/21 groups, including six invalid-environment subcases; earlier evidence recorded 26 individual cases. Duplicate-key equivalence is classified rather than falsely counted as killed.
- **Lifecycle mutation**: current harness passes 25/25, including endpoint identity, TERM/INT, stubborn-child cleanup, prompt transport, and bounded readiness.
- **Harness**: manifest checks are sound for integrity/runability but do **not** validate semantic correctness; therefore quality rankings remain weak. (`analysis/tuning/round2-synthesis.jsonl move R2-M07`).

## Direct-Ollama vs HVM-route distinction
- **HVM-route traces**: all `analysis/tuning/*.jsonl` are direct runs through `run.sh`/HVM bridge with logged env (`HVM_GEMMA_*`) and response diagnostics (`mode":"runtime"`).
- **Direct-Ollama concurrency traces**: `tests/concurrency60.sh` and `benchmarks/concurrency/*` are direct API calls to `http://127.0.0.1:11434/api/generate` and **are route-orthogonal** to HVM logic.

## Exact measured config table

### Calibration (HVM-route)
| config | prompt | wall_time_ms |
|---|---|---:|
| official/np8 | cal-exact-format-01 | 10039.884 |
| official/np8 | cal-arith-01 | 837.023 |
| official/np8 | cal-code-01 | 947.018 |
| official/np16 | cal-exact-format-01 | 683.714 |
| official/np16 | cal-arith-01 | 670.310 |
| official/np16 | cal-code-01 | 917.655 |
| official/np32 | cal-exact-format-01 | 645.675 |
| official/np32 | cal-arith-01 | 655.467 |
| official/np32 | cal-code-01 | 959.953 |
| official/np64 | cal-exact-format-01 | 644.530 |
| official/np64 | cal-arith-01 | 633.211 |
| official/np64 | cal-code-01 | 980.519 |
| e4b/np32 | cal-exact-format-01 | 6699.329 |
| e4b/np32 | cal-arith-01 | 756.904 |
| e4b/np32 | cal-code-01 | 944.257 |
| 12b/np32 | cal-exact-format-01 | 7799.179 |
| 12b/np32 | cal-arith-01 | 721.016 |
| 12b/np32 | cal-code-01 | 1123.237 |
| 26b/np32 | cal-exact-format-01 | 12418.029 |
| 26b/np32 | cal-arith-01 | 870.507 |
| 26b/np32 | cal-code-01 | 1141.746 |

### Heldout (HVM-route)
| config | prompt | wall_time_ms |
|---|---|---:|
| official/np16 | hold-exact-format-01 | 735.306 |
| official/np16 | hold-arith-01 | 683.293 |
| official/np16 | hold-code-01 | 886.491 |
| official/np32 | hold-exact-format-01 | 694.152 |
| official/np32 | hold-arith-01 | 635.669 |
| official/np32 | hold-code-01 | 798.327 |

### Direct-Ollama (small batch)
| config | total/ok/fail | min | p50 | p90 | max |
|---|---:|---:|---:|---:|---:|
| p1-f16 | 8/8/0 | 660 | 1330 | 2181 | 2181 |
| p4-q8 | 8/8/0 | 981 | 1003 | 1412 | 1412 |
| p8-q8 | 8/8/0 | 1230 | 1264 | 1267 | 1267 |

### Concurrency scale (direct-Ollama, 60-way)
| config | ok | min | p50 | p90 | max |
|---|---:|---:|---:|---:|---:|
| p8-q8 | 60/60 | 8545 | 10855 | 13215 | 14436 |
| legacy high-parallel baseline (settings incompletely persisted) | 60/60 | 166157 | 174216 | 180980 | 182737 |

## Model-load confound note
- Early model comparisons were confounded by cache state: first-case latencies for e4b/12b/26b were inflated due cold model switches into Ollama; the official-q4 runs were already resident and started in-cache (e.g., first row 784/645/~634 ms in calibration traces). `analysis/tuning/gemma4-hvm_official-q4-np32`, `analysis/tuning/gemma4_e4b-np32`, `analysis/tuning/gemma4_12b-np32`, and `analysis/tuning/gemma4_26b-np32` show materially different `diagnostics.cache_state.before` model IDs; first-run latency deltas cannot be treated as steady-state for all rows.

## Provisional Pareto verdicts
- **Retain**: official-q4 default, 16 as concise frontier, 32 safer default; keep p4-q8 + p8-q8 dual-frontier framing; retain lifecycle and request hardening with a stale-evidence caveat.
- **Reject / avoid ranking**: do **not** claim quality superiority of official-q4 over `e4b/12b/26b` from this suite.
- **Block as evidence-limited**: strong model-quality ranking and single-configuration “best” claims until benchmark validity is strengthened (randomized order, exact-output validators, reproducible high-concurrency traces).

## Audit hash
- Initial hash `sha256:b738c3a166d5033bbb3aea32c51159406d99900b489df6dcbda6dfe17ac41657` was invalidated because its source-map bytes were not persisted.
- Valid rerun hash: `sha256:16e61c152c3d39fa9b174a79897a06de2b1b020052c090b5c319345b408a81f4` (reveal matched).

## Commit delta pending
- Implementation and benchmark-harness changes landed in intermediate commits through `6017480`; this round commit adds the selected serving defaults (`OLLAMA_NUM_PARALLEL=8`, `OLLAMA_KV_CACHE_TYPE=q8_0`), measured traces, corrected concurrency tooling, and this audit report.
