import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

import qs.Commons
import qs.Ui
import "."

// Zenbu (全部, "everything"): one overlay, six tabs — Apps, Emoji, Files,
// Calc, Windows, SSH. Type to filter the current tab, Tab to cycle tabs,
// Enter to act. Colors, fonts, and spacing all come from the shell's theme
// singletons, so Zenbu always matches the active Omarchy theme.
Item {
  id: root

  // A file this plugin reads but does not own can be anything by the time it
  // is opened: a link pointing elsewhere, a pipe that never produces anything,
  // or something far too large. `head` opens a path the ordinary way and would
  // follow the first and wait forever on the second, inside a shell process
  // that stays up for days. So the open refuses on its own terms and hands
  // back nothing at all rather than something over the ceiling. O_NOFOLLOW
  // covers the final name only — a link in a parent directory is still
  // followed, which is the same trust already placed in the home directory.
  readonly property string safeRead: [
    'import os, stat, sys',
    'path = sys.argv[1]; ceiling = int(sys.argv[2])',
    'try:',
    '    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)',
    'except FileNotFoundError:',
    '    raise SystemExit(2)',
    'except OSError:',
    '    raise SystemExit(1)',
    'try:',
    '    if not stat.S_ISREG(os.fstat(fd).st_mode):',
    '        raise SystemExit(1)',
    '    with os.fdopen(fd, "rb") as handle:',
    '        fd = None',
    '        raw = handle.read(ceiling + 1)',
    'except OSError:',
    '    raise SystemExit(1)',
    'finally:',
    '    if fd is not None:',
    '        os.close(fd)',
    'if len(raw) > ceiling:',
    '    raise SystemExit(1)',
    'sys.stdout.buffer.write(raw)'
  ].join("
")

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property string home: Quickshell.env("HOME")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property int tabIndex: 0
  // Rows for the current tab, as [{label, sub, icon, glyph, hint}].
  property var rows: []

  readonly property var tabs: [
    { id: "apps",    label: "Apps",    placeholder: "Search apps…" },
    { id: "emoji",   label: "Emoji",   placeholder: "Search emoji…" },
    { id: "files",   label: "Files",   placeholder: "Search files…" },
    { id: "calc",    label: "Calc",    placeholder: "Type a calculation…" },
    { id: "windows", label: "Windows", placeholder: "Search open windows…" },
    { id: "ssh",     label: "SSH",     placeholder: "Search SSH hosts…" }
  ]
  readonly property string tab: tabs[tabIndex].id

  property var emojiData: []
  property var sshHosts: []
  property var fileRows: []
  property string calcResult: ""
  property string calcExpr: ""
  property bool qalcAvailable: true

  // ------------------------------------------------------------------ theme
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  // User-dragged size (0 = theme default); persisted across sessions.
  property int userWidth: 0
  property int userHeight: 0
  property int cardWidth: Math.max(Style.space(300),
    Math.min(userWidth > 0 ? userWidth : Style.space(430), panel.width - Style.gapsOut * 2))
  property int cardHeight: Math.max(Style.space(340),
    Math.min(userHeight > 0 ? userHeight : Style.space(520), panel.height - Style.gapsOut * 2))
  // Emoji rows are taller so the emoji itself is legible; text stays the same size.
  property int rowHeight: root.tab === "emoji"
    ? Math.max(Style.space(56), Style.font.displayLarge + Style.spacing.md * 2)
    : Math.max(Style.space(40), Style.font.title + Style.spacing.md * 2)
  property int iconSlot: root.tab === "emoji" ? Style.space(48) : Style.space(26)

  readonly property string sizeFile: root.home + "/.local/state/zenbu/size"

  // Written to an exclusively-created temporary name beside the file and
  // renamed over it: a bare `>` redirection truncates whatever already sits
  // at that path — including the target of a symlink a restored backup could
  // have left there — before the new content lands. `-O` confirms the state
  // directory is ours before anything is staged in it.
  function saveSize() {
    Quickshell.execDetached(["bash", "-c",
      'd=$(dirname "$1") && mkdir -p "$d" && [ -O "$d" ] && t=$(mktemp "$1.XXXXXXXX") && printf "%s\\n" "$2" > "$t" && mv -f "$t" "$1"', "--",
      root.sizeFile, root.cardWidth + "x" + root.cardHeight])
  }

  // ------------------------------------------------------------- settings
  // User choices, made in the greeter (first run) or the ⚙ settings view:
  // how Zenbu appears (centered pop-up or dropdown from the bar icon),
  // whether the bar icon is shown, and the summon hotkey. Applying a choice
  // is the ONLY time Zenbu touches bindings.lua (its own marked block, via
  // zenbu-ctl.sh) or the bar layout — never on its own.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    return decodeURIComponent(u.replace(/^file:\/\//, "")).replace(/\/$/, "")
  }
  readonly property string settingsFile: root.home + "/.local/state/zenbu/settings.json"
  property var zsettings: ({ greeted: false, mode: "center", barIcon: false, barSection: "right", shortcut: "", emojiAction: "both", hiddenFiles: true, systemFiles: false, rates: "off" })
  readonly property bool dropdown: zsettings.mode === "dropdown"

  // "list" is the launcher; "greeter" shows on first run; "settings" via ⚙.
  property string view: "list"
  property real anchorX: -1

  // How far down the card has to start to clear the bar: the bar's own height
  // when it is along the top and showing, and nothing otherwise. A left or
  // right bar takes no vertical room; a hidden one takes none either.
  readonly property real barDrop: {
    if (!ZenbuState.barKnown) return Style.space(46)
    if (ZenbuState.barHidden) return Style.gapsOut
    if (ZenbuState.barPosition !== "top") return Style.gapsOut
    return (ZenbuState.barSize > 0 ? ZenbuState.barSize : Style.space(38)) + Style.gapsOut
  }

  property string draftMode: "center"
  property bool draftBarIcon: false
  property string draftBarSection: "right"
  property string draftEmojiAction: "both"
  property string draftShortcut: ""
  property bool draftHiddenFiles: true
  property bool draftSystemFiles: false
  property string draftRates: "off"
  property bool capturing: false
  property string captureNote: ""

  // Nothing is written until the settings have been read back at least once,
  // so a save can never put the in-memory defaults over the user's real
  // choices before they have loaded.
  property bool settingsLoaded: false

  function saveSettings() {
    if (!root.settingsLoaded) return
    Quickshell.execDetached(["bash", "-c",
      'd=$(dirname "$2") && mkdir -p "$d" && [ -O "$d" ] && t=$(mktemp "$2.XXXXXXXX") && printf "%s\\n" "$1" > "$t" && mv -f "$t" "$2"', "--",
      JSON.stringify(root.zsettings), root.settingsFile])
  }

  function syncDrafts() {
    root.draftMode = root.zsettings.mode || "center"
    root.draftBarIcon = root.zsettings.barIcon === true
    root.draftBarSection = root.zsettings.barSection || "right"
    root.draftEmojiAction = root.zsettings.emojiAction || "both"
    root.draftShortcut = root.validShortcut(root.zsettings.shortcut)
                         ? root.zsettings.shortcut : ""
    root.draftHiddenFiles = root.zsettings.hiddenFiles !== false
    root.draftSystemFiles = root.zsettings.systemFiles === true
    root.draftRates = root.zsettings.rates === "daily" ? "daily" : "off"
    root.capturing = false
    root.captureNote = ""
  }

  function applyDrafts() {
    if (root.draftMode === "dropdown") root.draftBarIcon = true
    var s = {
      greeted: true,
      mode: root.draftMode,
      barIcon: root.draftBarIcon,
      barSection: root.draftBarSection,
      emojiAction: root.draftEmojiAction,
      shortcut: root.draftShortcut,
      hiddenFiles: root.draftHiddenFiles,
      systemFiles: root.draftSystemFiles,
      rates: root.draftRates
    }
    root.zsettings = s
    root.saveSettings()
    Quickshell.execDetached(["bash", root.pluginDir + "/zenbu-ctl.sh", "bar",
                             s.barIcon ? "on" : "off", s.barSection])
    if (root.validShortcut(s.shortcut))
      Quickshell.execDetached(["bash", root.pluginDir + "/zenbu-ctl.sh", "bind", s.shortcut])
    else
      Quickshell.execDetached(["bash", root.pluginDir + "/zenbu-ctl.sh", "unbind"])
    root.view = "list"
    root.rebuild()
  }

  // A hotkey is a fixed shape: one or more modifiers, then one key. Anything
  // else is not a hotkey, and since this value is written into bindings.lua as
  // Lua source, "anything else" has to mean refused rather than escaped. The
  // capture code below can only produce this shape, but settings.json can be
  // edited or restored from a backup without going near the capture code at
  // all, so what is read back is checked before it is used.
  readonly property var shortcutPattern:
    /^(SUPER|CTRL|ALT|SHIFT)( \+ (SUPER|CTRL|ALT|SHIFT))* \+ ([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$/

  function validShortcut(v) {
    return typeof v === "string" && v.length <= 40 && root.shortcutPattern.test(v)
  }

  function captureKey(event) {
    if (event.key === Qt.Key_Escape) { root.capturing = false; root.captureNote = ""; return }
    var mods = []
    if (event.modifiers & Qt.MetaModifier) mods.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) mods.push("CTRL")
    if (event.modifiers & Qt.AltModifier) mods.push("ALT")
    if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT")
    var name = ""
    if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z) name = String.fromCharCode(65 + (event.key - Qt.Key_A))
    else if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9) name = String.fromCharCode(48 + (event.key - Qt.Key_0))
    else if (event.key >= Qt.Key_F1 && event.key <= Qt.Key_F12) name = "F" + (event.key - Qt.Key_F1 + 1)
    if (name === "") return
    if (mods.length === 1 && mods[0] === "SHIFT") {
      root.captureNote = "Shift on its own is not enough — hold SUPER, CTRL or ALT too"
      return
    }
    if (mods.length === 0) { root.captureNote = "Add a modifier — SUPER, CTRL or ALT"; return }
    root.draftShortcut = mods.join(" + ") + " + " + name
    root.captureNote = ""
    root.capturing = false
  }

  // The expression a running calculation was asked of.
  property string calcSent: ""

  // -------------------------------------------------------------- lifecycle

  // Recording swallows every keystroke by design. Closing the launcher
  // mid-recording used to leave that flag set, so the next time it opened it
  // ate everything typed at it with nothing on screen to explain why.
  function stopCapture() {
    root.capturing = false
    root.captureNote = ""
  }

  function open(payloadJson) {
    root.stopCapture()
    root.opened = true
    // Always start on Apps, whatever tab was showing when it was last closed.
    root.tabIndex = 0
    root.filterText = ""
    root.calcResult = ""
    root.calcExpr = ""
    root.selectedIndex = 0
    pointerGate.reset()
    root.view = root.zsettings.greeted === true ? "list" : "greeter"
    if (root.view === "greeter") root.syncDrafts()
    if (root.shell && root.shell.appLibrary) root.shell.appLibrary.refreshIcons()
    if (!qalcCheck.running) qalcCheck.running = true
    root.rebuild()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openAt(x) {
    root.anchorX = x
    root.lastAnchorX = x
    root.open("{}")
  }

  // Remembered, so a summon from the hotkey drops from where the icon is
  // rather than from the middle of the screen until the icon has been clicked
  // once. Still -1 on a machine that has never shown the icon, which falls
  // back to centred — the only sensible answer when there is no icon.
  property real lastAnchorX: -1

  function close() { root.stopCapture(); root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.weedwhitesandwine.zenbu")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ------------------------------------------------------------------ tabs
  function switchTab(delta) {
    root.setTab((root.tabIndex + delta + root.tabs.length) % root.tabs.length)
  }

  function setTab(index) {
    if (index < 0 || index >= root.tabs.length || index === root.tabIndex) return
    root.tabIndex = index
    // A search belongs to the tab it was typed in — each tab starts clean.
    root.filterText = ""
    root.calcResult = ""
    root.calcExpr = ""
    root.selectedIndex = 0
    pointerGate.reset()
    root.rebuild()
  }

  function setFilter(next) {
    root.filterText = next
    root.selectedIndex = 0
    pointerGate.reset()
    root.rebuild()
  }

  // ---------------------------------------------------------------- rebuild
  function rebuild() {
    if (!root.opened) return
    var t = root.tab
    if (t === "apps") root.rows = root.appRows()
    else if (t === "emoji") root.rows = root.emojiRows()
    else if (t === "windows") root.rows = root.windowRows()
    else if (t === "ssh") root.rows = root.sshRows()
    else if (t === "files") { root.rows = root.fileRows; fdDebounce.restart() }
    else if (t === "calc") {
      root.rows = root.calcRows()
      calcDebounce.restart()
      // Lazily, and once per Zenbu run: nobody should pay a file read — or, if
      // they enabled it, a network call — merely for launching an app.
      if (!root.ratesChecked) { root.ratesChecked = true; root.readRates(true) }
    }
    listView.positionViewAtBeginning()
  }

  function appRows() {
    var lib = root.shell ? root.shell.appLibrary : null
    if (!lib) return []
    var entries = lib.sortedEntries(root.filterText)
    var out = []
    for (var i = 0; i < entries.length && out.length < 40; i++) {
      var entry = entries[i].entry
      if (!entry) continue
      out.push({
        label: lib.entryName(entry),
        sub: lib.entrySubtext(entry) || "",
        icon: lib.iconSource(entry.icon),
        glyph: "",
        hint: "run",
        appId: entry.id
      })
    }
    return out
  }

  function emojiRows() {
    var needle = root.filterText.trim().toLowerCase()
    var out = []
    for (var i = 0; i < root.emojiData.length && out.length < 40; i++) {
      var item = root.emojiData[i]
      if (!item || !item.e) continue
      var keys = String(item.k || "")
      if (!needle || keys.toLowerCase().indexOf(needle) >= 0) {
        out.push({
          label: keys.split(" ").slice(0, 4).join(" "),
          sub: "",
          icon: "",
          glyph: item.e,
          hint: (root.zsettings.emojiAction || "both") === "copy" ? "copy"
            : (root.zsettings.emojiAction || "both") === "type" ? "type it" : "type + copy",
          emoji: item.e
        })
      }
    }
    return out
  }

  function windowRows() {
    var needle = root.filterText.trim().toLowerCase()
    var values = []
    try { values = ToplevelManager.toplevels.values || [] } catch (e) {}
    var lib = root.shell ? root.shell.appLibrary : null
    var out = []
    for (var i = 0; i < values.length; i++) {
      var w = values[i]
      if (!w) continue
      var title = String(w.title || "")
      var app = String(w.appId || "")
      if (needle && title.toLowerCase().indexOf(needle) < 0 && app.toLowerCase().indexOf(needle) < 0) continue
      out.push({
        label: title || app,
        sub: app,
        icon: lib ? lib.iconSource(app) : "",
        glyph: "",
        hint: "focus",
        windowRef: w
      })
    }
    return out
  }

  function sshRows() {
    var needle = root.filterText.trim().toLowerCase()
    var out = []
    for (var i = 0; i < root.sshHosts.length; i++) {
      var h = root.sshHosts[i]
      if (needle && h.toLowerCase().indexOf(needle) < 0) continue
      out.push({ label: h, sub: "ssh " + h, icon: "", glyph: "󰉉", hint: "connect", host: h })
    }
    return out
  }

  function calcRows() {
    if (!root.qalcAvailable)
      return [{ label: "Calc needs the qalc calculator", sub: "Install it once:  omarchy pkg add libqalculate", icon: "", glyph: "󰃬", hint: "" }]
    if (!root.filterText.trim() || !root.looksCalculable(root.filterText))
      return [{ label: "Type a calculation…", sub: "6 feet to meters · 100 euros to jpy · 20 celsius to fahrenheit · sqrt(2)", icon: "", glyph: "󰃬", hint: "" }]
    if (root.calcResult && root.calcExpr === root.filterText) {
      // Money is only as current as the rates file behind it, so the answer
      // carries its date. Everything else converts from constants and needs no
      // such caveat.
      var sub = root.filterText
      if (root.isCurrencyResult(root.calcResult) && root.ratesLabel)
        sub += "   ·   rates " + root.ratesLabel
      return [{ label: root.calcResult, sub: sub, icon: "", glyph: "=", hint: "copy", copyText: root.calcResult }]
    }
    return [{ label: "…", sub: root.filterText, icon: "", glyph: "=", hint: "" }]
  }

  // --------------------------------------------------------------- actions
  function activate(index) {
    if (index < 0 || index >= root.rows.length) return
    var row = root.rows[index]
    if (row.appId !== undefined) {
      root.dismiss()
      var lib = root.shell ? root.shell.appLibrary : null
      if (lib) lib.launch(row.appId, row.label)
    } else if (row.emoji !== undefined) {
      root.dismiss()
      // Per the emoji-action setting: type it into the app you came from,
      // leave it on the clipboard, or both (sequential — the inserter's own
      // clipboard use is temporary and cleared, so the copy comes after).
      var act = root.zsettings.emojiAction || "both"
      if (act === "copy") {
        Quickshell.execDetached(["wl-copy", row.emoji])
      } else if (act === "type") {
        Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-menu-emoji-insert", row.emoji])
      } else {
        Quickshell.execDetached(["bash", "-c",
          '"$1" "$2"; sleep 0.1; printf %s "$2" | wl-copy', "--",
          root.omarchyPath + "/bin/omarchy-menu-emoji-insert", row.emoji])
      }
    } else if (row.path !== undefined) {
      root.dismiss()
      Quickshell.execDetached(["xdg-open", row.path])
    } else if (row.windowRef !== undefined) {
      root.dismiss()
      try { row.windowRef.activate() } catch (e) {}
    } else if (row.host !== undefined) {
      root.dismiss()
      // Opens in whatever terminal the user actually uses (xdg-terminal-exec).
      Quickshell.execDetached(["omarchy-launch-terminal", "ssh", row.host])
    } else if (row.copyText !== undefined) {
      root.dismiss()
      Quickshell.execDetached(["wl-copy", row.copyText])
    }
  }

  function select(delta) {
    if (root.rows.length === 0) return
    pointerGate.reset()
    root.selectedIndex = (root.selectedIndex + delta + root.rows.length) % root.rows.length
    listView.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function selectPage(delta) {
    if (root.rows.length === 0) return
    pointerGate.reset()
    var visible = Math.max(1, Math.floor(listView.height / root.rowHeight))
    var next = root.selectedIndex + delta * visible
    root.selectedIndex = Math.max(0, Math.min(root.rows.length - 1, next))
    listView.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  // Hover moves the selection, but only on real pointer movement. Rows sliding
  // under a stationary cursor raise the same hover signals, which would drag the
  // selection back mid-list while arrowing down through a scrolling list.
  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.selectedIndex = index
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  Component.onCompleted: {
    ZenbuState.overlay = root
    root.readZsettings()
    root.readSize()
    root.readEmoji()
    root.readSshHosts()
  }

  // ------------------------------------------------------------ data feeds
  // Everything read off disk goes through `head`, which puts the ceiling in
  // front of the read rather than behind it. FileView has no way to stop short
  // of the end of a file — by the time text() exists the whole file is in a
  // shell that stays up for days — so it does not do the reading here; it only
  // watches, with blockAllReads set so it never pulls a file into memory. A
  // file past its ceiling arrives cut off, fails to parse, and is ignored.
  //
  // None of these are Zenbu's to trust: settings and the size file can be
  // restored from a backup, and the emoji list and SSH config belong to other
  // programs entirely.
  readonly property int settingsCeiling: 64 * 1024
  readonly property int sizeCeiling: 64
  readonly property int emojiCeiling: 8 * 1024 * 1024
  readonly property int sshCeiling: 1024 * 1024

  FileView {
    path: root.settingsFile
    printErrors: false
    watchChanges: true
    blockAllReads: true
    preload: false
    onFileChanged: root.readZsettings()
  }

  function readZsettings() { settingsReader.running = false; settingsReader.running = true }
  function readSize() { sizeReader.running = false; sizeReader.running = true }
  function readEmoji() { emojiReader.running = false; emojiReader.running = true }
  function readSshHosts() { sshReader.running = false; sshReader.running = true }

  Process {
    id: settingsReader
    command: ["python3", "-c", root.safeRead,
              root.settingsFile, String(root.settingsCeiling)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var s = JSON.parse(text)
          if (s && typeof s === "object" && !Array.isArray(s)) root.zsettings = s
        } catch (e) {}
      }
    }
    // No settings file yet is a perfectly good answer: it means first run,
    // and the defaults in memory are the truth. Either way the answer is in,
    // and settings may now be written back.
    onExited: root.settingsLoaded = true
  }

  Process {
    id: sizeReader
    command: ["python3", "-c", root.safeRead,
              root.sizeFile, String(root.sizeCeiling)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var m = String(text || "").trim().match(/^(\d+)x(\d+)$/)
        if (m) { root.userWidth = parseInt(m[1]); root.userHeight = parseInt(m[2]) }
      }
    }
  }

  Process {
    id: emojiReader
    command: ["python3", "-c", root.safeRead,
              root.omarchyPath + "/shell/plugins/emojis/emojis.json", String(root.emojiCeiling)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text)
          root.emojiData = Array.isArray(d) ? d : []
        } catch (e) { root.emojiData = [] }
        if (root.opened && root.tab === "emoji") root.rebuild()
      }
    }
  }

  Process {
    id: sshReader
    command: ["python3", "-c", root.safeRead,
              root.home + "/.ssh/config", String(root.sshCeiling)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var hosts = []
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var m = lines[i].match(/^\s*Host\s+(.+)$/i)
          if (!m) continue
          var names = m[1].trim().split(/\s+/)
          for (var j = 0; j < names.length; j++) {
            if (names[j].indexOf("*") < 0 && names[j].indexOf("?") < 0) hosts.push(names[j])
          }
        }
        root.sshHosts = hosts
        if (root.opened && root.tab === "ssh") root.rebuild()
      }
    }
  }

  // Files: fd does the searching. Empty filter lists the home folder itself;
  // anything typed becomes a fixed-string filename search across home, with
  // the heavyweight junk folders excluded so results come back fast.
  Timer {
    id: fdDebounce
    interval: 160
    onTriggered: {
      if (root.tab !== "files" || !root.opened) return
      var args = ["fd", "--absolute-path", "--fixed-strings", "--ignore-case",
                  "--max-results", "40", "--search-path", root.home,
                  "--exclude", ".cache", "--exclude", ".git", "--exclude", "node_modules",
                  "--exclude", "Games", "--exclude", ".local/share/Steam",
                  "--exclude", ".local/share/Trash", "--exclude", "__pycache__",
                  "--exclude", "site-packages", "--exclude", "Backups",
                  "--exclude", ".local/share/nvim"]
      // The hidden-files setting applies to the plain home listing too;
      // without it the setting appeared to do nothing until you typed.
      if (root.zsettings.hiddenFiles !== false) args.push("--hidden")
      if (root.filterText.trim() === "") args = args.concat(["--max-depth", "1"])
      else {
        if (root.zsettings.systemFiles === true)
          args = args.concat(["--search-path", "/usr", "--search-path", "/etc", "--search-path", "/opt"])
        // Everything after `--` is the pattern, never an option. Typing "-h"
        // in Files otherwise ran fd's help and rendered it as a list of files.
        args.push("--")
        args.push(root.filterText.trim())
      }
      fdProc.command = args
      fdProc.running = false
      fdProc.running = true
    }
  }

  Process {
    id: fdProc
    stdout: StdioCollector {
      id: fdOut
      waitForEnd: true
      onStreamFinished: {
        var lines = String(fdOut.text || "").split("\n")
        var out = []
        for (var i = 0; i < lines.length && out.length < 40; i++) {
          var p = lines[i].trim()
          if (!p) continue
          var isDir = p.charAt(p.length - 1) === "/"
          var clean = isDir ? p.slice(0, -1) : p
          var base = clean.split("/").pop()
          var rel = clean.indexOf(root.home) === 0 ? "~" + clean.slice(root.home.length) : clean
          var dir = rel.slice(0, rel.length - base.length)
          out.push({
            label: base,
            sub: dir,
            icon: "",
            glyph: isDir ? "󰉋" : "󰈔",
            hint: "open",
            path: clean
          })
        }
        root.fileRows = out
        if (root.opened && root.tab === "files") {
          root.rows = out
          if (root.selectedIndex >= out.length) root.selectedIndex = Math.max(0, out.length - 1)
          pointerGate.reset()
        }
      }
    }
  }

  Process {
    id: qalcCheck
    command: ["bash", "-c", "command -v qalc"]
    onExited: function(code) { root.qalcAvailable = code === 0 }
  }

  // qalc reads a trailing "in" as inches, so every "<amount> in <unit>" comes
  // back as an area or a volume: "6 feet in meters" is 0.04645152 m³ (feet
  // times inches times metres) and "1 hour in minutes" is 5.4864 kg/mPa. It is
  // the phrasing most people reach for first, so it cannot be left to qalc.
  // Rewrite only the LAST "in" of "<expr> in <unit words>" to "to": the greedy
  // prefix keeps "3 in in cm" as "3 in to cm", so a real inches operand
  // survives, and a tail holding digits or operators ("2 in + 3 cm") never
  // matches at all.
  function calcNormalize(expr) {
    return expr.replace(/^(.*)\sin\s+([A-Za-z€$¥£₩ ]+)$/, "$1 to $2")
  }

  // qalc parses any bare word as a product of units and prefixes, so "asdfgh"
  // answers "311.04 rg·s³" with the same confidence as a real sum. It also
  // exits 0 and prints a result whatever it was given, so there is no error to
  // detect after the fact — the guard has to be here, before it is asked.
  // Anything holding a digit or an operator is a calculation; a bare word is
  // only one if it names a constant qalc would recognise on its own.
  readonly property var calcConstants: ["pi", "e", "tau", "phi", "golden"]
  function looksCalculable(expr) {
    var t = String(expr).trim()
    if (!t) return false
    if (/[0-9]/.test(t)) return true
    if (/[+\-*\/^%()]/.test(t)) return true
    return root.calcConstants.indexOf(t.toLowerCase()) >= 0
  }

  // Whether an answer is money, and so whether the rate date below applies to
  // it. qalc does not say, so this reads the shape of its output: a leading
  // currency symbol, or a trailing three-letter code. It answers no when it is
  // unsure — an un-annotated exchange rate is a small loss, "rates 28 Aug"
  // stapled to sqrt(2) is a wrong statement.
  function isCurrencyResult(res) {
    var s = String(res || "").trim()
    if (!s) return false
    return /^[¥$€£₩₹₽¢]/.test(s) || /\b[A-Z]{3}$/.test(s)
  }

  Timer {
    id: calcDebounce
    interval: 140
    onTriggered: {
      if (root.tab !== "calc" || !root.opened || !root.filterText.trim() || !root.qalcAvailable) return
      if (!root.looksCalculable(root.filterText)) {
        root.calcResult = ""
        root.calcExpr = ""
        root.rows = root.calcRows()
        return
      }
      root.calcSent = root.filterText
      // -m caps the calculation at half a second. Without it "(10^9)!" never
      // returns, and nothing here kills it: the process would sit pegged in
      // the background for the rest of the shell's life, one per keystroke.
      // -m bounds the calculation; `timeout` bounds the process. They are not
      // the same wall — -m does not cover qalc's own startup, and this runs on
      // every keystroke inside a shell that stays up for days.
      calcProc.command = ["timeout", "5", "qalc", "-m", "500", "-t", "--",
                          root.calcNormalize(root.filterText)]
      calcProc.running = false
      calcProc.running = true
    }
  }

  Process {
    id: calcProc
    stdout: StdioCollector {
      id: calcOut
      waitForEnd: true
      onStreamFinished: {
        // Stamped with the expression that was SENT, not whatever has been
        // typed since — otherwise a slow answer is shown, and copied on
        // Enter, as the result of a different sum.
        root.calcResult = String(calcOut.text || "").trim()
        root.calcExpr = root.calcSent
        if (root.opened && root.tab === "calc") root.rows = root.calcRows()
      }
    }
  }

  // ------------------------------------------------------- exchange rates
  // qalc answers currency conversions from a rates file, and libqalculate
  // ships one inside the package — so a fresh install converts money using
  // whatever the rates were on the day the distribution built it, to ten
  // decimal places, with nothing on screen to say so. Zenbu reads the date out
  // of that file and prints it beside the answer. Refreshing it is a separate,
  // opt-in thing below; the date is shown either way, which is the part that
  // stops a stale number from being presented as a live one.
  //
  // A user-owned file in ~/.local/share takes precedence over the packaged one
  // in /usr/share — verified by fetching once and watching 100 EUR move from
  // ¥18531 (packaged, 2026-07-06) to ¥18592 (fetched, 2026-08-28).
  readonly property string userRatesFile: root.home + "/.local/share/qalculate/eurofxref-daily.xml"
  readonly property string sysRatesFile: "/usr/share/qalculate/eurofxref-daily.xml"
  readonly property int ratesCeiling: 256 * 1024
  property string ratesDate: ""
  property bool ratesReadingUser: false
  property bool ratesChecked: false
  property bool ratesFetched: false

  readonly property var ratesMonths: ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  readonly property string ratesLabel: {
    var m = String(root.ratesDate).match(/^(\d{4})-(\d{2})-(\d{2})$/)
    if (!m) return ""
    var mi = parseInt(m[2], 10) - 1
    if (mi < 0 || mi > 11) return ""
    return parseInt(m[3], 10) + " " + root.ratesMonths[mi]
  }

  property string ratesRaw: ""
  property int ratesExit: -1
  property bool ratesTextIn: false

  function readRates(fromUser) {
    root.ratesReadingUser = fromUser
    root.ratesRaw = ""
    root.ratesExit = -1
    root.ratesTextIn = false
    ratesReader.command = ["python3", "-c", root.safeRead,
                           fromUser ? root.userRatesFile : root.sysRatesFile,
                           String(root.ratesCeiling)]
    ratesReader.running = false
    ratesReader.running = true
  }

  // The exit code and the output arrive on two signals with no guaranteed
  // order between them, so the decision waits until both are in.
  function ratesSettle() {
    if (!root.ratesTextIn || root.ratesExit < 0) return
    var m = String(root.ratesRaw).match(/time='(\d{4}-\d{2}-\d{2})'/)
    if (m) {
      root.ratesDate = m[1]
      if (root.opened && root.tab === "calc") root.rows = root.calcRows()
      root.checkRatesStamp()
      return
    }
    // Fall back to the packaged file ONLY when the user's copy is genuinely
    // absent (safeRead exits 2). If it is there but was refused — a symlink, a
    // FIFO, past the ceiling — or holds no date, then qalc may be reading it
    // and this has no idea what rates the answer used. Showing the packaged
    // date there would be a confident false statement, which is the one thing
    // this annotation exists to prevent, so it says nothing instead.
    if (root.ratesReadingUser && root.ratesExit === 2) { root.readRates(false); return }
    root.checkRatesStamp()
  }

  // The ECB publishes on TARGET business days only, and posts each day's fix at
  // around 16:00 CET — so for most of the week the date INSIDE the file is
  // legitimately older than today. Gating the fetch on that date meant a
  // download every Saturday, every Sunday, every holiday and every weekday
  // morning, each one writing back a file carrying the date it already had.
  // What decides whether there is anything to fetch is when the file was last
  // WRITTEN, so that is what is asked.
  //
  // Stat through a descriptor opened O_NOFOLLOW, for the same reason every
  // read here does: the path sits in a directory this plugin does not own, and
  // a symlink planted at it should be refused rather than followed.
  readonly property string safeStamp: [
    'import os, stat, sys, time',
    'try:',
    '    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)',
    'except OSError:',
    '    raise SystemExit(1)',
    'try:',
    '    st = os.fstat(fd)',
    'finally:',
    '    os.close(fd)',
    'if not stat.S_ISREG(st.st_mode):',
    '    raise SystemExit(1)',
    'sys.stdout.write(time.strftime("%Y-%m-%d", time.localtime(st.st_mtime)))'
  ].join("\n")

  property string ratesStamp: ""
  property int stampExit: -1
  property bool stampTextIn: false

  function checkRatesStamp() {
    if (root.ratesFetched) return
    if ((root.zsettings.rates || "off") !== "daily") return
    root.ratesStamp = ""
    root.stampExit = -1
    root.stampTextIn = false
    stampReader.command = ["python3", "-c", root.safeStamp, root.userRatesFile]
    stampReader.running = false
    stampReader.running = true
  }

  // Same two-signal wait as ratesSettle: the output and the exit code arrive
  // independently, and deciding on either alone reads an empty stamp as "never
  // fetched" half the time.
  function stampSettle() {
    if (!root.stampTextIn || root.stampExit < 0) return
    root.maybeFetchRates()
  }

  Process {
    id: stampReader
    stdout: StdioCollector {
      id: stampOut
      waitForEnd: true
      onStreamFinished: {
        root.ratesStamp = String(stampOut.text || "").trim()
        root.stampTextIn = true
        root.stampSettle()
      }
    }
    // A stamp is only ever a reason NOT to fetch. A stat that failed — no file
    // yet, or one refused — falls through to fetching, which is the answer an
    // absent rates file has always given.
    onExited: function(code) { root.stampExit = code; root.stampSettle() }
  }

  Process {
    id: ratesReader
    stdout: StdioCollector {
      id: ratesOut
      waitForEnd: true
      onStreamFinished: {
        root.ratesRaw = String(ratesOut.text || "")
        root.ratesTextIn = true
        root.ratesSettle()
      }
    }
    onExited: function(code) { root.ratesExit = code; root.ratesSettle() }
  }

  // Off unless the user turned it on in settings. Zenbu is a launcher; opening
  // it must not reach the network on its own, and the packaged rates still
  // answer with their date shown. Once per Zenbu run, never on the keystroke
  // path, and silent on failure — an unreachable ECB leaves the old date on
  // screen, which is already the honest answer.
  function maybeFetchRates() {
    if (root.ratesFetched) return
    if ((root.zsettings.rates || "off") !== "daily") return
    var today = Qt.formatDate(new Date(), "yyyy-MM-dd")
    if (root.ratesStamp === today) return
    root.ratesFetched = true
    ratesProc.running = false
    ratesProc.running = true
  }

  Process {
    id: ratesProc
    // qalc -e downloads and exits; the trivial expression is only there to
    // give it something to do afterwards. `timeout` is the wall-clock bound —
    // this is off the typing path, but a hung fetch should still not outlive
    // the answer it was meant to improve.
    command: ["timeout", "20", "qalc", "-e", "-t", "--", "1+1"]
    onExited: function(code) {
      if (code === 0) root.readRates(true)
    }
  }

  // -------------------------------------------------------------------- ui
  // Drag any edge or corner of the card to resize it. The card stays
  // centered, so a drag grows or shrinks it symmetrically; the size is
  // remembered across sessions.
  // Settings form building blocks: one look for every option row.
  component SettingLabel: Text {
    textFormat: Text.PlainText
    width: Style.space(200)
    anchors.verticalCenter: parent.verticalCenter
    color: root.foreground
    opacity: 0.75
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  component SettingPill: Rectangle {
    id: pill
    property string label
    property bool active: false
    property bool locked: false
    signal picked()
    width: pillLabel.width + Style.spacing.md * 2
    height: Style.space(28)
    radius: root.cornerRadius
    color: pill.active ? root.selectedBackground : "transparent"
    border.color: pill.active ? root.foreground : root.border
    border.width: pill.active ? 1 : 0
    opacity: pill.locked ? 0.45 : 1

    Text {
      textFormat: Text.PlainText
      id: pillLabel
      anchors.centerIn: parent
      text: pill.label
      color: pill.active ? root.selectedText : root.foreground
      opacity: pill.active ? 1 : 0.55
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      anchors.fill: parent
      enabled: !pill.locked
      cursorShape: Qt.PointingHandCursor
      onClicked: pill.picked()
    }
  }

  component ResizeHandle: MouseArea {
    property int edgeX: 0
    property int edgeY: 0
    property real startGX: 0
    property real startGY: 0
    property int startW: 0
    property int startH: 0

    hoverEnabled: true
    cursorShape: edgeX !== 0 && edgeY !== 0
      ? (edgeX === edgeY ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor)
      : (edgeX !== 0 ? Qt.SizeHorCursor : Qt.SizeVerCursor)

    onPressed: function(mouse) {
      var g = mapToItem(null, mouse.x, mouse.y)
      startGX = g.x
      startGY = g.y
      startW = root.cardWidth
      startH = root.cardHeight
    }
    onPositionChanged: function(mouse) {
      if (!pressed) return
      var g = mapToItem(null, mouse.x, mouse.y)
      // Centered card grows both ways per pixel dragged; the top-anchored
      // dropdown only grows downward, so it tracks the pointer 1:1.
      var fy = root.dropdown ? 1 : 2
      if (edgeX !== 0) root.userWidth = startW + 2 * edgeX * (g.x - startGX)
      if (edgeY !== 0) root.userHeight = startH + fy * edgeY * (g.y - startGY)
    }
    onReleased: root.saveSize()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "zenbu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.dropdown ? "transparent" : root.scrim }

    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      // Centered pop-up by default; the dropdown state re-anchors the card
      // under the bar icon. AnchorChanges is the only reliable way to switch
      // anchor layouts — a ternary returning undefined leaves the old anchor
      // active, silently overriding x.
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter

      states: State {
        name: "dropdown"
        when: root.dropdown

        AnchorChanges {
          target: card
          anchors.horizontalCenter: undefined
          anchors.verticalCenter: undefined
          anchors.top: card.parent.top
        }

        PropertyChanges {
          target: card
          anchors.topMargin: root.barDrop
          x: Math.max(Style.gapsOut, Math.min(panel.width - card.width - Style.gapsOut,
               (root.anchorX >= 0 ? root.anchorX
                : root.lastAnchorX >= 0 ? root.lastAnchorX
                : panel.width / 2) - card.width / 2))
        }
      }
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.capturing) {
            root.captureKey(event)
            event.accepted = true
            return
          }
          if (root.view !== "list") {
            if (event.key === Qt.Key_Escape) {
              if (root.view === "settings") root.view = "list"
              else root.dismiss()
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.applyDrafts()
            }
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Comma && (event.modifiers & Qt.ControlModifier)) {
            root.syncDrafts()
            root.view = "settings"
            event.accepted = true
          } else if (event.key === Qt.Key_Tab) {
            root.switchTab(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Backtab) {
            root.switchTab(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Left) {
            root.switchTab(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Right) {
            root.switchTab(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.selectPage(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.selectPage(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate(root.selectedIndex)
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        // Tab strip
        Row {
          id: tabStrip
          visible: root.view === "list"
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.tabs
            delegate: Rectangle {
              required property var modelData
              required property int index

              readonly property bool current: index === root.tabIndex

              width: (tabStrip.width - Style.space(4) * (root.tabs.length - 1)) / root.tabs.length
              height: Math.max(Style.space(30), Style.font.body + Style.spacing.controlPaddingY * 2)
              radius: root.cornerRadius
              color: current ? root.selectedBackground : "transparent"

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: parent.modelData.label
                color: parent.current ? root.selectedText : root.foreground
                opacity: parent.current ? 1 : 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setTab(parent.index)
              }
            }
          }
        }

        // Search line
        Text {
          textFormat: Text.PlainText
          visible: root.view === "list"
          width: parent.width
          text: root.filterText || root.tabs[root.tabIndex].placeholder
          color: root.foreground
          opacity: root.filterText ? 1 : 0.55
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          elide: Text.ElideRight
        }

        Rectangle {
          visible: root.view === "list"
          width: parent.width; height: 1; color: root.border; opacity: 0.6
        }

        // Result list
        Item {
          visible: root.view === "list"
          width: parent.width
          height: parent.height - y - footerRow.height - parent.spacing

          ListView {
            id: listView
            anchors.fill: parent
            model: root.rows
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: row
              required property var modelData
              required property int index

              readonly property bool current: index === root.selectedIndex

              width: listView.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: current ? root.selectedBackground : "transparent"

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.md
                anchors.rightMargin: Style.spacing.md
                spacing: Style.spacing.md

                Item {
                  width: root.iconSlot
                  height: parent.height

                  Image {
                    anchors.centerIn: parent
                    visible: modelData.icon !== ""
                    source: modelData.icon || ""
                    width: Style.space(24)
                    height: Style.space(24)
                    sourceSize.width: Style.space(24)
                    sourceSize.height: Style.space(24)
                    asynchronous: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    visible: modelData.icon === ""
                    text: modelData.glyph || ""
                    color: current ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: root.tab === "emoji" ? Style.font.displayLarge : Style.font.title
                  }
                }

                Column {
                  width: parent.width - root.iconSlot - Style.spacing.md * 2 - hintText.width
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: modelData.label || ""
                    color: current ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    visible: (modelData.sub || "") !== ""
                    text: modelData.sub || ""
                    color: current ? root.selectedText : root.foreground
                    opacity: 0.62
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  id: hintText
                  anchors.verticalCenter: parent.verticalCenter
                  visible: current && (modelData.hint || "") !== ""
                  text: current ? (modelData.hint || "") : ""
                  color: root.selectedText
                  opacity: 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectFromPointer(row.index, row, { x: rowMouse.mouseX, y: rowMouse.mouseY })
                onPositionChanged: (mouse) => root.selectFromPointer(row.index, row, mouse)
                onClicked: {
                  root.selectedIndex = row.index
                  root.activate(row.index)
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            visible: root.rows.length === 0
            text: "No matches" + (root.filterText ? " for “" + root.filterText + "”" : "")
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
        }

        // Greeter (first run) and settings (⚙) share one form.
        Item {
          visible: root.view !== "list"
          width: parent.width
          height: parent.height - y - footerRow.height - parent.spacing

          Column {
            width: parent.width
            spacing: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.view === "greeter" ? "全部 · welcome to Zenbu" : "Zenbu settings"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }

            Text {
              textFormat: Text.PlainText
              visible: root.view === "greeter"
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Apps, emoji, files, calculator, windows and SSH — one overlay. Choose how you want to summon it. Everything here can be changed later from the ⚙ in the corner."
              color: root.foreground
              opacity: 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md

              SettingLabel { text: "Hotkey" }

              Rectangle {
                width: Style.space(180)
                height: Style.space(28)
                radius: root.cornerRadius
                color: "transparent"
                border.color: root.border
                border.width: 1

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: root.capturing ? "press your keys…"
                    : (root.draftShortcut !== "" ? root.draftShortcut : "none set")
                  color: root.foreground
                  opacity: root.capturing || root.draftShortcut === "" ? 0.6 : 1
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              SettingPill {
                label: root.capturing ? "cancel" : "record"
                active: true
                onPicked: { root.capturing = !root.capturing; root.captureNote = "" }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.captureNote !== "" || root.capturing
              text: root.captureNote !== "" ? root.captureNote
                : "Pick a combination nothing else uses — already-taken keys will trigger their old action instead."
              wrapMode: Text.WordWrap
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              spacing: Style.spacing.md

              SettingLabel { text: "Summon style" }

              Row {
                spacing: Style.space(4)

                SettingPill {
                  label: "centered pop-up"
                  active: root.draftMode === "center"
                  onPicked: root.draftMode = "center"
                }

                SettingPill {
                  label: "dropdown from the bar icon"
                  active: root.draftMode === "dropdown"
                  onPicked: { root.draftMode = "dropdown"; root.draftBarIcon = true }
                }
              }
            }

            Row {
              spacing: Style.spacing.md

              SettingLabel { text: "Bar icon 全" }

              Row {
                spacing: Style.space(4)

                SettingPill {
                  label: "shown"
                  active: root.draftBarIcon
                  locked: root.draftMode === "dropdown"
                  onPicked: root.draftBarIcon = true
                }

                SettingPill {
                  label: "hidden"
                  active: !root.draftBarIcon
                  locked: root.draftMode === "dropdown"
                  onPicked: root.draftBarIcon = false
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: root.draftMode === "dropdown"
                anchors.verticalCenter: parent.verticalCenter
                text: "needed for dropdown"
                color: root.foreground
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              visible: root.draftBarIcon
              spacing: Style.spacing.md

              SettingLabel { text: "Icon position" }

              Row {
                spacing: Style.space(4)

                Repeater {
                  model: ["left", "center", "right"]
                  delegate: SettingPill {
                    required property var modelData
                    label: modelData
                    active: root.draftBarSection === modelData
                    onPicked: root.draftBarSection = modelData
                  }
                }
              }
            }

            Row {
              spacing: Style.spacing.md

              SettingLabel { text: "Emoji click" }

              Row {
                spacing: Style.space(4)

                Repeater {
                  model: [
                    { id: "copy", label: "copies it" },
                    { id: "type", label: "types it" },
                    { id: "both", label: "both" }
                  ]
                  delegate: SettingPill {
                    required property var modelData
                    label: modelData.label
                    active: root.draftEmojiAction === modelData.id
                    onPicked: root.draftEmojiAction = modelData.id
                  }
                }
              }
            }

            Row {
              spacing: Style.spacing.md

              SettingLabel { text: "Hidden files and folders" }

              Row {
                spacing: Style.space(4)

                SettingPill {
                  label: "show"
                  active: root.draftHiddenFiles
                  onPicked: root.draftHiddenFiles = true
                }

                SettingPill {
                  label: "don't show"
                  active: !root.draftHiddenFiles
                  onPicked: root.draftHiddenFiles = false
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "in file search — like ~/.config"
                color: root.foreground
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              spacing: Style.spacing.md

              SettingLabel { text: "Exchange rates" }

              Row {
                spacing: Style.space(4)

                SettingPill {
                  label: "packaged"
                  active: root.draftRates !== "daily"
                  onPicked: root.draftRates = "off"
                }

                SettingPill {
                  label: "refresh daily"
                  active: root.draftRates === "daily"
                  onPicked: root.draftRates = "daily"
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "refreshing fetches from the European Central Bank"
                color: root.foreground
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              spacing: Style.spacing.md

              SettingLabel { text: "System files" }

              Row {
                spacing: Style.space(4)

                SettingPill {
                  label: "show"
                  active: root.draftSystemFiles
                  onPicked: root.draftSystemFiles = true
                }

                SettingPill {
                  label: "don't show"
                  active: !root.draftSystemFiles
                  onPicked: root.draftSystemFiles = false
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "in file search — /usr, /etc and /opt"
                color: root.foreground
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.draftShortcut === "" && !root.draftBarIcon
              wrapMode: Text.WordWrap
              text: "⚠ No hotkey and no bar icon: Zenbu could then only be opened from a terminal with `omarchy-shell shell toggle io.github.weedwhitesandwine.zenbu`."
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Applying saves these choices, updates Zenbu's own marked hotkey block in bindings.lua, and adds or removes the bar icon. Nothing else is touched."
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              spacing: Style.spacing.md

              Rectangle {
                width: applyLabel.width + Style.spacing.md * 3
                height: Style.space(32)
                radius: root.cornerRadius
                color: root.selectedBackground
                border.color: root.foreground
                border.width: 1

                Text {
                  textFormat: Text.PlainText
                  id: applyLabel
                  anchors.centerIn: parent
                  text: root.view === "greeter" ? "Start Zenbu" : "Apply"
                  color: root.selectedText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.applyDrafts()
                }
              }

              Rectangle {
                visible: root.view === "settings"
                width: cancelLabel.width + Style.spacing.md * 3
                height: Style.space(32)
                radius: root.cornerRadius
                color: "transparent"

                Text {
                  textFormat: Text.PlainText
                  id: cancelLabel
                  anchors.centerIn: parent
                  text: "Cancel"
                  color: root.foreground
                  opacity: 0.55
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.view = "list"
                }
              }
            }
          }
        }

        // Fixed footer: key hints, settings gear on the far right.
        Row {
          id: footerRow
          width: parent.width
          spacing: Style.spacing.md

          Text {
            textFormat: Text.PlainText
            width: parent.width - gearIcon.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            text: "Tab tabs · ↑↓ move · ⏎ act · Esc close"
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            id: gearIcon
            anchors.verticalCenter: parent.verticalCenter
            text: "󰒓"
            color: root.view === "settings" ? root.selectedText : root.foreground
            opacity: root.view === "settings" ? 1 : 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (root.view === "settings") root.view = "list"
                else { root.syncDrafts(); root.view = "settings" }
              }
            }
          }
        }
      }

      ResizeHandle {
        edgeX: -1
        width: 8
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
      }
      ResizeHandle {
        edgeX: 1
        width: 8
        anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
      }
      ResizeHandle {
        // The dropdown is pinned under the bar icon, so its top edge cannot
        // move: dragging it up grew the card downward, away from the pointer.
        enabled: !root.dropdown
        visible: !root.dropdown
        edgeY: -1
        height: 8
        anchors { top: parent.top; left: parent.left; right: parent.right }
      }
      ResizeHandle {
        edgeY: 1
        height: 8
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
      }
      ResizeHandle {
        // The dropdown is pinned under the bar icon, so its top edge cannot
        // move: dragging it up grew the card downward, away from the pointer.
        enabled: !root.dropdown
        visible: !root.dropdown
        edgeX: -1
        edgeY: -1
        width: 16
        height: 16
        anchors { left: parent.left; top: parent.top }
      }
      ResizeHandle {
        // The dropdown is pinned under the bar icon, so its top edge cannot
        // move: dragging it up grew the card downward, away from the pointer.
        enabled: !root.dropdown
        visible: !root.dropdown
        edgeX: 1
        edgeY: -1
        width: 16
        height: 16
        anchors { right: parent.right; top: parent.top }
      }
      ResizeHandle {
        edgeX: -1
        edgeY: 1
        width: 16
        height: 16
        anchors { left: parent.left; bottom: parent.bottom }
      }
      ResizeHandle {
        edgeX: 1
        edgeY: 1
        width: 16
        height: 16
        anchors { right: parent.right; bottom: parent.bottom }
      }
    }
  }
}
