#!/usr/bin/env bash
# Installer for Agents Team. Creates ~/scripts/agents_team.py and registers the commands.
set -e
mkdir -p ~/scripts
cat > ~/scripts/agents_team.py << 'AGENTS_TEAM_EOF'
#!/usr/bin/env python3
"""
agents_team.py — A group chat in your terminal between YOU and several AI agents
(Claude Code, Codex, and as many more as you like).

Like a WhatsApp group with several members: you type, and the agents reply in the
SAME conversation — they see each other's messages and yours, and react to one another.

Under the hood: a single shared transcript. On every message, the script sends the
whole thread to each agent (via its CLI) and appends the reply — so everyone always
sees the same conversation.

PROFILES: in the PROFILES dict below you assemble the teams. Each profile is a LIST
of agents; each agent has a "name", a "cmd" (how to start its CLI) and, optionally,
an "instruction" (its role). Switch teams with --profile:
  python agents_team.py                   -> default profile (work)
  python agents_team.py --profile personal
  python agents_team.py --profiles        -> list configured profiles

In the chat:
  - Type normally     -> ALL agents reply (the order rotates each round).
  - @name <msg>       -> only that agent replies (e.g. @codex ...).
  - (empty Enter)     -> the agents keep talking among themselves for one round.
  - /clear            -> start the conversation over.
  - /save             -> save the transcript to a .md file.
  - /exit             -> quit.
"""

import argparse
import datetime
import shutil
import subprocess
import sys
from pathlib import Path

# =============================================================================
# PROFILES — this is where you assemble the teams.
# Each profile is a list of agents. An agent = name + cmd (+ optional instruction).
# To "add an agent", add an item to the list. To give it a role, fill "instruction".
# Use unique names within a team (the @name mention uses the name).
# =============================================================================
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
    # Example with a 3rd agent playing devil's advocate. Uncomment to use: --profile review
    # "review": [
    #     {"name": "Claude",  "cmd": ["claude", "-p"]},
    #     {"name": "Codex",   "cmd": ["codex", "exec"]},
    #     {"name": "Skeptic", "cmd": ["claude", "-p"],
    #      "instruction": "Your role is devil's advocate: question assumptions and flag risks and costs."},
    # ],
}
DEFAULT_PROFILE = "work"

TIMEOUT_S = 180  # max seconds per agent reply

# --- ANSI colors (auto-off if output isn't a terminal) ----------------------
_TTY = sys.stdout.isatty()


def _c(code):
    return code if _TTY else ""


BOLD = _c("\033[1m")
GRAY = _c("\033[90m")
GREEN = _c("\033[32m")
RESET = _c("\033[0m")
PALETTE = [_c("\033[36m"), _c("\033[33m"), _c("\033[35m"), _c("\033[34m"), _c("\033[31m")]


def render(transcript):
    return "\n".join(f"{who}: {text}" for who, text in transcript)


def strip_name_prefix(text, name):
    """Remove a leading 'Name:' the model might prepend to its reply."""
    for pref in (f"{name}:", f"{name.lower()}:", f"{name.upper()}:"):
        if text.startswith(pref):
            return text[len(pref):].strip()
    return text


def build_prompt(agent, others, transcript):
    role = f"\n{agent['instruction']}" if agent.get("instruction") else ""
    other_names = ", ".join(others) if others else "no one else"
    return f"""You are {agent['name']}, a member of a group chat (WhatsApp style) with the user ("You") and: {other_names}.{role}

Reply AS {agent['name']}, in a conversational tone: short and direct (1 to 4 sentences), without writing your name in front. You may agree, disagree, or raise a new point. Don't repeat what was already said. Reply in the same language the conversation is happening in.

Conversation so far:
{render(transcript)}

{agent['name']}:"""


def run_agent(agent, others, transcript):
    """Call the agent's CLI with the whole thread; return its reply."""
    try:
        proc = subprocess.run(
            agent["cmd"] + [build_prompt(agent, others, transcript)],
            capture_output=True, text=True, timeout=TIMEOUT_S,
        )
    except FileNotFoundError:
        return f"(command '{agent['cmd'][0]}' not found)"
    except subprocess.TimeoutExpired:
        return f"(no reply — timed out after {TIMEOUT_S}s)"
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        return f"(error: {detail[:300]})"
    return strip_name_prefix(proc.stdout.strip(), agent["name"]) or "(nothing to add)"


def speak(agent, agents, transcript):
    """Show 'is typing…', get the reply, print it and append to the thread."""
    others = [a["name"] for a in agents if a is not agent]
    color = agent["_color"]
    print(f"{color}{agent['name']} is typing…{RESET}", flush=True)
    reply = run_agent(agent, others, transcript)
    transcript.append((agent["name"], reply))
    print(f"{color}{BOLD}{agent['name']}{RESET}{color}: {reply}{RESET}")
    sys.stdout.flush()


