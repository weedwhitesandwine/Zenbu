#!/bin/bash
# Zenbu settings helper. Runs ONLY when the user makes a choice in Zenbu's
# greeter or settings view — never on its own.
#
#   zenbu-ctl.sh bind "SUPER + U"   manage Zenbu's hotkey as a marked block
#                                   in ~/.config/hypr/bindings.lua (replaces
#                                   only its own block, never other lines)
#   zenbu-ctl.sh unbind             remove that block
#   zenbu-ctl.sh bar on|off         add/remove the Zenbu icon in the bar
#                                   layout (~/.config/omarchy/shell.json)
set -e

ID="io.github.weedwhitesandwine.zenbu"
BIND_FILE="$HOME/.config/hypr/bindings.lua"
MARK_IN="-- >>> zenbu hotkey (managed by Zenbu settings — change it there)"
MARK_OUT="-- <<< zenbu hotkey"

strip_block() {
  # print bindings.lua without Zenbu's marked block
  awk -v a="$MARK_IN" -v b="$MARK_OUT" '
    index($0, ">>> zenbu hotkey") { skip = 1; next }
    index($0, "<<< zenbu hotkey") { skip = 0; next }
    !skip { print }
  ' "$BIND_FILE"
}

case "$1" in
  bind)
    key="$2"
    [[ -n $key && -f $BIND_FILE ]] || exit 1
    tmp=$(mktemp)
    strip_block > "$tmp"
    {
      echo ""
      echo "$MARK_IN"
      printf 'o.bind("%s", "Zenbu (everything launcher)", "omarchy-shell shell toggle %s")\n' "$key" "$ID"
      echo "$MARK_OUT"
    } >> "$tmp"
    mv "$tmp" "$BIND_FILE"
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  unbind)
    [[ -f $BIND_FILE ]] || exit 0
    tmp=$(mktemp)
    strip_block > "$tmp"
    mv "$tmp" "$BIND_FILE"
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  bar)
    # bar on [left|center|right] | bar off
    # The icon is visible when Zenbu's entry lives in the bar layout of
    # shell.json; hidden (but the plugin still enabled) when the entry
    # lives in the plugins list instead. The shell hot-reloads the file.
    python3 - "$2" "${3:-right}" <<'PY'
import json, os, sys
state = sys.argv[1]
sec = sys.argv[2] if sys.argv[2] in ("left", "center", "right") else "right"
ID = "io.github.weedwhitesandwine.zenbu"
p = os.path.expanduser("~/.config/omarchy/shell.json")
try:
    d = json.load(open(p))
except Exception:
    raise SystemExit
def eid(w): return w.get("id") if isinstance(w, dict) else w
bar = d.setdefault("bar", {})
lay = bar.setdefault("layout", {})
for s in ("left", "center", "right"):
    lay.setdefault(s, [])
for s in lay:
    lay[s] = [w for w in lay[s] if eid(w) != ID]
d.setdefault("plugins", [])
d["plugins"] = [w for w in d["plugins"] if eid(w) != ID]
if state == "on":
    lay[sec].append({"id": ID})
else:
    d["plugins"].append({"id": ID})
json.dump(d, open(p, "w"), indent=2)
PY
    ;;
esac
