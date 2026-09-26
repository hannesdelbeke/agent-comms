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
INSTALL_HOOKS=0
for arg in "$@"; do
  [ "$arg" = "--hooks" ] && INSTALL_HOOKS=1
done

if [ "$INSTALL_HOOKS" -eq 1 ]; then
  PYTHON_BIN="python3"
  if ! command -v python3 >/dev/null 2>&1; then
    if command -v python >/dev/null 2>&1; then
      PYTHON_BIN="python"
    else
      echo "Error: python3 or python required to install hooks" >&2
      exit 1
    fi
  fi

  "$PYTHON_BIN" - "$REPO_DIR" <<'EOF'
import json
import pathlib
import re
import sys

repo_dir = pathlib.Path(sys.argv[1]).resolve()
script_path = str(repo_dir / "comms_session.py")
hooks_path = repo_dir / "comms_session_hooks.json"
settings_path = pathlib.Path.home() / ".claude/settings.json"

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

try:
    hooks_src = json.loads(hooks_path.read_text(encoding="utf-8"))
except Exception as e:
    print(f"Error: could not parse {hooks_path}: {e}", file=sys.stderr)
    sys.exit(1)

# Clean legacy top-level hook keys if written by older install.sh
for event in ("SessionStart", "UserPromptSubmit", "PreCompact", "SessionEnd"):
    if event in data and isinstance(data[event], dict) and "hooks" in data[event]:
        data[event]["hooks"] = [
            h for h in data[event]["hooks"]
            if not (isinstance(h, dict) and "comms_session.py" in h.get("command", ""))
        ]
        if not data[event]["hooks"]:
            del data[event]

# Claude Code reads settings["hooks"][<event>] as a list of matcher groups: [{"hooks": [...]}]
hooks_dict = data.setdefault("hooks", {})
for event in ("SessionStart", "UserPromptSubmit", "PreCompact", "SessionEnd"):
    if event not in hooks_src:
        continue
    src_hook = dict(hooks_src[event]["hooks"][0])
    # Replace path in-memory without modifying comms_session_hooks.json on disk
    src_hook["command"] = re.sub(
        r's="[^"]*comms_session\.py"',
        f's="{script_path}"',
        src_hook.get("command", "")
    )

    event_groups = hooks_dict.setdefault(event, [])
    if not isinstance(event_groups, list):
        event_groups = []
        hooks_dict[event] = event_groups

    updated = False
    for group in event_groups:
        if not isinstance(group, dict):
            continue
        g_hooks = group.setdefault("hooks", [])
        if not isinstance(g_hooks, list):
            continue
        for i, h in enumerate(g_hooks):
            if isinstance(h, dict) and "comms_session.py" in h.get("command", ""):
                g_hooks[i] = src_hook
                updated = True
                break
        if updated:
            # Deduplicate any remaining comms_session hooks in this group
            group["hooks"] = [
                h for idx, h in enumerate(g_hooks)
                if idx == i or not (isinstance(h, dict) and "comms_session.py" in h.get("command", ""))
            ]
            break

    if not updated:
        event_groups.append({"hooks": [src_hook]})

    # Clean any duplicate comms_session hooks across other groups in this event
    for group in event_groups:
        if not isinstance(group, dict) or "hooks" not in group:
            continue
        group["hooks"] = [
            h for h in group["hooks"]
            if h is src_hook or not (isinstance(h, dict) and "comms_session.py" in h.get("command", ""))
        ]
    event_groups[:] = [g for g in event_groups if isinstance(g, dict) and g.get("hooks")]

settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(f"✓ Installed lifecycle hooks into {settings_path}")
EOF
fi

echo "Done! agent-comms is ready."
