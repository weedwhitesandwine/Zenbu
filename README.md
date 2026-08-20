# Zenbu

**全部 — "everything." One keyboard-driven overlay for all of it.**

Zenbu is an everything-launcher for [Omarchy](https://omarchy.org): press one
key and get six tabs — Apps, Emoji, Files, Calc, Windows, and SSH — in a
single overlay that is themed by your active Omarchy theme, automatically,
with no configuration. It is built for the keyboard, like the rest of
Omarchy: type to filter, Tab to change tabs, Enter to act, Esc to leave.

## The tabs

- **Apps** — every installed application, with icons, fuzzy-searched by the
  shell's own app library. Enter launches.
- **Emoji** — search by name ("shrug", "fire"), shown large enough to
  actually tell apart. Enter types the emoji into the app you came from.
- **Files** — type part of a filename and get instant results from across
  your home folder (powered by `fd`, with cache/build/Steam junk excluded so
  it stays fast). Enter opens with the default app. An empty search shows
  your home folder.
- **Calc** — a live calculator and unit converter on the full qalculate
  engine: `35kg to lbs`, `15% * 4300`, `sqrt(2)`. Enter copies the result.
- **Windows** — every open window; Enter focuses it.
- **SSH** — the hosts from your `~/.ssh/config`; Enter connects in a
  terminal.

## Keys

| Key | Action |
|-----|--------|
| type anything | Filter the current tab |
| `Tab` / `Shift+Tab` | Next / previous tab |
| `←` / `→` | Previous / next tab |
| `↑` / `↓` / `PgUp` / `PgDn` | Move the selection |
| `Enter` | Launch / type / open / focus / connect / copy |
| `Esc` | Clear the search, then close |

The mouse works too: click a tab, click a row, and drag any edge or corner
of the card to resize it — the size is remembered.

## Install

```bash
omarchy plugin add https://github.com/weedwhitesandwine/Zenbu.git --enable
```

Then bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + U", "Zenbu (everything launcher)", "omarchy-shell shell toggle io.github.weedwhitesandwine.zenbu")
```

(Any free key combination works.)

### Requirements

All of these ship with, or are standard on, Omarchy — Zenbu just uses them:

- `fd` for the Files tab
- `qalc` (libqalculate) for the Calc tab
- `wl-copy` (wl-clipboard) for copying Calc results
- `alacritty` for opening SSH connections

## How it works

Zenbu is a Quickshell overlay running inside the Omarchy shell. Colors,
fonts, spacing, and corner radii all come from the shell's theme system, so
it always matches the active theme with nothing to configure. Apps come from
the shell's shared application library (the same source as the Omarchy
menu), windows from the Wayland toplevel list, emoji from Omarchy's own
emoji data, and file results from `fd` run on demand. The only file Zenbu
writes is its remembered card size in `~/.local/state/zenbu/`.

## Uninstall

```bash
omarchy plugin remove io.github.weedwhitesandwine.zenbu
```

## License

MIT
