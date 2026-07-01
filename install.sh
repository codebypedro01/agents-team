#!/usr/bin/env bash
# Installer for Agents Team. Creates ~/scripts/agents_team.py and registers the commands.
set -e
mkdir -p ~/scripts
cat > ~/scripts/agents_team.py << 'AGENTS_TEAM_EOF'
#!/usr/bin/env python3
"""
agents_team.py — A group chat in your terminal between YOU and several AI agents.

Works with any coding-agent CLI that has a headless "prompt in -> text out" mode:
Claude Code (claude -p), Codex (codex exec), Google Antigravity (agy -p),
OpenCode (opencode run --model ...), and others. You type, and the agents reply in
the SAME shared conversation, seeing each other's messages and reacting.

Under the hood: a single shared transcript. On every message, the script sends the
whole thread to each active agent (via its CLI) and appends the reply.

PROFILES: in the PROFILES dict below you assemble the teams. Each profile is a LIST
of agents. An agent has:
  - "name": display name (also used by @name).
  - "cmd" : how to start the CLI in headless mode; the prompt is appended as the
            last argument. e.g. ["claude","-p"], ["codex","exec"], ["agy","-p"],
            ["opencode","run","--model","provider/model"].
  - "instruction": (optional) a role, injected into that agent's prompt.
  - "parse": (optional) how to read the reply from the CLI's output:
        "text"  (default)  -> use stdout as-is (ANSI colors stripped)
        "json:result"      -> parse stdout as JSON, take the "result" field
        "jsonl:msg.content"-> parse JSON-lines (streaming), take the last "msg.content"
      Dotted keys dig into nested JSON. If parsing fails, it falls back to text.

Chat commands: see /help. Highlights for saving tokens:
  /rules   — shared rules injected into every prompt (e.g. "answer in <=5 sentences").
  /mute    — silence agents you don't need this turn.
  /compact — summarize older messages to shrink the prompt (input tokens).
  /cost    — estimated token usage so far.
"""

import argparse
import datetime
import json
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# =============================================================================
# PROFILES — this is where you assemble the teams (see the module docstring for
# the full field reference, including "parse" for CLIs that emit JSON).
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
    # --- More examples (uncomment and adjust; needs the extra CLIs installed) ---
    # A third voice playing devil's advocate:
    # "review": [
    #     {"name": "Claude",  "cmd": ["claude", "-p"]},
    #     {"name": "Codex",   "cmd": ["codex", "exec"]},
    #     {"name": "Skeptic", "cmd": ["claude", "-p"],
    #      "instruction": "Your role is devil's advocate: question assumptions and flag risks and costs."},
    # ],
    # Mixing other CLIs (Antigravity + OpenCode). Output is plain text by default:
    # "multi": [
    #     {"name": "Claude",   "cmd": ["claude", "-p"]},
    #     {"name": "Gemini",   "cmd": ["agy", "-p"]},                                  # Google Antigravity
    #     {"name": "OpenCode", "cmd": ["opencode", "run", "--model", "openrouter/your-model"]},
    # ],
}
DEFAULT_PROFILE = "work"

TIMEOUT_S = 180  # max seconds per agent reply

# --- Context compression (/compact) ------------------------------------------
# When the shared transcript gets long, older messages are summarized into a
# compact block to cut INPUT tokens sent to the (expensive) agents.
# Point SUMMARIZER at a CHEAP/free model for this to actually save money.
SUMMARIZER = {"cmd": ["claude", "-p"], "parse": "text"}
# e.g. a free/small model via OpenCode:
# SUMMARIZER = {"cmd": ["opencode", "run", "--model", "opencode/grok-code"], "parse": "text"}
KEEP_RECENT = 6            # most recent messages kept verbatim; older ones get summarized
AUTO_COMPACT_TOKENS = 0    # auto-compact when transcript exceeds ~this many tokens (0 = off)

