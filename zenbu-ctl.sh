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
    # This value ends up inside a Lua string in bindings.lua, so it is checked
    # here as well as in the settings card — settings.json can be edited, or
    # restored from a backup, without ever going near the UI. A hotkey is
    # modifiers plus one key and nothing else; anything that does not match that
    # shape is refused rather than escaped, because there is no reason for it to
    # exist.
    if ! [[ $key =~ ^(SUPER|CTRL|ALT|SHIFT)([[:space:]]\+[[:space:]](SUPER|CTRL|ALT|SHIFT))*[[:space:]]\+[[:space:]]([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$ ]]; then
      echo "zenbu-ctl: refusing hotkey that is not modifiers plus one key: $key" >&2
      exit 1
    fi
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
# shell.json belongs to the user, not to this plugin, and it is read back
# before it is rewritten — so it gets a ceiling at the read, plus the one byte
# that identifies an over-sized file. Refusing leaves the file exactly as it
# stands, which is the right answer for one this script cannot make sense of.
MAX_SHELL_JSON = 4 * 1024 * 1024
try:
    with open(p, "rb") as f:
        raw = f.read(MAX_SHELL_JSON + 1)
    if len(raw) > MAX_SHELL_JSON:
        raise SystemExit
    d = json.loads(raw.decode("utf-8", "replace"))
except Exception:
    raise SystemExit
# Valid JSON of the wrong shape is not a config file, and setdefault will
# happily hand back a string to be subscripted. Each level is checked.
if not isinstance(d, dict):
    raise SystemExit
def eid(w): return w.get("id") if isinstance(w, dict) else w
if not isinstance(d.get("bar"), dict):
    d["bar"] = {}
bar = d["bar"]
if not isinstance(bar.get("layout"), dict):
    bar["layout"] = {}
lay = bar["layout"]
for s in ("left", "center", "right"):
    if not isinstance(lay.get(s), list):
        lay[s] = []
for s in lay:
    if isinstance(lay[s], list):
        lay[s] = [w for w in lay[s] if eid(w) != ID]
if not isinstance(d.get("plugins"), list):
    d["plugins"] = []
d["plugins"] = [w for w in d["plugins"] if eid(w) != ID]
if state == "on":
    lay[sec].append({"id": ID})
else:
    d["plugins"].append({"id": ID})
# Written beside the file and renamed over it. Writing in place truncates the
# user's shell configuration first and rebuilds it after, so an interruption
# anywhere in between would leave them with half a config file.
tmp = p + ".zenbu.tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
os.replace(tmp, p)
PY
    ;;
esac
