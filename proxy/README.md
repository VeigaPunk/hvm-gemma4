# xbreed-hvm-proxy (TypeScript / Bun)

OpenAI-compatible HTTP front for the **xbreed `g-` lane**:

```
CLI (Codex / Pi / Kimi / …)
  → http://127.0.0.1:11435/v1
  → gemma-hvm  (or XBREED_HVM_VIA=xbreed → xbreed ask gemma)
  → Bend → HVM2 → libhvm_gemma.so → Ollama
```

## Run

```sh
cd /home/arara/hvm-gemma4/proxy
bun install
bun run start
# or: ./run-proxy.sh
```

Health: `curl -s http://127.0.0.1:11435/health`

## Env

| Variable | Default | Meaning |
|----------|---------|---------|
| `XBREED_HVM_PORT` | `11435` | listen port |
| `HVM_GEMMA_BIN` | `gemma-hvm` | HVM entrypoint |
| `HVM_GEMMA_MODEL` | `gemma4:26b` | Ollama model the bridge requests |
| `XBREED_HVM_VIA` | `gemma-hvm` | set `xbreed` to use `xbreed ask gemma` |
| `XBREED_HVM_API_KEY` | `xbreed-hvm` | optional Bearer token |
| `XASK_TIMEOUT_SECS` | `600` | kill hung HVM after N seconds |

## Smoke

```sh
curl -s http://127.0.0.1:11435/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer xbreed-hvm' \
  -d '{"model":"gemma4:26b","messages":[{"role":"user","content":"say pong"}],"stream":false}' \
  | jq -r .choices[0].message.content
```