# --- Parallel replies ---------------------------------------------------------
# When True, active agents reply simultaneously (faster with several agents), but
# they don't see each other's reply within the same round. Toggle live with /parallel.
PARALLEL = False

RULES_FILE = Path(".team-rules.md")   # per-project rules, in the current folder
RULES = []                            # loaded at startup, injected into every prompt
USAGE = {"in": 0, "out": 0}           # estimated token counters for the session

# --- ANSI colors (auto-off if output isn't a terminal) ----------------------
_TTY = sys.stdout.isatty()


def _c(code):
    return code if _TTY else ""


BOLD = _c("\033[1m")
GRAY = _c("\033[90m")
GREEN = _c("\033[32m")
RESET = _c("\033[0m")
PALETTE = [_c("\033[36m"), _c("\033[33m"), _c("\033[35m"), _c("\033[34m"), _c("\033[31m")]

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def strip_ansi(text):
    return _ANSI_RE.sub("", text)


def estimate_tokens(text):
    """Rough token estimate from text length (~4 chars/token). Not an exact tokenizer."""
    return max(1, round(len(text) / 4))


def render(transcript):
    return "\n".join(f"{who}: {text}" for who, text in transcript)


def strip_name_prefix(text, name):
    """Remove a leading 'Name:' the model might prepend to its reply."""
    for pref in (f"{name}:", f"{name.lower()}:", f"{name.upper()}:"):
        if text.startswith(pref):
            return text[len(pref):].strip()
    return text


def _dig(obj, dotted):
    cur = obj
    for part in dotted.split("."):
        if isinstance(cur, dict):
            cur = cur[part]
        else:
            raise KeyError(part)
    return cur


def extract_reply(agent, stdout):
    """Pull the reply text out of a CLI's stdout, per the agent's 'parse' setting."""
    mode = agent.get("parse", "text")
    try:
        if mode.startswith("json:"):
            return str(_dig(json.loads(stdout), mode[5:])).strip()
        if mode.startswith("jsonl:"):
            key, val = mode[6:], None
            for line in stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    v = _dig(json.loads(line), key)
                    if v is not None:
                        val = v
                except (json.JSONDecodeError, KeyError, TypeError):
                    continue
            if val is not None:
                return str(val).strip()
    except (json.JSONDecodeError, KeyError, TypeError):
        pass  # fall back to plain text
    return strip_ansi(stdout).strip()


# --- Rules --------------------------------------------------------------------
def load_rules():
    RULES.clear()
    if RULES_FILE.exists():
        for line in RULES_FILE.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("- "):
                RULES.append(line[2:].strip())


def save_rules():
    body = "# Team rules\n\n" + "".join(f"- {r}\n" for r in RULES)
    RULES_FILE.write_text(body, encoding="utf-8")


def show_rules():
    if RULES:
        print(f"{GRAY}Team rules ({RULES_FILE}):{RESET}")
        for i, r in enumerate(RULES, 1):
            print(f"{GRAY}  {i}. {r}{RESET}")
    else:
        print(f"{GRAY}(no rules yet) — add one with: /rules add <text>{RESET}")


def handle_rules(msg):
    parts = msg.split(None, 2)
    sub = parts[1].lower() if len(parts) > 1 else ""
    arg = parts[2].strip() if len(parts) > 2 else ""
    if sub == "add" and arg:
        RULES.append(arg)
        save_rules()
        print(f"{GRAY}rule added ({len(RULES)} total){RESET}")
    elif sub == "clear":
        RULES.clear()
        save_rules()
        print(f"{GRAY}rules cleared{RESET}")
    elif sub == "del" and arg.isdigit():
        i = int(arg) - 1
        if 0 <= i < len(RULES):
            removed = RULES.pop(i)
            save_rules()
            print(f"{GRAY}removed: {removed}{RESET}")
        else:
            print(f"{GRAY}no rule #{arg}{RESET}")
    else:
        show_rules()


