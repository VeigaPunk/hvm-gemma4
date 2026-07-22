# Local Gemma knob calibration — 2026-07-22

All 15 OFAT smoke trials and both two-request contention trials passed. Raw evidence is in `knob-results.jsonl`.

| Axis | Measurements (ms) | Selection |
|---|---|---|
| `num_predict` | 32: 822; 96: 799; 224: 783 | 96 — balanced structural headroom |
| `num_ctx` | 1024: 769; 2048: 767; 4096: 7353 | 2048 — capacity without reload penalty |
| `keep_alive` | 0: 7497; 10m: 7431; later warm calls ~700 | 10m — interactive residency |
| temperature | 0: 703; 0.2: 711; 0.7: 712 | 0.2 — mild conversational variation |
| KV cache | f16: 7039; q8_0: 8289 | q8_0 retained conservatively; repeat before changing |
| parallel contention | 1: 9612; 2: 9218 | 2 — both requests passed, 4.1% lower batch wall time |

The KV result is a single cold-load sample and unexpectedly favored f16 in both latency and reported VRAM. It is insufficient evidence to replace the established q8_0 default.
