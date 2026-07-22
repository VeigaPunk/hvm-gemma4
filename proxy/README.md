# xbreed-hvm-proxy (TypeScript / Bun)

OpenAI-compatible front for the **xbreed `g-` lane**.

**Primary protocol is the Responses API** (`POST /v1/responses`) — what Codex Titanium
and Pi (`openai-responses`) use. This is **not** Chat Completions as the main path
(Chat Completions remains as a secondary fallback for Kimi/etc.).

```
CLI (Codex wire_api=responses / Pi openai-responses / …)
  → http://127.0.0.1:11435/v1/responses
  → gemma-hvm
  → Bend → HVM2 → libhvm_gemma.so → Ollama
```

## Run

```sh
./run-proxy.sh
# or: bun run src/server.ts
```

## Smoke (Responses API)

```sh
curl -s http://127.0.0.1:11435/v1/responses \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer xbreed-hvm' \
  -d '{"model":"gemma4:26b","input":"say pong","stream":false}' \
  | jq -r .output_text
```

## CLI wiring

| CLI | Setting |
|-----|---------|
| Codex Titanium | `wire_api = "responses"`, provider `xbreed-hvm`, profile `gemma-hvm` |
| Pi | `api: "openai-responses"`, `xbreed-hvm/gemma4:26b` |
| Kimi | OpenAI provider → same base URL (uses chat fallback if needed) |

Env: `XBREED_HVM_API_KEY` (default `xbreed-hvm`), `HVM_GEMMA_MODEL`, `XBREED_HVM_PORT`.
