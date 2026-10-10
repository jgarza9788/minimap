import QtQuick

// Workspace-switch effect for the whole widget, one per animation style:
//
//   smooth     the widget dips and recovers
//   cyberpunk  screen tearing: slices of the widget (a live texture of it) jump
//              sideways, with RGB fringes and a scanline
//   fun        the widget squashes and bounces back with a big overshoot
//   magic      a shimmer sweeps across and sparkles fly
//   ripple     an ink ripple spreads from the workspace number
//
// `source` is the item that holds the widget's content; slices are cut from it.
Item {
  id: wf

  property Item source: null
  property string style: "smooth"
  property color bg: "#000000"
  property color accent: "#88cc33"
  property real ox: width / 2          // where a ripple starts (the number)
  property real oy: height / 2

  // ---- entry point ----------------------------------------------------------
  function play() {
    if (!source) return
    if (style === "cyberpunk") { tearAnim.restart(); scanAnim.restart(); fringeAnim.restart() }
    else if (style === "fun") bounceAnim.restart()
    else if (style === "magic") { sheenAnim.restart(); sparkAnim.restart() }
    else if (style === "ripple") rippleAnim.restart()
    else dipAnim.restart()
  }

  // ---- smooth ---------------------------------------------------------------
  SequentialAnimation {
    id: dipAnim
    NumberAnimation { target: wf.source; property: "opacity"; to: 0.65; duration: 120; easing.type: Easing.OutSine }
    NumberAnimation { target: wf.source; property: "opacity"; to: 1; duration: 320; easing.type: Easing.InOutSine }
  }

  // ---- fun ------------------------------------------------------------------
  SequentialAnimation {
    id: bounceAnim
    ScriptAction { script: if (wf.source) wf.source.transformOrigin = Item.Center }
    NumberAnimation { target: wf.source; property: "scale"; to: 0.78; duration: 90; easing.type: Easing.OutSine }
    NumberAnimation { target: wf.source; property: "scale"; to: 1; duration: 620; easing.type: Easing.OutBack; easing.overshoot: 3.4 }
  }

  // ---- ripple ---------------------------------------------------------------
  Item {
    anchors.fill: parent
    clip: true
    Rectangle {
      id: ink
      width: 0
      height: width
      radius: width / 2
      x: wf.ox - width / 2
      y: wf.oy - height / 2
      color: wf.accent
      opacity: 0
    }
  }
  ParallelAnimation {
    id: rippleAnim
    NumberAnimation { target: ink; property: "width"; from: 0; to: Math.max(wf.width, wf.height) * 2.4; duration: 760; easing.type: Easing.OutCubic }
    SequentialAnimation {
      NumberAnimation { target: ink; property: "opacity"; to: 0.32; duration: 100 }
      NumberAnimation { target: ink; property: "opacity"; to: 0; duration: 660; easing.type: Easing.InOutSine }
    }
  }

  // ---- magic ----------------------------------------------------------------
  Item {
    anchors.fill: parent
    clip: true
    Rectangle {
      id: sheen
      y: -wf.height * 0.2
      width: Math.max(14, wf.width * 0.22)
      height: wf.height * 1.4
      rotation: 20
      opacity: 0
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: "transparent" }
        GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.5) }
        GradientStop { position: 1.0; color: "transparent" }
      }
    }
  }
  SequentialAnimation {
    id: sheenAnim
    ScriptAction { script: { sheen.x = -sheen.width; sheen.opacity = 1 } }
    NumberAnimation { target: sheen; property: "x"; to: wf.width; duration: 720; easing.type: Easing.InOutSine }
    ScriptAction { script: sheen.opacity = 0 }
  }
  property real sparkT: 1
  NumberAnimation { id: sparkAnim; target: wf; property: "sparkT"; from: 0; to: 1; duration: 950; easing.type: Easing.OutCubic }
  Repeater {
    model: 9
    Text {
      textFormat: Text.PlainText
      required property int index
      readonly property real seed: ((index * 7919) % 97) / 97
      x: wf.width * ((index + 0.5) / 9) - width / 2
      y: wf.height * (0.2 + 0.6 * seed) - wf.sparkT * (6 + 10 * seed) - height / 2
      text: index % 2 === 0 ? "✦" : "✧"
      color: Qt.lighter(wf.accent, 1.5)
      font.pixelSize: 7 + (index % 3) * 2
      opacity: wf.sparkT >= 1 ? 0 : Math.sin(wf.sparkT * Math.PI)
      scale: 0.6 + Math.sin(wf.sparkT * Math.PI) * 0.8
      rotation: wf.sparkT * 120 * (index % 2 === 0 ? 1 : -1)
    }
  }

  // ---- cyberpunk: screen tearing --------------------------------------------
  // Each strip hides its row of the widget and draws that row, cut from a live
  // texture of the widget, shifted sideways. Strips are re-rolled in hard steps.
  property bool tearing: false
  property var strips: []

  function reroll(amount) {
    var list = []
    var n = 3 + Math.floor(Math.random() * 3)
    for (var i = 0; i < n; i++) {
      var h = 2 + Math.random() * Math.max(2, height * 0.16)
      list.push({
        y: Math.random() * Math.max(1, height - h),
        h: h,
        dx: (Math.random() < 0.5 ? -1 : 1) * (3 + Math.random() * amount)
      })
    }
    strips = list
  }

  SequentialAnimation {
    id: tearAnim
    ScriptAction { script: { wf.tearing = true; wf.reroll(16) } }
    PauseAnimation { duration: 55 }
    ScriptAction { script: wf.reroll(10) }
    PauseAnimation { duration: 45 }
    ScriptAction { script: wf.reroll(22) }
    PauseAnimation { duration: 60 }
    ScriptAction { script: wf.reroll(8) }
    PauseAnimation { duration: 50 }
    ScriptAction { script: wf.reroll(4) }
    PauseAnimation { duration: 45 }
    ScriptAction { script: { wf.tearing = false; wf.strips = [] } }
  }

  Repeater {
    model: wf.tearing ? wf.strips : []

    Item {
      required property var modelData
      y: modelData.y
      width: wf.width
      height: modelData.h

      Rectangle {
        anchors.fill: parent
        color: wf.bg
      }
      ShaderEffectSource {
        x: modelData.dx
        width: wf.width
        height: modelData.h
        sourceItem: wf.source
        sourceRect: Qt.rect(0, modelData.y, wf.width, modelData.h)
        live: true
        hideSource: false
      }
    }
  }

  // RGB fringes and a scanline that sweeps down.
  Rectangle {
    id: fringeC
    anchors.fill: parent
    color: "#00e5ff"
    opacity: 0
  }
  Rectangle {
    id: fringeM
    anchors.fill: parent
    color: "#ff2bd6"
    opacity: 0
  }
  SequentialAnimation {
    id: fringeAnim
    ScriptAction { script: { fringeC.x = -2; fringeM.x = 2; fringeC.opacity = 0.07; fringeM.opacity = 0.07 } }
    PauseAnimation { duration: 90 }
    ScriptAction { script: { fringeC.x = 3; fringeM.x = -3; fringeC.opacity = 0.04; fringeM.opacity = 0.05 } }
    PauseAnimation { duration: 80 }
    ScriptAction { script: { fringeC.opacity = 0; fringeM.opacity = 0; fringeC.x = 0; fringeM.x = 0 } }
  }
  Rectangle {
    id: scan
    width: wf.width
    height: 1
    color: "#9dfcff"
    opacity: 0
  }
  SequentialAnimation {
    id: scanAnim
    ScriptAction { script: { scan.y = 0; scan.opacity = 0.9 } }
    NumberAnimation { target: scan; property: "y"; to: wf.height; duration: 240; easing.type: Easing.Linear }
    ScriptAction { script: scan.opacity = 0 }
  }
}
