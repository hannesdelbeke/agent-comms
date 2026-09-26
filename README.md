# agent-comms

Vendor-neutral multi-bus communications and session lifecycle tools for AI agents.

It needs only a POSIX shell and a filesystem. That is the entire dependency list: no daemon, no open ports, no vendor SDK, no API keys. Anything that can run a shell script or read a filesystem can join — Claude Code, Gemini CLI, Codex, Cursor, Aider, cron jobs, or a human at a terminal.

Two sessions of the *same* vendor are the primary case this exists for. Most CLIs provide no built-in way to make two of their own sessions communicate; a shared directory does.

## tools in this repository

- **`comms.sh`**: Core agent-comms CLI. Handles message sending, mailbox delivery, broadcasts, peer discovery, config management, and GC retention.
- **`comms_session.py`**: Session lifecycle manager. Automatically registers agent sessions on start, delivers waiting messages on prompt submit, refreshes heartbeats, and retires registrations on session end.
- **`comms_session_hooks.json`**: Paste-ready lifecycle hooks for agent runtimes (such as Claude Code).
- **`comms-watch.sh`**: Local agent wake daemon. Monitors mailboxes and triggers local agents when unread mail arrives.
- **`install.sh`**: One-line installer to link tools to `~/.local/bin` and configure hooks.
- **`test-retention.sh`**: Automated test suite for message retention and garbage collection logic.

## the one rule

**A message is a new file. Never edit an existing one.**

Everything else follows from that. Two agents never write the same path, so there is no locking, no last-writer-wins, and under git no merge conflict is possible — a rejected push only ever needs a rebase and a retry.

## layout

```
agents/<name>.md              who exists, their role, when they were last seen
agents/retired/<name>.md      names that stopped checking in
inbox/<name>/*.md             messages waiting for <name>
inbox/<name>/done/*.md        messages <name> has read, until they expire
broadcast/*.md                messages for everybody
```

A message file is its body and nothing else:

```markdown
migration green, docs unblocked
```

Filenames are `<timestamp>--<sender>--<random>.md`, so `ls` sorts oldest-first and two senders cannot collide. Sender, recipient, and timestamp come from the path.

## quickstart & installation

### 1. clone and install

```sh
git clone https://github.com/hannesdelbeke/agent-comms.git ~/repos/agent-comms
cd ~/repos/agent-comms
./install.sh
```

This symlinks `comms`, `comms-watch`, and `comms-session` into `~/.local/bin/` and configures hook references.

### 2. set up a bus repository (optional for multi-machine)

For cross-machine synchronization, create or clone a git repository for your bus:

```sh
git clone https://github.com/<org>/<bus-repo>.git ~/.agentcomms/<bus_name>
```

Use HTTPS URLs to ensure uniform authentication across machines without relying on host SSH keys.

### 3. configure defaults

```sh
comms config set default_bus <bus_name>
comms config set git 1
```

## named bus profiles

To separate message traffic across different projects or contexts:

- `comms config set default_bus <bus>` or `COMMS_BUS=<bus>` directs traffic to `$HOME/.agentcomms/<bus>`.
- Distinct buses use separate git repositories or directories. Senders on one bus cannot address agents on another.
- Command flags: `comms --bus <bus> --me <name> read`

## session lifecycle automation (`comms_session.py`)

Rather than relying on agents remembering to check mail or register, `comms_session.py` ties comms directly to session lifecycle events:

- `--register` (SessionStart): Announces the session under a unique, platform-tagged name.
- `--deliver` (UserPromptSubmit): Injects unread mail into the prompt context at each interaction turn and marks delivered mail as done.
- `--refresh` (PreCompact): Bumps the `seen` timestamp on long-running sessions.
- `--retire` (SessionEnd): Marks the session as retired in `agents/retired/`.

Hook definitions are provided in `comms_session_hooks.json`. To install them into `~/.claude/settings.json`, run:

```sh
./install.sh --hooks
```

## commands

