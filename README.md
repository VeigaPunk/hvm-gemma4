# HVM + Bend + Gemma 4

Private research stack: **Bend** owns program and IO control flow, **HVM2 2.0.22** executes the compiled net, and a narrow native dylib (`libhvm_gemma.so`) calls a local **Gemma 4** inference service (Ollama / llama.cpp). Quantized tensor work stays outside HVM on purpose.

This is also the transport behind the xbreed **`g-` prefix** (`xask gemma` → `gemma-hvm` → this repo).

## Quick start

```sh
# optional: pin official QAT Q4_0 GGUF (revision-pinned; public Google repo)
./download-model.sh

# register with Ollama if needed, then:
./run.sh "Explain mixture-of-experts routing in one sentence."
```

Or install the PATH entrypoint used by xbreed:

```sh
ln -sf "$(pwd)/run.sh" ~/.local/bin/gemma-hvm
xask gemma "one-word reply: pong"
```

Select another Ollama model without rebuilding the bridge:

```sh
HVM_GEMMA_MODEL=gemma4-hvm:official-q4 ./run.sh "Your prompt"
```

## Architecture

```
prompt
  → Bend (main.bend)
  → HVM2
  → IO/DyLib → build/libhvm_gemma.so (gemma_generate)
  → HTTP POST http://127.0.0.1:11434/api/generate
  → local gemma4-hvm:official-q4 (or HVM_GEMMA_MODEL)
```

Replacing the tensor engine would mean a full Gemma 4 loader, tokenizer, quantized ops, mixed attention, KV cache, MoE router, sampler, and conformance suite **inside** HVM. This bridge deliberately does not do that.

## Dependencies

- `bend` + **HVM 2.0.22** (set `HVM_PATH` / `HVM_ROOT` if not in the cargo registry)
- `cc`, `libcurl`, `json-c` (`pkg-config`)
- `ollama` with a Gemma 4 model loaded
- `jq` (test and readiness checks)
- optional: `hf` CLI for `./download-model.sh`

## Env

| Variable | Role |
|----------|------|
| `HVM_GEMMA_MODEL` | Ollama model name (default `gemma4-hvm:official-q4`) |
| `HVM_GEMMA_NUM_CTX` | Context window (default `2048`, minimum `128`) |
| `HVM_GEMMA_NUM_PREDICT` | Output-token cap (default `256`, minimum `1`) |
| `HVM_GEMMA_TEMPERATURE` | Sampling temperature (default `0`, range `0..2`) |
| `HVM_GEMMA_SEED` | Sampling seed (default `42`) |
| `HVM_GEMMA_THINK` | Thinking mode: `true`/`false` or `1`/`0` (default `false`) |
| `HVM_GEMMA_KEEP_ALIVE` | Ollama model residency (default `10m`) |
| `OLLAMA_ENDPOINT` | Ollama base URL (default `http://127.0.0.1:11434`) |
| `HVM_GEMMA_ENDPOINT` | Bridge-specific Ollama URL override; takes precedence over `OLLAMA_ENDPOINT` |
| `OLLAMA_NUM_PARALLEL` | Server parallel request slots when this script starts Ollama (default `128`) |
| `OLLAMA_MODELS` | Ollama model store when this script starts Ollama (default `${XDG_CACHE_HOME:-$HOME/.cache}/ollama/models`) |
| `HVM_PATH` | HVM binary for `bend --hvm-bin` |
| `HVM_ROOT` | HVM crate source for `make` includes |
| `HVM_GEMMA_BIN` | xbreed override for this entrypoint |
| `HF_TOKEN` | optional; used by `hf download` if set |

`run.sh` writes the prompt to a mode-`0600` temporary file and passes only its
path to the native bridge. The launcher removes the file on normal exit and on
signals. This avoids putting prompt bytes in the Bend/HVM environment, including
for prompts larger than 128 KiB. `HVM_GEMMA_PROMPT_FILE` is launcher-internal;
callers should pass prompt arguments to `run.sh` rather than setting it.

`download-model.sh` stores weights under
`${XDG_DATA_HOME:-$HOME/.local/share}/hvm-gemma4/models` by default. Set
`MODEL_DIR` to choose another location.

## License / weights

Code in this repository is private to the owner unless otherwise stated. Model weights are **not** checked in; pull them via `download-model.sh` or your own Ollama registration under the model’s original license terms.
