pragma Singleton
import QtQuick

// Rendezvous point between the bar icon (BarWidget.qml) and the overlay
// (Zenbu.qml): both live in the shell's QML engine, so the icon can drive
// the overlay directly through this singleton.
QtObject {
  property var overlay: null
}
