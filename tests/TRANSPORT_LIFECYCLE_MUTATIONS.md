# Shell / Bend / HVM transport and lifecycle mutations

## State

- obs: `./tests/transport_lifecycle_mutations.sh` now passes 24 assertions.
- obs: `bend check main.bend` exits 0.
- obs: harness remains process-stub only; no real model service required.

## Mutations

### M01 — explicit-pin validation bypass

**HYPOTHESIS** — A provided `HVM_PATH` is trusted.
**RESULT** — `run.sh` passes `--hvm-bin` exactly as supplied, with no shell validation.

### M02 — wrong HVM binary failures propagate

**HYPOTHESIS** — A downstream Bend failure should propagate status and diagnostic text.
**RESULT** — A rejecting/stubbed `HVM_PATH` returns the stub exit and stderr text unchanged.

### M03 — already-ready startup bypass

**HYPOTHESIS** — If readiness endpoint is already ready, no child `ollama` should be spawned.
**RESULT** — `ollama` is not launched and `bend` runs.

### M04 — server env overrides

**HYPOTHESIS** — Explicit `OLLAMA_*` settings should be used when spawning owned Ollama.
**RESULT** — Custom values for all supported `OLLAMA_*` variables were observed in the spawned env command.

### M05 — ready identity acceptance/rejection

**HYPOTHESIS** — The readiness probe must only accept Ollama API identity payloads.
**RESULT** — Semver-style version payloads from `/api/version` are accepted, while fake root responders are rejected.

### M06 — fake root responder rejection

**HYPOTHESIS** — Non-JSON/non-Ollama roots should be treated as not ready.
**RESULT** — readiness fails when `/api/version` returns a fake root response.

### M07 — delayed readiness

**HYPOTHESIS** — Startup can recover when endpoint becomes ready after retries.
**RESULT** — `run.sh` waits through delayed probes, starts `ollama`, and then executes `bend`.

### M08 — bounded readiness exhaustion

**HYPOTHESIS** — Never-ready endpoint should fail after bounded wait.
**RESULT**: `curl` probe count remains bounded and status exits 1 with explicit readiness error.

### M09 — owned child liveness

**HYPOTHESIS** — Child crash should abort readiness early.
**RESULT**: when `ollama` exits during bootstrap, `run.sh` returns promptly with owned-child exit reason.

### M10 — supervised cleanup

**HYPOTHESIS** — Owned `ollama` started by `run.sh` is terminated on every path.
**RESULT** — normal and signal paths both clean up the child before returning, including stubborn child escalation under shutdown grace.

### M11 — signal handling

**HYPOTHESIS** — TERM/INT should stop promptly and return signal-derived status.
**RESULT**: TERM exits with 143 and logs child teardown.

### M12 — prompt argument handling

**HYPOTHESIS** — Empty prompt argument should remain explicit when passed.
**RESULT**: empty first argument is serialized as `""` and reaches `bend`.

### M13 — readiness timeout behavior

**HYPOTHESIS** — Hung readiness probe should have bounded request/deadline budget.
**RESULT**: `curl` probe wrapper time-bounds calls and stops start-up quickly.

## Frontier / status

- ready semantics: explicit environment overrides, child lifecycle cleanup, and prompt handling are now exercised and pinned by tests.
- previously observed defects around orphaned child / dead-child / hung curl are now covered by red-before-green assertions and pass on this branch.
