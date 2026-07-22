# Gemma tuning confounders for HVM/Bend bridge

## Goal
Identify second-order interactions and benchmark confounders when tuning Gemma generation options through the HVM/Bend subprocess bridge to Ollama.

## Unknowns
- `obs` `confidence=strong`: I did not run a benchmark here, so the items below are code-path risks, not measured effects.

## Action

### Interaction surface
- `obs` `confidence=strong`: `main.bend` passes a single prompt into `gemma_generate`, so nearly all generation behavior is controlled in [`hvm_gemma.c`](/home/arara/hvm-gemma4/hvm_gemma.c).
- `obs` `confidence=strong`: `hvm_gemma.c` hard-codes `temperature=0.0`, `seed=42`, `num_predict=256`, `num_ctx=2048`, `stream=false`, `think=false`, and `keep_alive=10m`.
- `obs` `confidence=strong`: `run.sh` also pins Ollama runtime flags: `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=f16`, `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=1`.
- `obs` `confidence=strong`: `Modelfile.official` separately sets `PARAMETER temperature 0` and `PARAMETER num_ctx 2048`, so model defaults overlap with bridge-level options.

### Second-order interactions
- `inf` `confidence=strong`: `temperature` changes will be partially masked because both the Ollama model and the bridge force temperature to zero; any apparent “no effect” result is a control-path issue, not a model property.
- `inf` `confidence=strong`: `seed` is fixed to `42`, so sampling variance is suppressed; that makes temperature sweeps non-representative and can hide instability that appears under non-fixed seeds.
- `inf` `confidence=strong`: `num_predict=256` interacts with `num_ctx=2048`; longer prompts can truncate available answer budget, so a “better” setting may only look better because it preserves shorter outputs.
- `inf` `confidence=moderate`: `keep_alive=10m` plus `OLLAMA_MAX_LOADED_MODELS=1` can leak warm-cache effects across runs, especially if benchmark order is not randomized.
- `inf` `confidence=moderate`: `OLLAMA_FLASH_ATTENTION=1` and `OLLAMA_KV_CACHE_TYPE=f16` change throughput/latency and may also perturb numeric behavior, so any quality-vs-speed tradeoff is confounded with backend implementation choices.
- `inf` `confidence=moderate`: `OLLAMA_NUM_PARALLEL=1` removes server-side contention, which is good for repeatability but means results do not transfer to concurrent or batch workloads.

### Benchmark confounders
- `risk` `confidence=strong`: Prompt length is the biggest hidden covariate because the bridge does not normalize it, while `num_ctx` and `num_predict` are fixed.
- `risk` `confidence=strong`: Repeated runs are not independent if the same loaded model stays resident for `10m`; cache warmth and allocator state can bias latency and sometimes output timing-sensitive behavior.
- `risk` `confidence=strong`: Changing only one Ollama option can still be confounded by the duplicate defaults in `Modelfile.official` and `hvm_gemma.c`.
- `risk` `confidence=moderate`: Using the same prompt string every time will overfit the benchmark to this fixed transport path, not the model's general generation behavior.
- `risk` `confidence=moderate`: Because the bridge uses a local HTTP server and a native dylib, CPU scheduling and localhost I/O can dominate small latency differences.

### Practical controls
- `obs` `confidence=strong`: To isolate generation options, make one layer authoritative: either the model file, the dylib request body, or CLI/env overrides, but not all three.
- `inf` `confidence=strong`: For sweeps, vary one of `temperature`, `seed`, `num_predict`, or `num_ctx` at a time and randomize run order.
- `inf` `confidence=strong`: Log prompt token count, wall time, response length, and the exact effective request JSON so duplicate defaults are visible in results.
- `inf` `confidence=moderate`: If testing throughput, separate cold-start runs from warm runs and report them independently.

## Artifact: findings
- `obs` `confidence=strong`: `temperature` is currently doubly pinned to zero in both [`hvm_gemma.c`](/home/arara/hvm-gemma4/hvm_gemma.c) and [`Modelfile.official`](/home/arara/hvm-gemma4/Modelfile.official), so temperature tuning is not observable without removing one of those controls.
- `obs` `confidence=strong`: `seed=42` and `num_predict=256` are hard-coded in [`hvm_gemma.c`](/home/arara/hvm-gemma4/hvm_gemma.c), which can hide variance and cap output length.
- `obs` `confidence=strong`: `keep_alive=10m` in [`hvm_gemma.c`](/home/arara/hvm-gemma4/hvm_gemma.c) and model residency settings in [`run.sh`](/home/arara/hvm-gemma4/run.sh) make warm-cache effects a likely benchmark confounder.
