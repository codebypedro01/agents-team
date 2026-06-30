# Agents Team

> A group chat in your terminal between **you**, **Claude Code** and **Codex** — like a WhatsApp group with three members.

**English** · [Português](README.pt-BR.md)

You type, and the AI agents reply in the same conversation: they see each other's messages and yours, and react to one another. Under the hood the script keeps a single shared transcript and, on every message, sends the whole thread to each agent (via its CLI) and appends the reply — so everyone always sees the same conversation.

---

## Requirements

1. **Python 3** — check with `python3 --version`.
2. **Claude Code** installed and authenticated — check with `claude --version`.
3. **Codex CLI** installed and authenticated — check with `codex --version`.

**Platforms:** works out of the box on Linux, macOS and **WSL** (Windows Subsystem for Linux). On native Windows (PowerShell) the Python script runs the same, but the alias step is different and `claude`/`codex` must be installed as native Windows commands — see [Native Windows](#native-windows).

---

## Install

```bash
bash install.sh
```

The installer:

- creates the script at `~/scripts/agents_team.py`;
- registers the commands `agents-team` and `agents-team-personal` in the right startup file for your shell (it auto-detects **zsh** → `~/.zshrc` or **bash** → `~/.bashrc`).

After installing, **open a new terminal** (or run `source ~/.zshrc` / `source ~/.bashrc`) so the commands take effect.

> Prefer not to run a script? Save `agents_team.py` anywhere and add the alias yourself:
> ```bash
> echo "alias agents-team='python3 /path/to/agents_team.py'" >> ~/.zshrc   # or ~/.bashrc
> source ~/.zshrc
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
| `/clear` | start the conversation over (without restarting the program) |
| `/save` | save the current transcript to a `.md` file |
| `/help` | show the commands |
| `/exit` | quit |

Replies call the real CLIs, so they take a few seconds per agent (you'll see "is typing…" meanwhile).

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

## Where saved files go

`/save` writes a `team_<profile>_<timestamp>.md` file **in the folder you run the command from**. If you run it inside your project, it lands next to the project.

---

## Troubleshooting

**`command not found: agents-team`**
Open a new terminal — the alias only applies to shells started after install. If it still fails, confirm the alias is in your shell's startup file (`~/.zshrc` for zsh, `~/.bashrc` for bash) and run `source` on it.

**`[error] 'claude' (profile 'work') is not on your PATH`**
That profile's CLI wasn't found. Check it's installed and logged in (`claude --version`, `codex --version`) and that the name in `cmd`, inside the `PROFILES` block, is correct.

**Replies are slow / the chat got huge.** Each turn calls the real CLIs, so a few seconds per agent is expected. The whole transcript is re-sent every turn, so very long conversations get slower and pricier — use `/clear` to start fresh.

---

## Native Windows

On native Windows (no WSL), `agents_team.py` runs fine with Python, but:

- there's no `bash`/`alias` — start it directly with `python agents_team.py` (or define a function in your PowerShell profile);
- `claude` and `codex` must be installed as **Windows** commands and on the PATH (an install done inside WSL is not visible to native Windows).

If you already use WSL, staying there is the simplest path.

---

## Privacy

Saved transcripts (and any history) are plain text on disk. If a conversation includes personal data, store the files somewhere controlled. The included `.gitignore` already excludes `team_*.md` so you don't commit conversations to your repo by accident.

The agents have no memory between runs — each turn is re-sent with the current session's history. When you close the program, the conversation only persists if you used `/save`.

---

## License

MIT — see [LICENSE](LICENSE).
