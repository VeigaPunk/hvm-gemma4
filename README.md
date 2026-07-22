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
  → local gemma4:26b (or HVM_GEMMA_MODEL)
```

Replacing the tensor engine would mean a full Gemma 4 loader, tokenizer, quantized ops, mixed attention, KV cache, MoE router, sampler, and conformance suite **inside** HVM. This bridge deliberately does not do that.

## Dependencies

- `bend` + **HVM 2.0.22** (set `HVM_PATH` / `HVM_ROOT` if not in the cargo registry)
- `cc`, `libcurl`, `json-c` (`pkg-config`)
- `ollama` with a Gemma 4 model loaded
- `jq` (prompt encoding)
- optional: `hf` CLI for `./download-model.sh`

## Env

| Variable | Role |
|----------|------|
| `HVM_GEMMA_MODEL` | Ollama model name (default `gemma4:26b`) |
| `HVM_PATH` | HVM binary for `bend --hvm-bin` |
| `HVM_ROOT` | HVM crate source for `make` includes |
| `HVM_GEMMA_BIN` | xbreed override for this entrypoint |
| `HF_TOKEN` | optional; used by `hf download` if set |

## License / weights

Code in this repository is private to the owner unless otherwise stated. Model weights are **not** checked in; pull them via `download-model.sh` or your own Ollama registration under the model’s original license terms.
