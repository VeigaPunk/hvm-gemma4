# HVM4 + Bend adapter

This is the authentic HVM4 adaptation path:

```text
Bend→gen-hvm → HVM4 4.0 runtime (pure control computation) → Ollama/Gemma
```

Current upstream HVM4 4.0 is a pre-launch, sequential runtime for pure
Interaction Calculus programs. It has no documented HTTP, IO, dylib, or FFI
surface, so this path uses Bend to generate an HVM4 control program that HVM4
itself executes to validate `num_predict` before Ollama inference.

This does **not** claim that Gemma tensor operations execute on HVM4.

## Run

```sh
HVM4_GEMMA_METRICS=1 ./run-hvm4.sh "Reply exactly: HVM4_OK"
```

### Scope and compatibility gates

`run-hvm4.sh` enforces strict runner bounds for this boundary:
- exact runtime compatibility: Bend `0.2.38` and HVM4 `4.0.x`
- `BEND_BIN`/`HVM4_BIN` must resolve to executable binaries
- request/IO validation parity with `hvm_gemma.c` options (endpoint/model/num_ctx/num_predict/temperature/seed/think/keep_alive/system)
- HVM4 is invoked only as a scoped control runner: generated control program path + `-C1`.

Requirements: built HVM4 at `$HVM4_ROOT` (default
`/home/arara/Projects/HVM4`), Bend 0.2.38, Ollama, curl, and jq.

## Mailbox substrate (BEND2)

The xbreed team mailbox keep-classifier runs on the same HVM4 control plane:

```text
events.ndjson → Bend keep source-of-record → HVM4 IR lowerer → HVM4 -C1 → filtered NDJSON
```

- Source of record: [`mailbox.bend`](mailbox.bend) (keep kinds 1..4)
- Entrypoint: [`mailbox-bend2.sh`](mailbox-bend2.sh) → xbreed `scripts/mailbox-hvm4.sh`
- CLI: `xbreed team mailbox compact --hvm4` (or `XBREED_MAILBOX_BACKEND=hvm4`)
- Connector: `xbreed team mailbox connect` (Gemma/HVM synthesizer over the live socket)

Why a custom lowerer: `bend gen-hvm` still emits HVM2 nets for non-literal
programs (lists / `==` / functions). The mailbox substrate keeps Bend as the
syntax gate and lowers only the keep dialect into HVM4-native IR.
