#!/bin/bash
# Zenbu settings helper. Runs ONLY when the user makes a choice in Zenbu's
# greeter or settings view — never on its own.
#
#   zenbu-ctl.sh bind "<keys>"      manage Zenbu's hotkey as a marked block
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

# An opening marker whose terminator is missing used to swallow every line
# after it: `skip` is only cleared by the closing marker, so an unbalanced
# block ran to the end of the file and the rest of the user's keybindings were
# deleted without a word. A block that is not a matched, ordered pair is not a
# block this script understands.
# Where bindings.lua really lives. A dotfiles manager (stow, chezmoi) puts a
# symlink at ~/.config/hypr/bindings.lua pointing into its own repository;
# staging beside the LINK and renaming over it replaces the link with a plain
# file, orphaning the repo so every later apply stops reaching Hyprland — and a
# stage file on another filesystem turns the rename into a non-atomic copy.
# Resolving first means the write lands on the real file, in its own directory,
# and the link survives. Target and directory must both be the user's and
# writable by nobody else.
resolve_bind_file() {
  local real dir mode
  real=$(realpath -- "$BIND_FILE" 2>/dev/null) || return 1
  [[ -f $real ]] || return 1
  dir=$(dirname -- "$real")
  if [[ ! -O $real || ! -O $dir ]]; then
    echo "refusing to write $real — it is not yours" >&2
    return 1
  fi
  mode=$(stat -c %a -- "$dir" 2>/dev/null) || return 1
  if (( 8#$mode & 8#022 )); then
    echo "refusing to write into $dir — it is writable by others" >&2
    return 1
  fi
  printf '%s' "$real"
}

check_markers() {
  local opens closes o c
  opens=$(grep -c -- ">>> zenbu hotkey" "$BIND_FILE" || true)
  closes=$(grep -c -- "<<< zenbu hotkey" "$BIND_FILE" || true)
  if (( opens != closes )); then
    echo "zenbu-ctl: refusing to edit $BIND_FILE — its hotkey block is not a matched pair ($opens opening, $closes closing)" >&2
    return 1
  fi
  if (( opens > 1 )); then
    echo "zenbu-ctl: refusing to edit $BIND_FILE — $opens hotkey blocks, expected at most one" >&2
    return 1
  fi
  if (( opens == 1 )); then
    o=$(grep -n -- ">>> zenbu hotkey" "$BIND_FILE" | head -1 | cut -d: -f1)
    c=$(grep -n -- "<<< zenbu hotkey" "$BIND_FILE" | head -1 | cut -d: -f1)
    if (( c < o )); then
      echo "zenbu-ctl: refusing to edit $BIND_FILE — its hotkey block closes before it opens" >&2
      return 1
    fi
  fi
  return 0
}

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
    # The shape a hotkey may have, held in a variable because it contains
# spaces — and it must contain literal spaces, not [[:space:]], which
# also matches a newline and a tab. The settings card checks a literal
# space, so anything looser here is a gap between the two guards: a
# newline passed this check, was refused by that one, and reached
# bindings.lua as an unterminated Lua string that cost the user every
# keybinding in the file on the next reload.
KEY_SHAPE='^(SUPER|CTRL|ALT|SHIFT)( \+ (SUPER|CTRL|ALT|SHIFT))* \+ ([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$'
if ! [[ $key =~ $KEY_SHAPE ]]; then
      echo "zenbu-ctl: refusing hotkey that is not modifiers plus one key: $key" >&2
      exit 1
    fi
    # The replacement is staged in the same directory as bindings.lua and
    # renamed over it, so the swap is a single atomic step — staging it in
    # /tmp and mv-ing across filesystems degrades to a copy, which can leave
    # a half-written config if interrupted. mktemp creates the stage file
    # exclusively under a random name, so nothing can have been planted at it.
    REAL_BIND=$(resolve_bind_file) || exit 1
    tmp=$(mktemp "$REAL_BIND.XXXXXXXX")
    trap 'rm -f "$tmp"' EXIT
    check_markers || exit 1
    strip_block > "$tmp"
    {
      echo ""
      echo "$MARK_IN"
      printf 'o.bind("%s", "Zenbu (everything launcher)", "omarchy-shell shell toggle %s")\n' "$key" "$ID"
      echo "$MARK_OUT"
    } >> "$tmp"
    chmod --reference="$REAL_BIND" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$REAL_BIND"
    trap - EXIT
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  unbind)
    [[ -f $BIND_FILE ]] || exit 0
    REAL_BIND=$(resolve_bind_file) || exit 1
    tmp=$(mktemp "$REAL_BIND.XXXXXXXX")
    trap 'rm -f "$tmp"' EXIT
    check_markers || exit 1
    strip_block > "$tmp"
    chmod --reference="$REAL_BIND" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$REAL_BIND"
    trap - EXIT
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  bar)
    # bar on [left|center|right] | bar off
    # The icon is visible when Zenbu's entry lives in the bar layout of
    # shell.json; hidden (but the plugin still enabled) when the entry
    # lives in the plugins list instead. The shell hot-reloads the file.
    python3 - "$2" "${3:-right}" <<'PY'
import json, os, stat, sys, tempfile
state = sys.argv[1]
sec = sys.argv[2] if sys.argv[2] in ("left", "center", "right") else "right"
ID = "io.github.weedwhitesandwine.zenbu"
p = os.path.expanduser("~/.config/omarchy/shell.json")
# shell.json belongs to the user, not to this plugin, and it is read back
# before it is rewritten — so it gets a ceiling at the read, plus the one byte
# that identifies an over-sized file. Refusing leaves the file exactly as it
# stands, which is the right answer for one this script cannot make sense of.
# The open refuses symlinks and non-regular files, so a planted link cannot
# redirect the read and a FIFO cannot block it forever.
MAX_SHELL_JSON = 4 * 1024 * 1024
try:
    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise SystemExit
        with os.fdopen(fd, "rb") as f:
            fd = None
            raw = f.read(MAX_SHELL_JSON + 1)
    finally:
        if fd is not None:
            os.close(fd)
    if len(raw) > MAX_SHELL_JSON:
        raise SystemExit
    d = json.loads(raw.decode("utf-8", "replace"))
except SystemExit:
    raise
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
# Staged under an unpredictable name created exclusively by mkstemp — which
# never follows a symlink — in a directory verified to be owned by us and
# writable by nobody else, then renamed over the destination in one step.
# Writing in place would truncate the user's shell configuration before
# rebuilding it, and a predictable stage name would let a pre-planted symlink
# turn this write into the truncation of whatever the link pointed at.
home_cfg = os.path.dirname(p)
try:
    st = os.stat(home_cfg)
    if st.st_uid != os.getuid() or (st.st_mode & 0o022):
        raise SystemExit
except OSError:
    raise SystemExit
fd, tmp = tempfile.mkstemp(prefix=".shell.json.", suffix=".tmp", dir=home_cfg)
try:
    with os.fdopen(fd, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    try:
        os.chmod(tmp, os.stat(p).st_mode & 0o777)
    except OSError:
        pass
    os.replace(tmp, p)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
    ;;
esac