def round_robin(agents, order, transcript):
    """Everyone speaks, in the current order; returns the rotated order for next time."""
    for i in order:
        speak(agents[i], agents, transcript)
    return order[1:] + order[:1]


def find_agent(agents, token):
    """Find an agent by name (case-insensitive; accepts a prefix)."""
    t = token.lower()
    for a in agents:
        if a["name"].lower() == t:
            return a
    for a in agents:
        if a["name"].lower().startswith(t):
            return a
    return None


def save(transcript, profile):
    if not transcript:
        print(f"{GRAY}(nothing to save yet){RESET}")
        return
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    out = Path(f"team_{profile}_{ts}.md")
    out.write_text(
        f"# Team conversation ({profile})\n\n"
        + "\n\n".join(f"**{who}:** {text}" for who, text in transcript)
        + "\n",
        encoding="utf-8",
    )
    print(f"{GRAY}saved to {out.resolve()}{RESET}")


def list_profiles():
    print("Available teams:")
    for name, agents in PROFILES.items():
        mark = "  (default)" if name == DEFAULT_PROFILE else ""
        who = ", ".join(a["name"] for a in agents)
        print(f"  - {name}{mark}: {who}")


def main():
    ap = argparse.ArgumentParser(description="Group chat: You + AI agents.")
    ap.add_argument("--profile", choices=list(PROFILES), default=DEFAULT_PROFILE,
                    help=f"Which team to use (default: {DEFAULT_PROFILE}).")
    ap.add_argument("--profiles", action="store_true", help="List teams and exit.")
    args = ap.parse_args()

    if args.profiles:
        list_profiles()
        return

    agents = [dict(a) for a in PROFILES[args.profile]]  # copy to attach color w/o touching PROFILES
    for i, a in enumerate(agents):
        a["_color"] = PALETTE[i % len(PALETTE)] if PALETTE else ""

    # Check the binaries (without repeating the same one)
    for binary in {a["cmd"][0] for a in agents}:
        if shutil.which(binary) is None:
            sys.exit(f"[error] '{binary}' (profile '{args.profile}') is not on your PATH — "
                     f"check the name in the PROFILES dict or whether the CLI is installed/logged in.")

    names = " + ".join(a["name"] for a in agents)
    print(f"{BOLD}Team [{args.profile}]: You + {names}{RESET}")
    print(f"{GRAY}Everyone replies. '@name' talks to one. Empty Enter = they continue. "
          f"'/clear' resets · '/save' saves · '/exit' quits.{RESET}")

    transcript = []
    order = list(range(len(agents)))

    while True:
        try:
            msg = input(f"\n{GREEN}{BOLD}You{RESET}{GREEN}: {RESET}").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n(bye)")
            break

        if msg in ("/exit", "/quit", "/sair"):
            break
        if msg == "/save":
            save(transcript, args.profile)
            continue
        if msg == "/clear":
            transcript.clear()
            order = list(range(len(agents)))
            print(f"{GRAY}(conversation cleared){RESET}")
            continue
        if msg in ("/help", "/ajuda"):
            print(f"{GRAY}@name talks to one · empty Enter = they continue · /clear · /save · /exit{RESET}")
            continue

        try:
            if msg == "":  # empty Enter -> agents continue among themselves
                if transcript:
                    order = round_robin(agents, order, transcript)
                continue

            if msg.startswith("@") and len(msg) > 1:
                token = msg[1:].split(None, 1)[0]
                target = find_agent(agents, token)
                if target is not None:
                    rest = msg[1 + len(token):].strip()
                    transcript.append(("You", rest or "(continue)"))
                    speak(target, agents, transcript)
                    continue
                # @ with no valid name: fall through to normal flow

            transcript.append(("You", msg))
            order = round_robin(agents, order, transcript)
        except KeyboardInterrupt:
            print(f"\n{GRAY}(interrupted — back to the chat){RESET}")


if __name__ == "__main__":
    main()
AGENTS_TEAM_EOF

# Pick the rc file for the user's shell so the command is found
case "${SHELL##*/}" in
  zsh) RC="$HOME/.zshrc" ;;
  *)   RC="$HOME/.bashrc" ;;
esac

add_alias() { grep -qxF "$1" "$RC" 2>/dev/null || echo "$1" >> "$RC"; }
add_alias "alias agents-team='python3 ~/scripts/agents_team.py'"
add_alias "alias agents-team-personal='python3 ~/scripts/agents_team.py --profile personal'"

echo "Installed. Aliases added to $RC."
echo "Open a new terminal (or run: source $RC), then run:  agents-team"
