# Claude Overseer

An autonomous monitoring system powered by Claude Code's `/loop` command. This project uses specialized agents to continuously monitor deployments, logs, PRs, and builds.

## Architecture

- **Agents** (`.claude/agents/`): Specialized monitoring agents invoked on a loop interval
- **Skills** (`.claude/skills/`): Shared capabilities like report formatting
- **Scripts** (`scripts/`): Deterministic shell scripts agents can call for data gathering
- **Loop Notes** (`loop-notes/`): Persistent findings written by agents across loop iterations

## Usage

Start a monitoring loop:
```
/loop 5m @deploy-monitor
/loop 10m @log-scanner
/loop 15m @pr-reviewer
/loop 5m @build-watcher
```

## Conventions

- Agents should write actionable findings to `loop-notes/` with timestamped filenames
- Agents should call scripts in `scripts/` for data collection rather than running raw commands
- Reports should follow the format defined in `.claude/skills/loop-report/SKILL.md`
- Agents should be concise — surface only what changed since last check
- Use exit codes from scripts: 0 = healthy, 1 = warning, 2 = critical
