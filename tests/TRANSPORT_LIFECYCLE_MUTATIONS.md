# Shell / Bend / HVM transport and lifecycle mutations

## State

- obs: `./tests/transport_lifecycle_mutations.sh` passes 16/16 assertions. Confidence: certain.
- obs: `bend check main.bend` exits 0. Confidence: certain.
- obs: The harness replaces external processes only; it does not alter production sources or contact the model service. Confidence: certain.

## Mutations

### M01 — explicit-pin validation bypass

**HYPOTHESIS** — inf: An explicit `HVM_PATH` is trusted without checking existence, executability, or version. Confidence: strong.  
**METHOD** — obs: Set `HVM_PATH` to a nonexistent file and record the arguments received by the Bend boundary. Confidence: certain.  
**RESULT** — obs: The exact nonexistent path reached `bend --hvm-bin`; the shell returned the stub Bend status. Confidence: certain.

### M02 — wrong HVM binary

**HYPOTHESIS** — inf: A downstream Bend failure caused by the wrong binary propagates through `run.sh`. Confidence: strong.  
**METHOD** — obs: Make the Bend boundary reject the nonexistent HVM with status 66 and a stderr diagnostic. Confidence: certain.  
**RESULT** — obs: `run.sh` returned 66 and preserved the diagnostic on stderr. Confidence: certain.

### M03 — already-ready startup bypass

**HYPOTHESIS** — inf: A successful initial readiness probe prevents creation of an owned Ollama process. Confidence: strong.  
**METHOD** — obs: Return success from every readiness probe and record process invocations. Confidence: certain.  
**RESULT** — obs: Bend ran and `ollama serve` did not. Confidence: certain.

### M04 — readiness false positive

**HYPOTHESIS** — inf: Readiness depends only on curl status, not response content or model availability. Confidence: strong.  
**METHOD** — obs: Make the root endpoint return success under a `false-positive` fault without supplying a valid health body. Confidence: certain.  
**RESULT** — obs: Both probes passed and Bend ran. Confidence: certain.

### M05 — delayed readiness

**HYPOTHESIS** — inf: The shell tolerates a service that becomes ready during the polling window. Confidence: strong.  
**METHOD** — obs: Fail probes 1–3, succeed at probe 4, and record Ollama and Bend invocations. Confidence: certain.  
**RESULT** — obs: Ollama started and control reached Bend with status 0. Confidence: certain.

### M06 — readiness exhaustion

**HYPOTHESIS** — inf: A service that never becomes ready returns a stable shell error after the finite retry count. Confidence: strong.  
**METHOD** — obs: Fail the preflight probe, all 60 loop probes, and the final probe. Confidence: certain.  
**RESULT** — obs: Exactly 62 probes occurred; status was 1 and stderr contained `Ollama did not become ready`. Confidence: certain.

### M07 — server dies during startup

**HYPOTHESIS** — inf: Early Ollama death is not detected directly because the polling loop does not inspect its PID. Confidence: strong.  
**METHOD** — obs: Make `ollama serve` exit 23 immediately while every readiness probe fails. Confidence: certain.  
**RESULT** — obs: The shell still performed all 62 probes and eventually returned readiness status 1, masking child status 23. Confidence: certain.

### M08 — owned-process cleanup after success

**HYPOTHESIS** — inf: `exec bend` replaces the shell before its `EXIT` trap can clean an Ollama process started by that shell. Confidence: strong.  
**METHOD** — obs: Start a persistent fake Ollama, become ready, let Bend exit 0, then test the recorded PID. Confidence: certain.  
**RESULT** — obs: The owned Ollama PID remained alive after `run.sh` completed; the harness then terminated it. Confidence: certain.

### M09 — TERM during readiness

**HYPOTHESIS** — inf: The `TERM` trap calls cleanup but does not explicitly end the shell, so polling can continue. Confidence: strong.  
**METHOD** — obs: Send TERM during the first polling sleep while readiness continues to fail. Confidence: certain.  
**RESULT** — obs: The child received TERM, but the shell completed all 62 probes and returned 1 rather than terminating immediately with a signal-derived status. Confidence: certain.

### M10 — Bend nonzero exit

