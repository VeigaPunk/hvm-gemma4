# xbreed-hvm-proxy (TypeScript / Bun)

OpenAI-compatible front for the **xbreed `g-` lane**.

**Primary protocol is the Responses API** (`POST /v1/responses`) — what Codex Titanium
and Pi (`openai-responses`) use. This is **not** Chat Completions as the main path
(Chat Completions remains as a secondary fallback for Kimi/etc.).

```
CLI (Codex wire_api=responses / Pi openai-responses / …)
  → http://127.0.0.1:11435/v1/responses
  → gemma-hvm / run-hvm4.sh
  → Bend 0.2.38 gen-hvm → HVM4 4.0 control gate → Ollama
```

## Run

`run-proxy.sh` performs a fail-closed `check-hvm4-provenance.sh` startup check for
`gemma4-hvm:a4b-q4-k-m` (Q4_K_M) before serving. It enables buffered SSE by
default for streaming-only clients such as OpenCode; HVM inference itself remains
non-streaming.

```sh
./run-proxy.sh
XBREED_HVM_STREAMING=0 ./run-proxy.sh  # strict non-streaming mode
# direct server defaults to streaming disabled unless the flag is set
XBREED_HVM_STREAMING=1 bun run src/server.ts
```

## Smoke (Responses API)

```sh
curl -s http://127.0.0.1:11435/v1/responses \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer xbreed-hvm' \
  -d '{"model":"gemma4-hvm:a4b-q4-k-m","input":"say pong","stream":false}' \
  | jq -r .output_text
```

## CLI wiring

| CLI | Setting |
|-----|---------|
| Codex Titanium | `wire_api = "responses"`, provider `xbreed-hvm`, profile `gemma-hvm` |
| Pi | `api: "openai-responses"`, provider `xbreed-hvm`, model `gemma4-hvm:a4b-q4-k-m` |
| Kimi | OpenAI provider → same base URL (uses chat fallback if needed) |

Env: `XBREED_HVM_API_KEY` (default `xbreed-hvm`), `HVM_GEMMA_MODEL`,
`XBREED_HVM_PORT`, and `XBREED_HVM_STREAMING` (`1|true|yes|on` enables
buffered SSE; other values disable it).
