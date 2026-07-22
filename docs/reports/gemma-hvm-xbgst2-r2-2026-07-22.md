# Gemma-HVM xbgst2 Round-2 Report
**Date:** 2026-07-22

## Inputs
- `analysis/tuning/xbgst2-r2-synthesis.jsonl` (sealed)
- `analysis/tuning/xbgst2-r2-judge.jsonl` (sealed)

## Scope
Round-2 review/synthesis for xbgst2: benchmark truthfulness + runtime/model-route validity across benchmark and proxy layers.

## Audit summary
- **Audit hash:** `sha256:554d40fb7f34fc995c5ac0e1e40967ffea51fdd3d2f259eb053c97f3d8cbbf9b`
- Evidence audit: `with=5`, `without=0`, `dropped=0`, `spoof_flagged=0`
- Source map sealed at `analysis/tuning/.xbgst2-r2-source-map.sealed.json`

## Canonical source-map reveal
```json
[{"move_id":"X2R2-M01","source_prefix":"reviewer+rollback-verification"},{"move_id":"X2R2-M02","source_prefix":"reviewer+semantic-contract"},{"move_id":"X2R2-M03","source_prefix":"mutation-runtime"},{"move_id":"X2R2-M04","source_prefix":"connector"},{"move_id":"X2R2-M05","source_prefix":"executor-proxy+artifact-audit"}]
```
- Canonicalization: UTF-8 JSON array sorted by `move_id`; object keys sorted; separators `(',', ':')`; no trailing newline.
- Verified reveal hash: `sha256:554d40fb7f34fc995c5ac0e1e40967ffea51fdd3d2f259eb053c97f3d8cbbf9b` (matches the scoring hash).

## What was rejected/rolled back
- **M01 (benchmark_truthfulness_and_safety) — REJECT / ROLLED BACK**
  - Transient benchmark executable-validator implementation was rejected.
  - Problems: unsafe host execution context, false-pass oracle behavior, row-loss/drop behavior, split-count/provenance reconstruction, and treating mutant survival as success.
  - `HEAD` inspection shows rollback is already present (no persisted change in production files).

## Accepted safe contract (requirement only; unimplemented)
- **M02 (safe_semantic_contract) — ACCEPT_REQUIREMENT_ONLY**
  - Use each manifest-declared validator against the **actual model stdout only**.
  - Exact validators compare to declared expected values.
  - Executable validators must be allowlisted and run in deny-by-default sandbox with:
    - no network
    - no inherited secrets
    - read-only filesystem
    - bounded CPU/memory/time/output/process resources
  - Empty/arbitrary outputs must fail unless explicitly expected.
  - Validator launch/error/timeout must emit failing records; never abort or disappear.
  - Success requires emitted ID set exactly equals selected manifest IDs.
  - Provenance must bind: selected runner, canonical `POST /v1/responses` route, request, model digest, validator, and result.

## Effective-runtime plan retained
- **M03 (effective_runtime_validation) — ACCEPT_TEST_PLAN**
  - Plan (not executed) for C02/C04/C06/C08/C10/C12/C14/C16:
    - verify pinned official model identity + digest + quantization
    - validate effective context via `/api/ps` and live generation behavior
    - enforce bounded `eval_count`
    - run deterministic repeatable generation checks (`temperature=0` + seed)
    - check no thinking leakage
    - verify keep-alive/residency behavior
    - assert runtime cache/config expectations (`OLLAMA_KV_CACHE_TYPE=q8_0`, `-np=8`)

## Cross-layer invariant retained
- **M04 (cross_layer_invariant) — ACCEPT_INVARIANT**
  - A semantic acceptance must be tied to:
    - canonical route `POST /v1/responses`
    - response schema `object=response`
    - bound model/runtime: `HVM_GEMMA_MODEL=gemma4-hvm:official-q4`, `XBREED_HVM_VIA=gemma-hvm`, `OLLAMA_KV_CACHE_TYPE=q8_0`, `OLLAMA_NUM_PARALLEL=8`, `OLLAMA_MAX_LOADED_MODELS=1`
  - Any mismatch in route/schema/model/runtime invalidates acceptance.

## Unverified proxy claim
- **M05 (proxy_test_provenance) — WITHHOLD_UNVERIFIED_CLAIM**
  - No persisted Round-2 proxy artifact or executed round-2 proxy test results were found in this repository worktree.
  - Any proxy semantic kill/pass claims are therefore unverified and should not be used.

## Next red-first implementation (ordered)
1. Implement contract-safe runtime validator execution in the benchmark harness (`benchmarks/run.sh`) with strict sandboxing, manifest-id equality checks, and explicit fail-closed record emission.
2. Add executable validator allowlist + deterministic provenance capture (request, route, digest, validator, result)
3. Add and run effective-runtime probes for remaining config survivors (C02,C04,C06,C08,C10,C12,C14,C16).
4. Persist and execute Round-2 proxy-route semantic test artifact before claiming route/model/validator kills.
5. Retest with sealed manifest/heldout pipeline under cross-layer invariant before any claim changes.

## Notes
- No production files were edited for this report writing task.
- This report intentionally documents review conclusions only; no runtime changes are claimed implemented in this round.