**HYPOTHESIS** — inf: `exec` preserves Bend's nonzero status. Confidence: strong.  
**METHOD** — obs: Make Bend return 7 after successful readiness. Confidence: certain.  
**RESULT** — obs: `run.sh` returned 7. Confidence: certain.

### M11 — stdout/stderr separation

**HYPOTHESIS** — inf: Bend's output streams pass through without merging. Confidence: strong.  
**METHOD** — obs: Emit distinct sentinels on Bend stdout and stderr and capture them separately. Confidence: certain.  
**RESULT** — obs: Each sentinel appeared only in its intended stream. Confidence: certain.

### M12 — build failure

**HYPOTHESIS** — inf: `set -e` prevents transport startup after a failed build. Confidence: strong.  
**METHOD** — obs: Make `make` return 2 and record later invocations. Confidence: certain.  
**RESULT** — obs: Status 2 propagated; neither readiness nor Bend ran. Confidence: certain.

### M13 — prompt encoder failure

**HYPOTHESIS** — inf: A failed `jq` command substitution stops execution before Bend. Confidence: strong.  
**METHOD** — obs: Make `jq` emit a stderr diagnostic and return 9. Confidence: certain.  
**RESULT** — obs: Status 9 and stderr propagated; Bend did not run. Confidence: certain.

### M14 — quoting and argument collapse

**HYPOTHESIS** — inf: Multiple shell arguments are intentionally collapsed with spaces, then transported as one JSON-safe Bend argument. Confidence: strong.  
**METHOD** — obs: Supply separate arguments containing a quote and newline and record Bend's argv. Confidence: certain.  
**RESULT** — obs: Bend received one encoded prompt containing escaped quote/newline data; original argument boundaries were not retained. Confidence: certain.

### M15 — PATH HVM fallback

**HYPOTHESIS** — inf: With no explicit pin and no registry build, discovery falls back to the first `hvm` on PATH. Confidence: strong.  
**METHOD** — obs: Use an empty `CARGO_HOME`, unset `HVM_PATH`, and place a fake `hvm` first on PATH. Confidence: certain.  
**RESULT** — obs: The fake PATH binary was passed to `bend --hvm-bin`. Confidence: certain.

### M16 — hung readiness request

**HYPOTHESIS** — inf: The 60-iteration loop is not a wall-clock timeout because readiness curl calls have no `--connect-timeout` or `--max-time`. Confidence: strong.  
**METHOD** — obs: Make the initial curl hang and place a 0.2-second external deadline around `run.sh`. Confidence: certain.  
**RESULT** — obs: The external deadline killed the run before Bend; the shell supplied no internal deadline. Confidence: certain.

### M17 — real Bend with a non-HVM executable

**HYPOTHESIS** — inf: Real Bend rejects an executable that starts successfully but emits no HVM result. Confidence: strong.  
**METHOD** — obs: Run real Bend with `--hvm-bin /bin/true` against `main.bend`. Confidence: certain.  
**RESULT** — obs: Bend returned 1 with `HVM output had no result`. Confidence: certain.

### M18 — real HVM with missing relative dylib

**HYPOTHESIS** — inf: Running from the wrong working directory breaks the relative `./build/libhvm_gemma.so` transport. Confidence: strong.  
**METHOD** — obs: From `/tmp`, run real Bend and HVM against the absolute path to `main.bend`. Confidence: certain.  
**RESULT** — obs: HVM emitted dylib-handle and undefined-symbol errors but the overall command returned 0 with an `IO/Done` result. Confidence: certain.  
**RESULT** — risk: Loader failure can therefore look successful to callers that inspect exit status only. Confidence: strong.

## Frontier

- obs: M08 is a cleanup defect: remove `exec` or transfer owned-process supervision to a wrapper that remains alive. Confidence: strong.
- obs: M09 is a signal-lifecycle defect: the INT/TERM handler needs an explicit signal-derived exit after cleanup. Confidence: strong.
- obs: M16 is a timeout defect: each readiness request needs bounded connect and total time. Confidence: strong.
- obs: M18 is an exit-status defect at the Bend/HVM/dylib boundary. Confidence: strong.
