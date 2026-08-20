import QtQuick
import qs.Commons
import qs.Ui as Ui
import "."

// Optional bar icon for Zenbu. Whether it appears in the bar at all is the
// user's choice, made in Zenbu's greeter/settings (which add or remove it
// from the bar layout). Clicking it opens the overlay — centered, or
// dropped down from this icon, per the user's chosen style.
// (qs.Ui is imported under a namespace because this file is itself named
// BarWidget.qml — a bare `BarWidget` would resolve to the file itself.)
Ui.BarWidget {
  id: root
  moduleName: "io.github.weedwhitesandwine.zenbu"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function anchorCenterX() {
    var g = button.mapToItem(null, button.width / 2, 0)
    return g.x
  }

  // Shape contract for shell summon/toggle routing — forward to the overlay.
  readonly property bool opened: ZenbuState.overlay ? ZenbuState.overlay.opened === true : false
  function open() { if (ZenbuState.overlay) ZenbuState.overlay.openAt(root.anchorCenterX()) }
  function close() { if (ZenbuState.overlay) ZenbuState.overlay.dismiss() }

  Ui.BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "全"
    tooltipText: ""
    onPressed: function(b) {
      if (!ZenbuState.overlay) return
      if (ZenbuState.overlay.opened) ZenbuState.overlay.dismiss()
      else ZenbuState.overlay.openAt(root.anchorCenterX())
    }
  }
}