def show_cost():
    print(f"{GRAY}Session so far (estimated): ~{USAGE['in']:,} tok in · ~{USAGE['out']:,} tok out{RESET}")
    print(f"{GRAY}(rough estimate from text length, not the model's exact tokenizer){RESET}")


# --- Context compression ------------------------------------------------------
def compact(transcript):
    """Summarize older messages into one block, keeping the most recent verbatim.
    Returns a new transcript. On summarizer failure, returns the input unchanged."""
    if len(transcript) <= KEEP_RECENT + 1:
        print(f"{GRAY}(not enough history to compact){RESET}")
        return transcript
    older, recent = transcript[:-KEEP_RECENT], transcript[-KEEP_RECENT:]
    before = estimate_tokens(render(transcript))
    print(f"{GRAY}compacting {len(older)} older messages…{RESET}", flush=True)
    prompt = ("Summarize the conversation below compactly. Preserve decisions made, key facts, "
              "names, and open questions as short bullet points. Output only the summary.\n\n"
              + render(older))
    summarizer = {"name": "Summary", "cmd": SUMMARIZER["cmd"], "parse": SUMMARIZER.get("parse", "text")}
    summary = run_agent(summarizer, prompt)
    if not summary.strip() or summary.startswith("("):
        print(f"{GRAY}summarizer failed — history unchanged (check SUMMARIZER in the script){RESET}")
        return transcript
    new_t = [("Summary of earlier conversation", summary)] + recent
    print(f"{GRAY}compacted: ~{before:,} → ~{estimate_tokens(render(new_t)):,} tok of history{RESET}")
    return new_t


# --- Team / participation -----------------------------------------------------
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


def set_active(agents, tokens, value):
    """Set _active=value for agents matching the given name tokens. Returns matched agents."""
    matched = []
    for tok in tokens:
        a = find_agent(agents, tok)
        if a and a not in matched:
            a["_active"] = value
            matched.append(a)
    return matched


def show_team(agents):
    print(f"{GRAY}Team members ({'●' if _TTY else '*'} active · {'○' if _TTY else '-'} muted):{RESET}")
    for a in agents:
        active = a.get("_active", True)
        dot = ("●" if active else "○") if _TTY else ("*" if active else "-")
        state = "active" if active else "muted"
        print(f"{a['_color']}  {dot} {a['name']}{RESET}{GRAY} ({state}){RESET}")


# --- Prompt & agent calls -----------------------------------------------------
def build_prompt(agent, others, transcript):
    role = f"\n{agent['instruction']}" if agent.get("instruction") else ""
    other_names = ", ".join(others) if others else "no one else"
    rules_block = ""
    if RULES:
        rules_block = "\n\nTeam rules (all members must follow these):\n" + "".join(f"- {r}\n" for r in RULES)
    return f"""You are {agent['name']}, a member of a group chat (WhatsApp style) with the user ("You") and: {other_names}.{role}{rules_block}

Reply AS {agent['name']}, in a conversational tone: short and direct (1 to 4 sentences), without writing your name in front. You may agree, disagree, or raise a new point. Don't repeat what was already said. Reply in the same language the conversation is happening in.

Conversation so far:
{render(transcript)}

{agent['name']}:"""


def run_agent(agent, prompt):
    """Call the agent's CLI with the given prompt; return its reply."""
    try:
        proc = subprocess.run(
            agent["cmd"] + [prompt],
            capture_output=True, text=True, timeout=TIMEOUT_S,
        )
    except FileNotFoundError:
        return f"(command '{agent['cmd'][0]}' not found)"
    except subprocess.TimeoutExpired:
        return f"(no reply — timed out after {TIMEOUT_S}s)"
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        return f"(error: {detail[:300]})"
    return strip_name_prefix(extract_reply(agent, proc.stdout), agent["name"]) or "(nothing to add)"


