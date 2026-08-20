import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

import qs.Commons
import qs.Ui

// Zenbu (全部, "everything"): one overlay, six tabs — Apps, Emoji, Files,
// Calc, Windows, SSH. Type to filter the current tab, Tab to cycle tabs,
// Enter to act. Colors, fonts, and spacing all come from the shell's theme
// singletons, so Zenbu always matches the active Omarchy theme.
Item {
  id: root

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

  function saveSize() {
    Quickshell.execDetached(["bash", "-c",
      'mkdir -p "$(dirname "$1")" && printf "%s\\n" "$2" > "$1"', "--",
      root.sizeFile, root.cardWidth + "x" + root.cardHeight])
  }

  // -------------------------------------------------------------- lifecycle
  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    if (root.shell && root.shell.appLibrary) root.shell.appLibrary.refreshIcons()
    root.rebuild()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }

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
    root.rebuild()
  }

  function setFilter(next) {
    root.filterText = next
    root.selectedIndex = 0
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
    else if (t === "calc") { root.rows = root.calcRows(); calcDebounce.restart() }
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
          hint: "type it",
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
    if (!root.filterText.trim())
      return [{ label: "Type a calculation…", sub: "35kg to lbs · 15% * 4300 · sqrt(2) · 8*7+12", icon: "", glyph: "󰃬", hint: "" }]
    if (root.calcResult && root.calcExpr === root.filterText)
      return [{ label: root.calcResult, sub: root.filterText, icon: "", glyph: "=", hint: "copy", copyText: root.calcResult }]
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
      Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-menu-emoji-insert", row.emoji])
    } else if (row.path !== undefined) {
      root.dismiss()
      Quickshell.execDetached(["xdg-open", row.path])
    } else if (row.windowRef !== undefined) {
      root.dismiss()
      try { row.windowRef.activate() } catch (e) {}
    } else if (row.host !== undefined) {
      root.dismiss()
      Quickshell.execDetached(["alacritty", "-e", "ssh", row.host])
    } else if (row.copyText !== undefined) {
      root.dismiss()
      Quickshell.execDetached(["wl-copy", row.copyText])
    }
  }

  function select(delta) {
    if (root.rows.length === 0) return
    root.selectedIndex = (root.selectedIndex + delta + root.rows.length) % root.rows.length
    listView.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function selectPage(delta) {
    if (root.rows.length === 0) return
    var visible = Math.max(1, Math.floor(listView.height / root.rowHeight))
    var next = root.selectedIndex + delta * visible
    root.selectedIndex = Math.max(0, Math.min(root.rows.length - 1, next))
    listView.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  // ------------------------------------------------------------ data feeds
  FileView {
    path: root.sizeFile
    printErrors: false
    onLoaded: {
      var m = String(text() || "").trim().match(/^(\d+)x(\d+)$/)
      if (m) { root.userWidth = parseInt(m[1]); root.userHeight = parseInt(m[2]) }
    }
  }

  FileView {
    path: root.omarchyPath + "/shell/plugins/emojis/emojis.json"
    onLoaded: {
      try { root.emojiData = JSON.parse(text()) } catch (e) { root.emojiData = [] }
      if (root.opened && root.tab === "emoji") root.rebuild()
    }
  }

  FileView {
    path: root.home + "/.ssh/config"
    printErrors: false
    onLoaded: {
      var hosts = []
      var lines = String(text() || "").split("\n")
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
                  "--exclude", ".local/share/Trash", "--exclude", "__pycache__"]
      if (root.filterText.trim() === "") args = args.concat(["--max-depth", "1"])
      else args = args.concat([root.filterText.trim()])
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
        }
      }
    }
  }

  Timer {
    id: calcDebounce
    interval: 140
    onTriggered: {
      if (root.tab !== "calc" || !root.opened || !root.filterText.trim()) return
      calcProc.command = ["qalc", "-t", root.filterText]
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
        root.calcResult = String(calcOut.text || "").trim()
        root.calcExpr = root.filterText
        if (root.opened && root.tab === "calc") root.rows = root.calcRows()
      }
    }
  }

  // -------------------------------------------------------------------- ui
  // Drag any edge or corner of the card to resize it. The card stays
  // centered, so a drag grows or shrinks it symmetrically; the size is
  // remembered across sessions.
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
      if (edgeX !== 0) root.userWidth = startW + 2 * edgeX * (g.x - startGX)
      if (edgeY !== 0) root.userHeight = startH + 2 * edgeY * (g.y - startGY)
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

    Rectangle { anchors.fill: parent; color: root.scrim }

    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
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
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
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
          width: parent.width
          text: root.filterText || root.tabs[root.tabIndex].placeholder
          color: root.foreground
          opacity: root.filterText ? 1 : 0.55
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          elide: Text.ElideRight
        }

        Rectangle { width: parent.width; height: 1; color: root.border; opacity: 0.6 }

        // Result list
        Item {
          width: parent.width
          height: parent.height - y

          ListView {
            id: listView
            anchors.fill: parent
            model: root.rows
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
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
                    width: parent.width
                    text: modelData.label || ""
                    color: current ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    elide: Text.ElideRight
                  }

                  Text {
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
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) root.selectedIndex = index
                onClicked: root.activate(index)
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: root.rows.length === 0
            text: "No matches" + (root.filterText ? " for “" + root.filterText + "”" : "")
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
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
        edgeX: -1
        edgeY: -1
        width: 16
        height: 16
        anchors { left: parent.left; top: parent.top }
      }
      ResizeHandle {
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
