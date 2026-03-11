# Loop Report Skill

Format all loop iteration output using this standardized structure.

## Report Format

```
[AGENT_NAME] [TIMESTAMP] [STATUS_EMOJI]

STATUS: healthy | warning | critical | info
CHANGES: Number of changes since last check

FINDINGS:
- Finding 1 (severity)
- Finding 2 (severity)

ACTION NEEDED: Yes/No — brief description if yes
```

## Rules

1. **Be concise**: Maximum 10 lines for routine checks, 20 lines for incidents
2. **Delta-only**: Only report what changed since the last loop iteration
3. **Severity prefix**: Use `[CRIT]`, `[WARN]`, `[INFO]` prefixes for findings
4. **Timestamps**: Use ISO 8601 format (e.g., 2026-03-10T14:30:00Z)
5. **No noise**: If nothing changed, output a single status line
6. **Actionable**: Every finding should suggest what to do or who to notify

## Quiet Output (Nothing Changed)

When there are no changes since the last check:
```
[AGENT_NAME] [TIMESTAMP] — No changes. All healthy.
```

## Writing Notes

When writing findings to `loop-notes/`, use this filename pattern:
```
loop-notes/{agent-prefix}-{YYYY-MM-DD-HHmmss}.md
```

Notes should include:
- Full findings with context
- Raw data/metrics for comparison in future iterations
- Links to relevant PRs, builds, or dashboards