def speak(agent, agents, transcript):
    """Build the prompt, get the reply, print it (+ usage), append to the thread."""
    others = [a["name"] for a in agents if a is not agent]
    prompt = build_prompt(agent, others, transcript)
    color = agent["_color"]
    print(f"{color}{agent['name']} is typing…{RESET}", flush=True)
    reply = run_agent(agent, prompt)
    transcript.append((agent["name"], reply))
    in_tok, out_tok = estimate_tokens(prompt), estimate_tokens(reply)
    USAGE["in"] += in_tok
    USAGE["out"] += out_tok
    print(f"{color}{BOLD}{agent['name']}{RESET}{color}: {reply}{RESET}")
    print(f"{GRAY}  ~{in_tok:,} tok in · ~{out_tok:,} tok out{RESET}")
    sys.stdout.flush()


def round_robin(agents, order, transcript):
    """Active agents speak, in the current order; returns the rotated order for next time."""
    for i in order:
        if agents[i].get("_active", True):
            speak(agents[i], agents, transcript)
    return order[1:] + order[:1]


def round_parallel(agents, order, transcript):
    """Active agents reply concurrently from the same snapshot (they don't see each
    other within this round). Appends/prints in order; returns the rotated order."""
    active = [agents[i] for i in order if agents[i].get("_active", True)]
    if not active:
        return order[1:] + order[:1]
    tasks = []
    for ag in active:
        others = [a["name"] for a in agents if a is not ag]
        tasks.append((ag, build_prompt(ag, others, transcript)))
    print(f"{GRAY}{len(active)} agents thinking in parallel…{RESET}", flush=True)
    with ThreadPoolExecutor(max_workers=len(tasks)) as ex:
        replies = list(ex.map(lambda pair: run_agent(pair[0], pair[1]), tasks))
    for (ag, prompt), reply in zip(tasks, replies):   # append/print in main thread (no races)
        transcript.append((ag["name"], reply))
        in_tok, out_tok = estimate_tokens(prompt), estimate_tokens(reply)
        USAGE["in"] += in_tok
        USAGE["out"] += out_tok
        color = ag["_color"]
        print(f"{color}{BOLD}{ag['name']}{RESET}{color}: {reply}{RESET}")
        print(f"{GRAY}  ~{in_tok:,} tok in · ~{out_tok:,} tok out{RESET}")
    sys.stdout.flush()
    return order[1:] + order[:1]


