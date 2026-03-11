# Claude Overseer

An autonomous monitoring and orchestration system for multi-agent development environments. Built on [Claude Code's](https://docs.anthropic.com/en/docs/claude-code) `/loop` command and [NTM](https://github.com/Dicklesworthstone/ntm) (Named Tmux Manager), it keeps your AI coding agents running, productive, and coordinated.

## What It Does

Claude Overseer manages multiple AI coding agents (Claude Code, Codex) running in tmux panes:

- **Watchdog** — Detects frozen/crashed LLM sessions and automatically restarts them
- **Auto-Prompter** — Feeds idle agents new work from a configurable prompt list
- **Deploy Monitor** — Tracks deployment health and surface degradations
- **Build Watcher** — Monitors CI/CD pipeline status via GitHub Actions
- **PR Reviewer** — Watches open pull requests for staleness and review needs
- **Log Scanner** — Scans logs for errors, anomalies, and recurring patterns

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- [NTM](https://github.com/Dicklesworthstone/ntm) (Named Tmux Manager)
- [tmux](https://github.com/tmux/tmux)
- [GitHub CLI](https://cli.github.com/) (`gh`) — for PR and build monitoring agents
- bash 4.0+ (for associative arrays)

## Project Structure

```
claude-overseer/
├── CLAUDE.md                          # Global project context for Claude Code
├── README.md                          # This file
├── prompts.conf                       # Prompt list config (NTM + custom entries)
├── custom-prompts.md                  # Custom inline prompts for auto-prompter
├── .gitignore
├── .claude/
│   ├── agents/
│   │   ├── tmux-watchdog.md           # Frozen pane detection & restart
│   │   ├── auto-prompter.md           # Idle pane prompt delivery
│   │   ├── deploy-monitor.md          # Deployment health checks
│   │   ├── log-scanner.md             # Log error/anomaly scanning
│   │   ├── pr-reviewer.md             # Open PR tracking
│   │   └── build-watcher.md           # CI/CD build monitoring
│   ├── skills/
│   │   └── loop-report/
│   │       └── SKILL.md               # Standardized report format
│   └── settings.local.json            # Personal tool permissions (gitignored)
├── scripts/
│   ├── pane-watchdog.sh               # Frozen detection, kill, restart logic
│   ├── auto-prompt.sh                 # Idle detection, prompt selection & send
│   ├── health-check.sh                # System health checks (disk, memory, endpoints)
│   ├── log-digest.sh                  # Log filtering and summarization
│   └── metrics-snapshot.sh            # System and application metrics capture
└── loop-notes/                        # Agent findings (gitignored, append-only daily logs)
```

## Quick Start

### 1. Clone and set up

```bash
git clone https://github.com/JordanChoo/claude-overseer.git
cd claude-overseer
```

### 2. Set up an NTM session

```bash
# Create a multi-agent session with Claude Code and Codex agents
ntm spawn myproject --cc=4 --cod=2
```

### 3. Start the core agents

From a Claude Code session, start the watchdog and auto-prompter:

```bash
/loop 30s @tmux-watchdog     # Monitor for frozen panes
/loop 60s @auto-prompter     # Feed idle panes new work
```

### 4. Optionally start monitoring agents

```bash
/loop 5m @deploy-monitor     # Deployment health
/loop 10m @log-scanner       # Log analysis
/loop 15m @pr-reviewer       # PR tracking
/loop 5m @build-watcher      # CI/CD monitoring
```

## Core Agents

### TMUX Watchdog (`@tmux-watchdog`)

Detects and recovers frozen LLM sessions. Runs `scripts/pane-watchdog.sh`.

**How it works:**
1. Takes content hash snapshots of each pane across multiple intervals
2. Checks for healthy prompt indicators (agent is idle but responsive vs truly frozen)
3. If a pane has no output change AND no healthy prompt beyond the frozen threshold (default: 120s):
   - Kills the entire process tree in the pane
   - Respawns with a fresh shell
   - Relaunches the LLM (`cc` for Claude Code, `cod` for Codex) based on detected agent type
   - Sends `register_agent` as the first prompt

**Configuration:**

| Flag | Default | Description |
|------|---------|-------------|
| `--session` | (required) | Tmux session name |
| `--frozen-threshold` | `120` | Seconds of inactivity before considered frozen |
| `--snapshot-interval` | `10` | Seconds between content snapshots |
| `--snapshot-checks` | `3` | Number of snapshots to compare |
| `--notes-dir` | (none) | Directory for daily finding logs |

**Key behaviors:**
- Skips pane 0 (NTM user/control pane)
- Rate-limited panes are not considered frozen
- Idle panes showing a healthy prompt are not frozen unless past the threshold
- Agent type detected via NTM patterns (Claude: opus/claude/sonnet/haiku keywords; Codex: codex/openai/gpt keywords)

### Auto-Prompter (`@auto-prompter`)

Keeps agents productive by sending prompts to idle panes. Runs `scripts/auto-prompt.sh`.

**How it works:**
1. Detects idle panes via content snapshots and NTM-style pattern matching
2. Selects a random prompt from the configured mix in `prompts.conf`
3. Sends the prompt via NTM's robot API
4. Marks the pane as "prompted" — it must show activity before receiving another prompt
5. Adds a random 2-5s delay between sends to prevent thundering herd

**Configuration:**

| Flag | Default | Description |
|------|---------|-------------|
| `--session` | (required) | Tmux session name |
| `--agent-type` | all | Filter by agent type: `cc` or `cod` |
| `--send-delay` | `2,5` | Random delay range (seconds) between sends |
| `--prompts-conf` | `prompts.conf` | Path to prompt list config |
| `--custom-prompts` | `custom-prompts.md` | Path to custom prompts file |
| `--notes-dir` | (none) | Directory for daily finding logs |

## Prompt Configuration

### `prompts.conf`

Defines the pool of prompts the auto-prompter randomly selects from. Supports two sources:

```
# NTM palette prompts — resolved from ~/.config/ntm/palettes/<name>.md
ntm:next_bead
ntm:work_on_your_beads
ntm:do_all_of_it

# Custom inline prompts — resolved from custom-prompts.md by heading name
custom:check-mail-and-continue
```

### `custom-prompts.md`

Define custom prompts inline. Each `# heading` is the prompt name, the text below is the prompt body, and `---` separates entries:

```markdown
# check-mail-and-continue
Carefully check your agent mail to see if you have any messages and respond
to them. Then pick the next bead and continue development. Make sure to
actively communicate and let your fellow agents know what you are working
on along with responding back whenever messages come in.

---

# review-and-refactor
Review the code you've written so far. Look for opportunities to simplify,
remove duplication, and improve readability. Then continue with your next task.
```

## Monitoring Agents

These agents are designed to be customized for your specific deployment environment.

### Deploy Monitor (`@deploy-monitor`)

Runs `scripts/health-check.sh` and `scripts/metrics-snapshot.sh` to check deployment health. Compares against previous findings and reports deltas.

**Included checks** (customize in scripts):
- Disk usage (warn >75%, critical >90%)
- Available memory
- HTTP endpoint health (commented out — configure for your services)

### Log Scanner (`@log-scanner`)

Runs `scripts/log-digest.sh` to filter and summarize recent logs. Detects error spikes, new error types, recurring failures, and anomalous patterns.

**Supported log sources:**
- Direct log file scanning (pass path as argument)
- macOS system logs (`log show`)
- Linux journal (`journalctl`)

### PR Reviewer (`@pr-reviewer`)

Uses `gh pr list` to track open pull requests. Classifies PRs as needing attention, stale, ready to merge, or blocked.

### Build Watcher (`@build-watcher`)

Uses `gh run list` to monitor GitHub Actions workflows. Alerts on new failures, tracks recoveries, and flags stuck builds.

## Report Format

All agents use the standardized loop-report format defined in `.claude/skills/loop-report/SKILL.md`:

```
[AGENT_NAME] [TIMESTAMP]

STATUS: healthy | warning | critical | info
CHANGES: Number of changes since last check

FINDINGS:
- [CRIT] Critical finding
- [WARN] Warning finding
- [INFO] Informational finding

ACTION NEEDED: Yes/No — description
```

When nothing changed:
```
[AGENT_NAME] [TIMESTAMP] — No changes. All healthy.
```

Agents write detailed findings to `loop-notes/` as daily append-only logs (e.g., `watchdog-2026-03-10.md`).

## State Management

Agents persist state across loop iterations:

| Agent | State Location | Purpose |
|-------|---------------|---------|
| Watchdog | `~/.ntm/watchdog-state/<session>/` | Tracks how long each pane has been idle |
| Auto-Prompter | `~/.ntm/auto-prompt-state/<session>/` | Tracks which panes have been prompted |
| All agents | `loop-notes/` | Daily finding logs for cross-iteration comparison |

## Customization

### Adding custom prompts

1. Add the prompt text to `custom-prompts.md` with a `# heading` and `---` separator
2. Add `custom:<heading-name>` to `prompts.conf`

### Adding NTM palette prompts

1. Place a `.md` file in `~/.config/ntm/palettes/`
2. Add `ntm:<filename-without-extension>` to `prompts.conf`

### Customizing health checks

Edit the scripts in `scripts/` — they include commented-out examples for:
- HTTP endpoint monitoring
- Process liveness checks
- Application-specific metrics
- Custom log paths

### Creating new agents

1. Create a new `.md` file in `.claude/agents/`
2. Optionally create a supporting script in `scripts/`
3. Start with `/loop <interval> @<agent-name>`

## License

MIT
