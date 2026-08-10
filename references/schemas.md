# Output schemas

`--schema FILE` passes a JSON Schema to `codex exec --output-schema`, which forces the final
message to be JSON matching it. Use a schema whenever you will parse, compare, or aggregate a
result; use plain prose only when a human reads it directly.

Write the schema into `<run>/schema/<name>.json` before dispatching. The result lands in
`<run>/agents/<label>/result.json`.

The CLI forwards the schema to the API without checking it, so an invalid schema is rejected
only after the dispatch is paid for. `codex_agent.sh` pre-checks the documented subset and
refuses to launch. The constraints:

- the root must be an object, not `anyOf`
- every object needs `"additionalProperties": false` and lists every property in `required`
  (make a field optional by allowing `null` in its type, not by omitting it)
- supported: string, number, integer, boolean, object, array, enum, nested `anyOf`, `$defs`
- rejected: `allOf`, `oneOf`, `not`, `if`/`then`/`else`, `dependentRequired`,
  `dependentSchemas`, `patternProperties`
- limits: 10 nesting levels, 5,000 properties, 120,000 characters of schema, 1,000 enum values

## Implementation

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["status", "summary", "files_changed", "commands_run", "not_verified", "unresolved"],
  "properties": {
    "status": {"type": "string", "enum": ["done", "partial", "blocked"]},
    "summary": {"type": "string"},
    "files_changed": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["path", "change"],
        "properties": {
          "path": {"type": "string"},
          "change": {"type": "string"}
        }
      }
    },
    "commands_run": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["command", "exit_code"],
        "properties": {
          "command": {"type": "string"},
          "exit_code": {"type": "integer"}
        }
      }
    },
    "not_verified": {"type": "array", "items": {"type": "string"}},
    "unresolved": {"type": "array", "items": {"type": "string"}}
  }
}
```

`commands_run` is what makes the report checkable: an empty list next to `status: "done"` means
the worker verified nothing, whatever its summary says. `not_verified` is required for the same
reason — a worker that claims complete coverage is either wrong or was not asked a hard enough
question. Re-run the listed commands yourself; their presence is a claim until you do.

`status: "blocked"` with a populated `unresolved` list is a successful outcome: the worker hit
a real contradiction instead of inventing a way around it.

## Findings (audit, bug hunt, review)

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["findings"],
  "properties": {
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["file", "line", "severity", "claim", "evidence", "failure_scenario"],
        "properties": {
          "file": {"type": "string"},
          "line": {"type": "integer"},
          "severity": {"type": "string", "enum": ["high", "medium", "low"]},
          "claim": {"type": "string"},
          "evidence": {"type": "string"},
          "failure_scenario": {"type": "string"}
        }
      }
    }
  }
}
```

Requiring `failure_scenario` — concrete input, then wrong output — removes most style
complaints dressed up as bugs. Findings from parallel agents deduplicate on `file` plus
`line`.

## Research and data collection

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["answers", "gaps"],
  "properties": {
    "answers": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["question", "answer", "sources", "confidence"],
        "properties": {
          "question": {"type": "string"},
          "answer": {"type": "string"},
          "sources": {"type": "array", "items": {"type": "string"}},
          "confidence": {"type": "string", "enum": ["verified", "probable", "unverified"]}
        }
      }
    },
    "gaps": {"type": "array", "items": {"type": "string"}}
  }
}
```

Treat `unverified` as unusable until you check it yourself, and spot-check the sources behind
anything marked `verified`: fetch at least two of them and confirm the quoted number, publisher,
and date actually appear there. Fabricated and drifted citations are the normal failure mode of
research agents, and a confident answer with a plausible URL is exactly what they look like.