def maybe_auto_compact(transcript):
    """Auto-compact if enabled and the transcript is over the token threshold."""
    if AUTO_COMPACT_TOKENS and estimate_tokens(render(transcript)) > AUTO_COMPACT_TOKENS:
        print(f"{GRAY}(history over ~{AUTO_COMPACT_TOKENS:,} tok — auto-compacting){RESET}")
        return compact(transcript)
    return transcript


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
    ap.add_argument("--parallel", action="store_true",
                    help="Agents reply simultaneously (faster; they don't see each other within a round).")
    args = ap.parse_args()

    if args.profiles:
        list_profiles()
        return

    agents = [dict(a) for a in PROFILES[args.profile]]  # copy to attach state w/o touching PROFILES
    for i, a in enumerate(agents):
        a["_color"] = PALETTE[i % len(PALETTE)] if PALETTE else ""
        a["_active"] = True

    for binary in {a["cmd"][0] for a in agents}:
        if shutil.which(binary) is None:
            sys.exit(f"[error] '{binary}' (profile '{args.profile}') is not on your PATH — "
                     f"check the name in the PROFILES dict or whether the CLI is installed/logged in.")

    load_rules()

    names = " + ".join(a["name"] for a in agents)
    print(f"{BOLD}Team [{args.profile}]: You + {names}{RESET}")
    if RULES:
        print(f"{GRAY}{len(RULES)} rule(s) active from {RULES_FILE}.{RESET}")
    print(f"{GRAY}Active agents reply. '@name' talks to one (even if muted). "
          f"'/who' · '/mute' · '/rules' · '/compact' · '/cost' · '/help' · '/exit'.{RESET}")

    transcript = []
    order = list(range(len(agents)))
    parallel = args.parallel or PARALLEL

    def do_round(order):
        return (round_parallel if parallel else round_robin)(agents, order, transcript)

    while True:
        try:
            msg = input(f"\n{GREEN}{BOLD}You{RESET}{GREEN}: {RESET}").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n(bye)")
            if USAGE["in"] or USAGE["out"]:
                show_cost()
            break

        if msg in ("/exit", "/quit", "/sair"):
            if USAGE["in"] or USAGE["out"]:
                show_cost()
            break
        if msg == "/save":
            save(transcript, args.profile)
            continue
        if msg == "/cost":
            show_cost()
            continue
        if msg == "/compact":
            transcript = compact(transcript)
            continue
        if msg == "/parallel":
            parallel = not parallel
            how = "simultaneously (faster; they see each other only next round)" if parallel else "in sequence (each sees the previous reply)"
            print(f"{GRAY}parallel mode {'on' if parallel else 'off'} — agents reply {how}{RESET}")
            continue
        if msg == "/who":
            show_team(agents)
            continue
        if msg == "/all":
            for a in agents:
                a["_active"] = True
            print(f"{GRAY}all agents active{RESET}")
            continue
        if msg.startswith("/only "):
            matched = []
            for tk in msg.split()[1:]:
                a = find_agent(agents, tk)
                if a and a not in matched:
                    matched.append(a)
            if matched:
                for a in agents:
                    a["_active"] = a in matched
                print(f"{GRAY}only active: {', '.join(a['name'] for a in matched)}{RESET}")
            else:
                print(f"{GRAY}no matching agent — team unchanged{RESET}")
            continue
        if msg.startswith("/mute ") or msg.startswith("/unmute "):
            parts = msg.split()
            value = parts[0] == "/unmute"
            changed = set_active(agents, parts[1:], value)
            if changed:
                print(f"{GRAY}{'unmuted' if value else 'muted'}: {', '.join(a['name'] for a in changed)}{RESET}")
            else:
                print(f"{GRAY}no matching agent{RESET}")
            continue
        if msg == "/rules" or msg.startswith("/rules "):
            handle_rules(msg)
            continue
        if msg == "/clear":
            transcript.clear()
            order = list(range(len(agents)))
            USAGE["in"] = USAGE["out"] = 0
            print(f"{GRAY}(conversation cleared){RESET}")
            continue
        if msg in ("/help", "/ajuda"):
            print(f"{GRAY}@name talks to one (even if muted) · empty Enter = active agents continue{RESET}")
            print(f"{GRAY}/who · /mute <name> · /unmute <name> · /only <names> · /all{RESET}")
            print(f"{GRAY}/rules · /compact · /parallel · /cost · /clear · /save · /exit{RESET}")
            continue

        try:
            if msg == "":  # empty Enter -> active agents continue among themselves
                if transcript:
                    order = do_round(order)
                    transcript = maybe_auto_compact(transcript)
                continue

            if msg.startswith("@") and len(msg) > 1:
                token = msg[1:].split(None, 1)[0]
                target = find_agent(agents, token)
                if target is not None:
                    rest = msg[1 + len(token):].strip()
                    transcript.append(("You", rest or "(continue)"))
                    speak(target, agents, transcript)  # mention overrides mute
                    transcript = maybe_auto_compact(transcript)
                    continue
                # @ with no valid name: fall through to normal flow

            active = [a for a in agents if a.get("_active", True)]
            if not active:
                print(f"{GRAY}(everyone is muted — use @name to poke one, or /all to unmute){RESET}")
                continue
            transcript.append(("You", msg))
            order = do_round(order)
            transcript = maybe_auto_compact(transcript)
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
