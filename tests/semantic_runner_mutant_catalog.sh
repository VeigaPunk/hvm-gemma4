#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CATALOG=$ROOT/analysis/semantic_runner_mutants.jsonl

command -v jq >/dev/null 2>&1 || { echo 'Bail out! jq not found' >&2; exit 2; }

jq -e -s '
  length == 12 and
  ([.[].mutant_id] | unique | length) == 12 and
  (map(.mutant_id) == [range(1; 13) | "SR" + (if . < 10 then "0" else "" end) + tostring]) and
  (group_by(.axis) | map({key: .[0].axis, value: length}) | from_entries) == {
    "exact-normalization": 2,
    "regex-normalization": 2,
    "json-normalization": 2,
    "split-no-drop": 2,
    "row-preservation": 2,
    "runner-provenance": 2
  } and
  all(.[ ];
    .scope == "semantic-runner" and
    .status == "specified" and
    (.baseline | type == "string" and length > 0) and
    (.operator | type == "string" and length > 0) and
    (.mutation | type == "string" and length > 0) and
    (.witness | type == "object") and
    (.expected_kill | type == "string" and length > 0) and
    (.applies_to | length > 0) and
    all(.applies_to[]; . == "exact" or . == "regex" or . == "json") and
    (.claim | startswith("inf:")) and
    (.confidence == "certain" or .confidence == "strong")
  )
' "$CATALOG" >/dev/null

printf 'ok 1 - 12 unique semantic-runner mutants cover the six requested axes\n'
printf 'ok 2 - executable-validator mutations are excluded from every applies_to set\n'
