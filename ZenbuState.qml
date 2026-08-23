pragma Singleton
import QtQuick

// Rendezvous point between the bar icon (BarWidget.qml) and the overlay
// (Zenbu.qml): both live in the shell's QML engine, so the icon can drive
// the overlay directly through this singleton.
QtObject {
  property var overlay: null

  // Where the bar is and how big it is, published by the icon so the overlay
  // can drop from it correctly. The overlay has no reference to the bar of its
  // own, and assuming a 46-pixel bar across the top put the card nowhere near
  // the icon for anyone with a bottom, left or right bar — or none showing.
  property string barPosition: "top"
  property int barSize: 0
  property bool barHidden: false
  property bool barKnown: false
}
