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

# 4. Generate/update repo comms_session_hooks.json with actual repo path
sed -i -e "s|s=\"[^\"]*comms_session\.py\"|s=\"$REPO_DIR/comms_session.py\"|g" "$REPO_DIR/comms_session_hooks.json"
echo "✓ Configured comms_session_hooks.json target to $REPO_DIR/comms_session.py"

# 5. Optional hook installation into ~/.claude/settings.json
INSTALL_HOOKS=0
for arg in "$@"; do
  [ "$arg" = "--hooks" ] && INSTALL_HOOKS=1
done

if [ "$INSTALL_HOOKS" -eq 1 ]; then
  python3 - <<EOF
import json
import pathlib
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

for event in ("SessionStart", "UserPromptSubmit", "PreCompact", "SessionEnd"):
    if event not in hooks_src:
        continue
    target_event = data.setdefault(event, {})
    target_hooks = target_event.setdefault("hooks", [])
    src_hook = hooks_src[event]["hooks"][0]
    
    # Check if identical command already exists
    exists = any(h.get("command") == src_hook.get("command") for h in target_hooks)
    if not exists:
        target_hooks.append(src_hook)

settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(f"✓ Installed lifecycle hooks into {settings_path}")
EOF
fi

echo "Done! agent-comms is ready."
