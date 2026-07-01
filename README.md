# Agents Team

> A group chat in your terminal between **you**, **Claude Code** and **Codex** — like a WhatsApp group with three members.

**English** · [Português](README.pt-BR.md)

You type, and the AI agents reply in the same conversation: they see each other's messages and yours, and react to one another. Under the hood the script keeps a single shared transcript and, on every message, sends the whole thread to each agent (via its CLI) and appends the reply — so everyone always sees the same conversation.

---

## Requirements

1. **Python 3** — check with `python3 --version`.
2. **Claude Code** installed and authenticated — check with `claude --version`.
3. **Codex CLI** installed and authenticated — check with `codex --version`.

**Platforms:** works out of the box on Linux, macOS and **WSL** (Windows Subsystem for Linux). On native Windows (PowerShell) the Python script runs the same, but the command setup is different and `claude`/`codex` must be installed as native Windows commands — see [Native Windows](#native-windows).

---

## Install

```bash
bash install.sh
```

The installer:

- creates the script at `~/scripts/agents_team.py`;
- creates the commands `agents-team` and `agents-team-personal` in `~/.local/bin`;
- makes sure `~/.local/bin` is on your PATH in the right startup file for your shell (it auto-detects **zsh** → `~/.zshrc` or **bash** → `~/.bashrc`).

If `~/.local/bin` is already on your PATH, the commands work immediately. Otherwise, open a new terminal or run the `export PATH=...` line printed by the installer.

> Prefer not to run a script? Save `agents_team.py` anywhere and add the command yourself:
> ```bash
> mkdir -p ~/.local/bin
> chmod +x /path/to/agents_team.py
> ln -sf /path/to/agents_team.py ~/.local/bin/agents-team
> ```

---

## Usage

Go into the project folder you want to talk about and run the command:

```bash
cd ~/path/to/your/project
agents-team
```

> Context comes from the folder you're in: run it inside a project and the agents see its content (`CLAUDE.md`, code). For a neutral chat, run it from an empty folder.

A `You:` prompt appears. From there:

| What you type | What happens |
|---|---|
| a message + Enter | **all** agents reply (the order rotates each round) |
| `@name message` | only that agent replies (e.g. `@codex what do you think?`) |
| empty Enter | the agents continue the conversation **among themselves** for one round |
| `/who` | show team members and who's muted |
| `/mute <name>` / `/unmute <name>` | silence or re-activate an agent (muted agents skip replies; `@name` still reaches them) |
| `/only <names>` / `/all` | activate only some agents, or everyone |
| `/clear` | start the conversation over (without restarting the program) |
| `/save` | save the current transcript to a `.md` file |
| `/rules` | view or edit shared rules all agents must follow (`/rules add <text>`, `/rules del <n>`, `/rules clear`) |
| `/cost` | show estimated token usage for the session |
| `/compact` | summarize older messages to shrink the prompt (saves input tokens) |
| `/parallel` | toggle simultaneous replies (faster; agents don't see each other within a round) |
| `/help` | show the commands |
| `/exit` | quit |

Replies call the real CLIs, so they take a few seconds per agent (you'll see "is typing…" meanwhile).

---

## Rules & cost

**Rules.** `/rules` shows the shared rules the agents must follow; `/rules add <text>` adds one, `/rules del <n>` removes one, and `/rules clear` wipes them. Rules are saved to `.team-rules.md` in the current folder (so each project has its own) and are injected into every agent's prompt. Rules that constrain output — e.g. *"answer in at most 5 sentences"* — are one of the most reliable ways to cut output tokens across all models.

**Cost.** After every reply the chat prints an estimated token count (input/output) for that call, and `/cost` shows the running total for the session. This is a rough estimate based on text length (~4 chars/token), not the model's exact tokenizer, and it doesn't include each CLI's own hidden system prompt — treat it as a gauge to compare turns and see the effect of your rules, not a billing figure.

**Muting (the biggest token lever).** With several agents, having everyone reply every turn multiplies cost. Use `/mute`, `/only` and `/all` to keep just the agents you need active for a given question — muted agents skip replies, but `@name` still reaches them for a one-off. `/who` shows the current state.

**Context compression.** As a conversation grows, the whole transcript is re-sent every turn, so input tokens climb. `/compact` summarizes older messages into a short block (keeping the most recent verbatim), cutting input tokens. It uses the `SUMMARIZER` model set at the top of the script — point it at a cheap/free model for real savings — and you can set `AUTO_COMPACT_TOKENS` to compact automatically past a threshold. If the summarizer fails, the history is left untouched.

**Parallel replies.** By default agents reply in sequence, so each sees the previous one's reply. With several agents that's slow; `/parallel` (or the `--parallel` flag) makes them reply simultaneously — much faster, but within a round they only see the previous round, not each other.

---

## Profiles & adding agents

A **profile** defines which agents are in the team and which command starts each one. Two commands are set up by default:

| Command | Starts |
|---|---|
| `agents-team` | the `work` profile (default) |
| `agents-team-personal` | the `personal` profile |
| `python3 ~/scripts/agents_team.py --profiles` | list configured profiles |
| `python3 ~/scripts/agents_team.py --profile NAME` | start a specific profile |

Profiles are independent, so you can run `work` in one terminal and `personal` in another at the same time.

### Where to configure it

At the top of `agents_team.py` there's a `PROFILES` block. Each profile is a **list of agents**; each agent has a `name`, a `cmd` (how to start the CLI) and, optionally, an `instruction` (its role):

```python
PROFILES = {
    "work": [
        {"name": "Claude", "cmd": ["claude", "-p"]},
        {"name": "Codex",  "cmd": ["codex", "exec"]},
    ],
    "personal": [
        # Example using alternative command names — adjust to your own setup.
        {"name": "Claude", "cmd": ["claude-pessoal", "-p"]},
        {"name": "Codex",  "cmd": ["codex-pessoal", "exec"]},
    ],
}
DEFAULT_PROFILE = "work"
```

> The `personal` profile is an **example** using alternative command names. Edit the `cmd` values to match commands that exist on your machine.

### Add an agent (and give it a role)

To add a third member, just add an item to the list. Filling `instruction` gives it a role — great for a built-in devil's advocate:

```python
    "review": [
        {"name": "Claude",  "cmd": ["claude", "-p"]},
        {"name": "Codex",   "cmd": ["codex", "exec"]},
        {"name": "Skeptic", "cmd": ["claude", "-p"],
         "instruction": "Your role is devil's advocate: question assumptions and flag risks and costs."},
    ],
```

Then run `python3 ~/scripts/agents_team.py --profile review`. You can have 2, 3 or more voices, mix work and personal commands, etc. Use **unique names** within a team (the `@name` mention uses the name).

---

### Adding other CLIs (OpenCode, Antigravity, …)

Any CLI with a headless "prompt in → text out" mode fits — add an entry with its `cmd`, and the prompt is appended as the last argument:

- **Antigravity:** `["agy", "-p"]`
- **OpenCode:** `["opencode", "run", "--model", "provider/model"]` — 75+ providers, so this one agent can be any model

Output is read as plain text by default (ANSI colors stripped). If a CLI emits JSON, add a `"parse"` field: `"json:result"` parses stdout as JSON and takes the `result` field; `"jsonl:msg.content"` reads streaming JSON lines and takes the last `msg.content` (dotted keys dig into nested JSON; on failure it falls back to plain text). Example — Claude in JSON mode:

```python
{"name": "Claude", "cmd": ["claude", "-p", "--output-format", "json"], "parse": "json:result"}
```

---

## Where saved files go

`/save` writes a `team_<profile>_<timestamp>.md` file **in the folder you run the command from**. If you run it inside your project, it lands next to the project.

---

## Troubleshooting

**`command not found: agents-team`**
Confirm `~/.local/bin` is on your PATH with `echo $PATH`. If it is missing, open a new terminal or run `export PATH="$HOME/.local/bin:$PATH"` in the current one.

**`[error] 'claude' (profile 'work') is not on your PATH`**
That profile's CLI wasn't found. Check it's installed and logged in (`claude --version`, `codex --version`) and that the name in `cmd`, inside the `PROFILES` block, is correct.

**Replies are slow / the chat got huge.** Each turn calls the real CLIs, so a few seconds per agent is expected. The whole transcript is re-sent every turn, so very long conversations get slower and pricier — use `/clear` to start fresh.

---

## Native Windows

On native Windows (no WSL), `agents_team.py` runs fine with Python, but:

- there's no bash-style command setup — start it directly with `python agents_team.py` (or define a function in your PowerShell profile);
- `claude` and `codex` must be installed as **Windows** commands and on the PATH (an install done inside WSL is not visible to native Windows).

If you already use WSL, staying there is the simplest path.

---

## Privacy

Saved transcripts (and any history) are plain text on disk. If a conversation includes personal data, store the files somewhere controlled. The included `.gitignore` already excludes `team_*.md` so you don't commit conversations to your repo by accident.

The agents have no memory between runs — each turn is re-sent with the current session's history. When you close the program, the conversation only persists if you used `/save`.

---

## License

MIT — see [LICENSE](LICENSE).
