#!/bin/bash
# Install omarchy-workspaces: the CLI, the bar widget, and the menu entries.
# Safe to re-run — every step is idempotent.

set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ID=$(jq -r .id "$REPO/manifest.json")
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
BIN_DIR="$HOME/.local/bin"
MENU="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
SHELL_JSON="$HOME/.config/omarchy/shell.json"

step() { echo "  → $*"; }

# 1. CLI on PATH.
mkdir -p "$BIN_DIR"
ln -sfn "$REPO/bin/omarchy-workspaces" "$BIN_DIR/omarchy-workspaces"
step "Linked omarchy-workspaces into $BIN_DIR"

# 2. Plugin visible to the shell. A symlink keeps the checkout editable in
#    place; the plugin walker follows links.
mkdir -p "$(dirname "$PLUGIN_DIR")"
if [[ -e $PLUGIN_DIR && ! -L $PLUGIN_DIR ]]; then
  echo "  ! $PLUGIN_DIR exists and is not a symlink — leaving it alone" >&2
else
  ln -sfn "$REPO" "$PLUGIN_DIR"
  step "Linked plugin into $PLUGIN_DIR"
fi

# 3. Config, seeded from whatever is plugged in right now.
if [[ ! -f "$HOME/.config/omarchy/workspaces.json" ]]; then
  "$REPO/bin/omarchy-workspaces" detect --quiet >/dev/null
  step "Seeded ~/.config/omarchy/workspaces.json from the connected monitors"
fi

# 4. Menu entries under Setup → Workspaces.
if [[ -f $MENU ]] && ! grep -q '"setup.workspaces"' "$MENU"; then
  cp "$MENU" "$MENU.bak.$(date +%s)"
  # The file is JSONC with a trailing `}`; splice our rows in just above it.
  python3 - "$MENU" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
rows = '''
  // ── omarchy-workspaces ──────────────────────────────────────────────────
  "setup.workspaces": {"icon":"󰕰","label":"Workspaces","aliases":["workspaces"],"description":"Pin workspaces to monitors","action":"omarchy-workspaces open"},
'''
index = text.rstrip().rfind('}')
path.write_text(text[:index].rstrip('\n') + '\n' + rows + text[index:])
PY
  step "Added Setup → Workspaces to the Omarchy menu"
fi

# 5. Swap the stock workspaces widget for this one, keeping its bar position.
if [[ -f $SHELL_JSON ]] && ! grep -q "$PLUGIN_ID" "$SHELL_JSON"; then
  cp "$SHELL_JSON" "$SHELL_JSON.bak.$(date +%s)"
  tmp=$(mktemp)
  jq --arg id "$PLUGIN_ID" '
    .bar.layout |= with_entries(
      .value |= map(if .id == "omarchy.workspaces" then .id = $id else . end))' \
    "$SHELL_JSON" >"$tmp" && mv "$tmp" "$SHELL_JSON"
  step "Swapped omarchy.workspaces → $PLUGIN_ID in the bar"
fi

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
"$REPO/bin/omarchy-workspaces" apply

echo
echo "Done. Setup → Workspaces in the Omarchy menu, or: omarchy-workspaces --help"
