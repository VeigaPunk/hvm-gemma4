# Gemma bridge generation-option mutations

Baseline: `hvm_gemma.c` constructs `options={num_ctx:2048, temperature:0.0, seed:42, num_predict:256}` with json-c, then transfers that object into the request. The campaign creates isolated temporary source copies; it never edits the baseline. `tests/generation_option_mutations.sh` verifies that every edit lands and compiles against the same HVM/json-c/libcurl headers as production.

`RESULT` here reports the observed compile-oracle outcome, followed by the runtime consequence inferred from json-c/Ollama semantics. `SURVIVED` means the current build checks do not detect the defect; it does not mean the mutant is correct.

## Boundary

### M01 — `num_ctx: 2048 -> 0`

- **HYPOTHESIS** — risk: a zero context is rejected or yields unusable generation. Confidence: strong.
- **METHOD** — obs: replace only `json_object_new_int(2048)` with `json_object_new_int(0)`, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: only a request-shape/API test can kill it. Confidence: strong.

### M02 — `num_ctx: 2048 -> INT_MAX`

- **HYPOTHESIS** — risk: the request provokes allocation failure, overflow downstream, or an Ollama validation error. Confidence: strong.
- **METHOD** — obs: emit `2147483647` through `json_object_new_int`, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: a bounded server test should require a clean error without OOM. Confidence: strong.

### M03 — `num_predict: 256 -> 0`

- **HYPOTHESIS** — risk: zero changes the output-limit contract and may produce no tokens or backend-specific behavior. Confidence: moderate.
- **METHOD** — obs: replace the integer value only, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: an exact-output test with a nonempty response is needed. Confidence: strong.

### M04 — `num_predict: 256 -> -2`

- **HYPOTHESIS** — risk: Ollama's fill-context sentinel removes the 256-token latency bound. Confidence: strong.
- **METHOD** — obs: emit `-2` under the unchanged `num_predict` key, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: a request assertion or duration/output cap should kill it. Confidence: strong.

## Wrong default

### M05 — `temperature: 0.0 -> 0.8`

- **HYPOTHESIS** — risk: the deterministic bridge silently becomes stochastic. Confidence: strong.
- **METHOD** — obs: change only the double literal, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: exact request inspection is more reliable than output-repeat tests because `seed=42` may mask variance. Confidence: strong.

### M06 — `seed: 42 -> 0`

- **HYPOTHESIS** — risk: reproducibility no longer matches the pinned baseline. Confidence: strong.
- **METHOD** — obs: change only the seed literal, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: output tests at temperature zero may be equivalent, so the request body must be asserted. Confidence: strong.

### M07 — `num_ctx: 2048 -> 4096`

- **HYPOTHESIS** — risk: the bridge doubles KV-cache demand and violates the documented default even when short prompts appear correct. Confidence: strong.
- **METHOD** — obs: change only the context literal, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: short functional prompts will probably miss it. Confidence: strong.

## Precedence

### M08 — append duplicate `temperature=0.8`

- **HYPOTHESIS** — risk: a later duplicate silently overrides the intended `0.0`. Confidence: strong.
- **METHOD** — obs: add the same key again after the baseline temperature insertion, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: json-c replacement semantics make the effective value `0.8`. Confidence: strong.

### M09 — prepend duplicate `temperature=0.8`

- **HYPOTHESIS** — inf: the later baseline insertion wins, making this an equivalent request mutant despite suspicious source. Confidence: strong.
- **METHOD** — obs: insert `temperature=0.8` immediately before `temperature=0.0`, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: effective temperature remains `0.0`, proving order-sensitive last-write precedence. Confidence: strong.

### M10 — replace attached `options` with `{}`

- **HYPOTHESIS** — risk: request-level replacement drops every pinned option at once and exposes model/server defaults. Confidence: strong.
- **METHOD** — obs: add a second `request["options"]` assignment after attachment, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: json-c leaves the effective request with an empty options object. Confidence: strong.

## Dropped option

### M11 — remove `num_ctx`

- **HYPOTHESIS** — risk: effective context falls through to model or server defaults. Confidence: strong.
- **METHOD** — obs: delete exactly the `num_ctx` insertion, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: only an exact key-set oracle reliably kills it. Confidence: strong.

### M12 — remove `temperature`

- **HYPOTHESIS** — risk: sampling behavior inherits a potentially different model default. Confidence: strong.
- **METHOD** — obs: delete exactly the temperature insertion, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: the current official Modelfile may mask this defect by also pinning zero. Confidence: strong.

### M13 — remove `seed`

- **HYPOTHESIS** — risk: reproducibility becomes backend/default dependent when sampling is enabled. Confidence: strong.
- **METHOD** — obs: delete exactly the seed insertion, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: deterministic baseline output can mask it. Confidence: strong.

### M14 — remove `num_predict`

- **HYPOTHESIS** — risk: response length and latency lose the bridge's 256-token bound. Confidence: strong.
- **METHOD** — obs: delete exactly the output-limit insertion, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: short prompts are weak detectors, while request-key and long-output tests are strong detectors. Confidence: strong.

## Escaping and type

### M15 — serialize `options` as a JSON string

- **HYPOTHESIS** — risk: double encoding changes `options` from an object to escaped text, e.g. `"options":"{\\"num_ctx\\":...}"`. Confidence: strong.
- **METHOD** — obs: wrap the options serialization in `json_object_new_string(...)`, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: a schema/type assertion kills it before server dispatch. Confidence: strong.

### M16 — escape a quote into the option key

- **HYPOTHESIS** — risk: the JSON stays syntactically valid but Ollama ignores the unknown escaped key. Confidence: strong.
- **METHOD** — obs: mutate the C key literal so the decoded key is `temperature"`, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: JSON-validity-only tests will miss it; exact key equality is required. Confidence: strong.

## Return and error paths

### M17 — release `options` after ownership transfer

- **HYPOTHESIS** — risk: decrementing the attached object's sole reference creates a dangling value in `request`, leading to use-after-free during serialization or cleanup. Confidence: strong.
- **METHOD** — obs: insert `json_object_put(options)` immediately after `json_object_object_add(request, "options", options)`, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: an ASan request-construction test should kill it deterministically. Confidence: strong.

### M18 — return directly on curl initialization failure

- **HYPOTHESIS** — risk: bypassing `cleanup_json` leaks the request tree and `prompt.buf` on every initialization failure. Confidence: strong.
- **METHOD** — obs: replace the error-path `goto cleanup_json` with a direct error return, then compile. Confidence: certain.
- **RESULT** — obs: SURVIVED the compile oracle; inf: a forced `curl_easy_init()==NULL` test under LeakSanitizer should kill it while checking the same error text. Confidence: strong.

## Aggregate result

- obs: all 18/18 mutants survived the campaign's production-equivalent C compile oracle, for a 0% compile-time kill rate. Confidence: certain.
- inf: the smallest non-overlapping detector set is (1) an intercepted HTTP request schema/value assertion, (2) duplicate-key precedence cases, (3) a bounded Ollama rejection test for extreme values, and (4) ASan/LSan fault injection for ownership and early returns. Confidence: strong.
- risk: live-generation-only tests can miss M06, M09, M12, and M13 because deterministic decoding and duplicate Modelfile defaults mask request defects. Confidence: strong.