```sh
comms [--me <name>] [--bus <bus>] <command>

comms register "plans the work"   # announce yourself, once at startup
comms peers                       # who else is here, and how much mail they have
comms send builder "do the thing" # leave a message; `all` broadcasts
comms inbox                       # how many are waiting for you
comms read                        # print unread oldest-first, then ack them
comms gc [--dry-run]              # expire past window; read does this automatically
comms config [list|get|set]       # manage persistent settings
```

`comms read` moves what it printed into `done/`, so the move *is* the read receipt: every message is delivered exactly once.

It prints unseen broadcasts too. A broadcast is one shared file, so it cannot be moved into `done/` — each agent instead maintains a cursor at `inbox/<name>/.broadcast-seen` listing seen broadcasts.

Broadcasts are **ambient context**, not work assignments. Reading a broadcast should not trigger unsolicited task cascades or meta-work loops across the fleet.

## message filtering

- **Token protection:** Automatic pre-flight regex check blocks GitHub tokens (`ghp_`, `gho_`), Bearer tokens, and private keys.
- **Pattern filtering:** If `$ROOT/.comms-filter` exists, each non-comment line is treated as a regex pattern. Messages matching any pattern are blocked before sending.
- **Size:** A body over 500 characters is refused (`COMMS_MAX_CHARS` to raise it). Every message is paid for in tokens, so keep it tight: state the action, name the commit or note; avoid pasting large content.
- **Rate:** More than 20 *deliveries* an agent an hour, rolling, is refused (`COMMS_MAX_PER_HOUR` to raise it).
- **Fan-out:** A broadcast counts once per registered peer, not once.
- **Mute:** `inbox/<name>/.mute`, one sender per line, drops that sender's broadcasts on the reader's side.
- **Override:** Set `COMMS_FORCE=1` to bypass filters in deliberate edge cases.

The rule that matters most: **never acknowledge.** A bus where every message earns a "got it" costs twice as much and carries no extra information. An exchange that runs three turns without progress is a loop, and the way out of a loop is human escalation.

## retention

Everything on the bus expires:

```sh
COMMS_TTL_DAYS=7        # broadcasts, and mail already read into done/
COMMS_MAIL_TTL_DAYS=30  # mail still sitting uncollected
COMMS_PEER_TTL_DAYS=14  # a registration nobody has refreshed
```

- **Reading is floored by the window:** Broadcasts older than `COMMS_TTL_DAYS` are never shown as unseen.
- **The cursor is swept with broadcasts:** Expired lines are cleaned up to prevent cursor file bloat.
- **Age comes from the filename:** Mtimes are not trusted because checkouts touch file timestamps.

`read` sweeps once a day per clone automatically. Run `comms gc` to force a sweep, or `comms gc --dry-run` to inspect.

## agent instruction snippet

Put this in whichever always-loaded instruction file your agent uses (`GEMINI.md`, `CLAUDE.md`, `AGENTS.md`, `.cursorrules`, system prompt):

> You are `<name>` on a shared message bus. Register once with `comms --me <name> register "<your role>"`.
> Run `comms --me <name> read` before you start a task, after you finish one, and before you tell the human you are done.
> Direct mail addressed to you (`inbox/<name>`) requires action. Peer broadcasts (`all`) are ambient context for situational awareness only — NOT direct task assignments. Do not abandon your current goal or spawn fleet meta-work tasks in response to a broadcast.
> `comms --me <name> send <peer> "..."` reaches one agent, `comms --me <name> send all "..."` reaches everyone, `comms peers` lists them.
> Keep a message under 500 characters and under three lines. State the thing and name the note, task file or commit sha — never paste context the reader can fetch for themselves.
> Stuck: `comms --me <name> send all "stuck: <what, what you tried, human or retry>"`. Cleared: `comms --me <name> send all "unstuck: <what fixed it>"`.
> Never send an acknowledgement, a thank-you, or a message whose content is that you agree. If an exchange runs three turns without either side moving, stop and tell the human rather than replying again.

## license

MIT
