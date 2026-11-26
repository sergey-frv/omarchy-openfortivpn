import QtQuick
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// The shield glyph for the bar and the panel hero. The state picks the tone;
// "connecting" pulses the glyph's alpha. The pulse drives the color, not
// opacity, so the bar's icon bounds (which read opacity) stay put, and it
// stops entirely while animations are off.
Text {
  id: root

  property string vpnState: "down"
  property real iconSize: Style.font.icon
  property string fontFamily: Style.font.family
  property color dimColor: Qt.darker(Commons.Color.foreground, 1.55)
  property color normalColor: Commons.Color.foreground
  property color accentColor: Commons.Color.accent
  property color errorColor: Commons.Color.urgent

  readonly property var spec: Model.iconSpec(vpnState)
  readonly property color tint: spec.tone === "normal" ? normalColor
    : spec.tone === "accent" ? accentColor
    : spec.tone === "error" ? errorColor
    : dimColor
  readonly property bool pulseActive: spec.pulse === true && !Style.reduceMotion
  property real pulse: 1.0

  textFormat: Text.PlainText
  text: spec.glyph
  font.family: root.fontFamily
  font.pixelSize: root.iconSize
  color: Qt.rgba(tint.r, tint.g, tint.b, tint.a * (pulseActive ? pulse : 1.0))

  SequentialAnimation on pulse {
    running: root.pulseActive
    loops: Animation.Infinite
    NumberAnimation { to: 0.35; duration: Style.duration(650); easing.type: Easing.OutCubic }
    NumberAnimation { to: 1.0; duration: Style.duration(650); easing.type: Easing.OutCubic }
  }
}
