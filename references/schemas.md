# Output schemas

`--schema FILE` passes a JSON Schema to `codex exec --output-schema`, which forces the final
message to be JSON matching it. Use a schema whenever you will parse, compare, or aggregate a
result; use plain prose only when a human reads it directly.

Write the schema into `<run>/schema/<name>.json` before dispatching. The result lands in
`<run>/agents/<label>/result.json`.

Constraints that matter: the top level must be an object, and every object needs
`"additionalProperties": false` plus a `required` list, otherwise workers pad the answer with
invented fields.

## Implementation

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["status", "summary", "files_changed", "commands_run", "unresolved"],
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
    "unresolved": {"type": "array", "items": {"type": "string"}}
  }
}
```

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
anything marked `verified`.
