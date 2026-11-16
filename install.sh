#!/bin/sh
# install.sh - Set up agent-comms symlinks and session hooks
#
# Usage:
#   sh install.sh
#   sh install.sh --bus <default_bus>
#   sh install.sh --hooks   # also install lifecycle hooks into ~/.claude/settings.json

set -eu

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
BIN_DIR="${HOME}/.local/bin"
BUS="${1:-}"

if [ "$BUS" = "--bus" ]; then
  shift
  BUS="${1:-default}"
fi

mkdir -p "$BIN_DIR"

# 1. Make scripts executable
chmod +x "$REPO_DIR/comms.sh"
chmod +x "$REPO_DIR/comms-watch.sh"
chmod +x "$REPO_DIR/test-retention.sh"
chmod +x "$REPO_DIR/comms_session.py"

# 2. Symlink core tools into ~/.local/bin
ln -sfn "$REPO_DIR/comms.sh" "$BIN_DIR/comms"
ln -sfn "$REPO_DIR/comms-watch.sh" "$BIN_DIR/comms-watch"
ln -sfn "$REPO_DIR/comms_session.py" "$BIN_DIR/comms-session"

echo "✓ Symlinked comms -> $BIN_DIR/comms"
echo "✓ Symlinked comms-watch -> $BIN_DIR/comms-watch"
echo "✓ Symlinked comms-session -> $BIN_DIR/comms-session"

# 3. Configure comms defaults if specified or not yet present
if [ -n "$BUS" ] && [ "$BUS" != "--hooks" ]; then
  "$BIN_DIR/comms" config set default_bus "$BUS"
  echo "✓ Configured default_bus=$BUS"
fi

# 4. Optional hook installation into ~/.claude/settings.json
#
# The repo's comms_session_hooks.json is left untouched on purpose. It used to be
# rewritten in place with `sed -i`, which dirtied a tracked file on every install and
# then made the next `git pull --ff-only` refuse; the path is substituted in memory
# below instead. `sed -i` also takes a mandatory argument on BSD, so `-i -e` wrote
# backup files named `...json-e` on macOS rather than editing in place.
INSTALL_HOOKS=0
for arg in "$@"; do
  [ "$arg" = "--hooks" ] && INSTALL_HOOKS=1
done

if [ "$INSTALL_HOOKS" -eq 1 ]; then
  python3 - <<EOF
import json
import pathlib
import re
import sys

settings_path = pathlib.Path.home() / ".claude/settings.json"
hooks_path = pathlib.Path("$REPO_DIR/comms_session_hooks.json")

if not hooks_path.exists():
    print(f"Error: {hooks_path} not found", file=sys.stderr)
    sys.exit(1)

settings_path.parent.mkdir(parents=True, exist_ok=True)
if settings_path.exists() and settings_path.stat().st_size > 0:
    try:
        data = json.loads(settings_path.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"Warning: could not parse existing {settings_path}: {e}", file=sys.stderr)
        data = {}
else:
    data = {}

hooks_src = json.loads(hooks_path.read_text(encoding="utf-8"))

# Point every hook command at this checkout, in memory rather than on disk.
repo_dir = "$REPO_DIR"
script = repo_dir + "/comms_session.py"

# Claude Code's schema is settings["hooks"][<event>] -> list of matcher groups, each
# {"hooks": [ {type, command, ...} ]}. Writing settings[<event>] instead, which is what
# this installer used to do, puts a well-formed block at a key Claude Code never reads:
# the install reports success, nothing errors, and the bus silently never registers or
# delivers. Merge into the nested list, per matcher group.
settings_hooks = data.setdefault("hooks", {})
installed = 0

for event in ("SessionStart", "UserPromptSubmit", "PreCompact", "SessionEnd"):
    if event not in hooks_src:
        continue
    src_group = hooks_src[event]
    if not isinstance(src_group, dict) or not src_group.get("hooks"):
        continue
    src_hook = dict(src_group["hooks"][0])
    src_hook["command"] = re.sub(
        r's="[^"]*comms_session\.py"', 's="%s"' % script, src_hook["command"]
    )

    groups = settings_hooks.setdefault(event, [])
    if not isinstance(groups, list):
        print(f"Warning: settings hooks.{event} is not a list, skipping", file=sys.stderr)
        continue

    # Dedupe on the command across every existing group, so re-running is idempotent
    # and an older comms hook pointing at a different checkout is replaced rather than
    # left to register the same session twice.
    already = False
    for group in groups:
        for hook in list(group.get("hooks", []) if isinstance(group, dict) else []):
            cmd = hook.get("command", "")
            if "comms_session.py" not in cmd:
                continue
            if cmd == src_hook["command"]:
                already = True
            else:
                group["hooks"].remove(hook)

    if not already:
        groups.append({"hooks": [src_hook]})
        installed += 1

# Drop any matcher group left with no hooks by the replacement above.
for event, groups in list(settings_hooks.items()):
    if isinstance(groups, list):
        settings_hooks[event] = [
            g for g in groups if not (isinstance(g, dict) and g.get("hooks") == [])
        ]

settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(f"✓ Installed {installed} lifecycle hook(s) into {settings_path} under hooks.*")
EOF
fi

echo "Done! agent-comms is ready."
