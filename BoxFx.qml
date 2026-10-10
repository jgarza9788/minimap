import QtQuick
import qs.Commons

// Effects layer for one box (or the workspace number). Sits on top of its
// parent, fills it, and is themed by `style`:
//
//   smooth     soft glow pulses            cyberpunk  glitch, RGB split, flicker
//   fun        shockwave rings, wobble     magic      sparkles and a shimmer
//   ripple     Material ink ripples
//
// `level` is the attention state: 0 none, 1 minor, 2 critical. Critical is
// louder, faster and drawn in the urgent colour; both keep a thin outline.
// `play()` fires one-shot effects. The parent should apply `wobbleRot` as its
// rotation and multiply `flick` into its opacity.
Item {
  id: fx

  property string style: "smooth"
  property int level: 0
  property color accent: "#88cc33"
  property color urgent: "#ff3b3b"
  property color warn: "#f2b134"
  property color fill: "#88cc33"     // the box colour, for tearing strips
  property real corner: 2

  readonly property color tone: level >= 2 ? urgent : (level === 1 ? warn : accent)
  readonly property real power: level >= 2 ? 1.0 : 0.6
  property real wobbleRot: 0
  property real flick: 1

  anchors.fill: parent

  // ---- One-shots -----------------------------------------------------------
  // kind: "appear" | "focus" | "click" | "resolve".
  function play(kind, px, py) {
    var cx = px === undefined ? width / 2 : px
    var cy = py === undefined ? height / 2 : py
    if (kind === "resolve") {
      flashAt(0.8, 420, accent)
      if (style === "ripple") rippleAt(cx, cy, accent)
      else if (style === "fun") ringBurst(accent)
      else if (style === "magic") sparkBurst(accent)
      else if (style === "cyberpunk") glitchBurst()
      return
    }
    if (kind === "click") {
      if (style === "ripple") rippleAt(cx, cy, accent)
      else if (style === "magic") sparkBurst(accent)
      return
    }
    if (style === "cyberpunk") glitchBurst()
    else if (style === "fun") { ringBurst(accent); wobble(8) }
    else if (style === "magic") { sparkBurst(accent); shimmer() }
    else if (style === "ripple") rippleAt(cx, cy, accent)
  }

  // One attention cycle in the current style, in the level's colour.
  function attend() {
    if (style === "cyberpunk") { glitchBurst(); flashAt(0.5 * power, 260, tone) }
    else if (style === "fun") { ringBurst(tone); wobble(level >= 2 ? 15 : 8) }
    else if (style === "magic") { sparkBurst(tone); shimmer() }
    else if (style === "ripple") rippleAt(width / 2, height / 2, tone)
    else flashAt(0.55 * power, level >= 2 ? 600 : 1100, tone)
  }

  Timer {
    interval: fx.level >= 2 ? 900 : 2200
    repeat: true
    running: fx.level > 0 && fx.visible
    triggeredOnStart: true
    onTriggered: fx.attend()
  }

  // Glow: rings fading outward from the box, pulsing with the alert. Border
  // only, so the box's own colour is never tinted.
  property real pulse: 0
  SequentialAnimation on pulse {
    running: fx.level > 0 && fx.visible
    loops: Animation.Infinite
    NumberAnimation { to: 1; duration: fx.level >= 2 ? 420 : 1100; easing.type: fx.style === "cyberpunk" ? Easing.Linear : Easing.InOutSine }
    NumberAnimation { to: 0; duration: fx.level >= 2 ? 420 : 1100; easing.type: fx.style === "cyberpunk" ? Easing.Linear : Easing.InOutSine }
  }
  Repeater {
    model: 3

    Rectangle {
      required property int index
      anchors.fill: parent
      anchors.margins: -(1.2 + index * 1.5)
      radius: fx.corner + 1.2 + index * 1.5
      color: "transparent"
      border.width: 1.6
      border.color: fx.tone
      opacity: fx.level > 0
        ? (fx.level >= 2 ? 0.9 : 0.6) * (0.35 + 0.65 * fx.pulse) / (1 + index * 1.1)
        : 0
      Behavior on opacity { NumberAnimation { duration: 200 } }
    }
  }

  // Steady marker so an alert is visible between cycles.
  Rectangle {
    anchors.fill: parent
    radius: fx.corner
    color: "transparent"
    border.width: 1
    border.color: fx.tone
    opacity: fx.level >= 2 ? 0.95 : (fx.level === 1 ? 0.55 : 0)
    Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.InOutSine } }
    Behavior on border.color { ColorAnimation { duration: 260 } }
  }

  // ---- Flash ---------------------------------------------------------------
  Rectangle {
    id: flashRect
    anchors.fill: parent
    radius: fx.corner
    opacity: 0
  }
  SequentialAnimation {
    id: flashAnim
    property real peak: 0.6
    property int dur: 500
    NumberAnimation { target: flashRect; property: "opacity"; to: flashAnim.peak; duration: Math.max(60, flashAnim.dur * 0.25); easing.type: Easing.OutSine }
    NumberAnimation { target: flashRect; property: "opacity"; to: 0; duration: flashAnim.dur * 0.75; easing.type: Easing.InOutSine }
  }
  function flashAt(peak, dur, col) {
    flashRect.color = col
    flashAnim.peak = peak
    flashAnim.dur = dur
    flashAnim.restart()
  }

  // ---- Ripple (Material ink) -----------------------------------------------
  Item {
    id: rippleClip
    anchors.fill: parent
    clip: true

    Rectangle {
      id: dot
      property real cx: 0
      property real cy: 0
      width: 0
      height: width
      radius: width / 2
      x: cx - width / 2
      y: cy - height / 2
      opacity: 0
    }
  }
  ParallelAnimation {
    id: rippleAnim
    NumberAnimation { target: dot; property: "width"; from: 0; to: Math.max(fx.width, fx.height) * 2.6; duration: 620; easing.type: Easing.OutCubic }
    SequentialAnimation {
      NumberAnimation { target: dot; property: "opacity"; to: 0.5; duration: 90 }
      NumberAnimation { target: dot; property: "opacity"; to: 0; duration: 530; easing.type: Easing.InOutSine }
    }
  }
  function rippleAt(px, py, col) {
    dot.color = col
    dot.cx = px
    dot.cy = py
    rippleAnim.restart()
  }

  // ---- Shockwave ring ------------------------------------------------------
  Rectangle {
    id: ring
    anchors.centerIn: parent
    width: parent.width
    height: parent.height
    radius: fx.corner + 1
    color: "transparent"
    border.width: 2
    opacity: 0
  }
  ParallelAnimation {
    id: ringAnim
    NumberAnimation { target: ring; property: "scale"; from: 1; to: 2.1; duration: 620; easing.type: Easing.OutCubic }
    NumberAnimation { target: ring; property: "opacity"; from: 0.9; to: 0; duration: 620; easing.type: Easing.OutCubic }
  }
  function ringBurst(col) {
    ring.border.color = col
    ringAnim.restart()
  }

  // ---- Wobble --------------------------------------------------------------
  SequentialAnimation {
    id: wobbleAnim
    property real amp: 8
    NumberAnimation { target: fx; property: "wobbleRot"; to: -wobbleAnim.amp; duration: 70; easing.type: Easing.OutSine }
    NumberAnimation { target: fx; property: "wobbleRot"; to: wobbleAnim.amp; duration: 110; easing.type: Easing.InOutSine }
    NumberAnimation { target: fx; property: "wobbleRot"; to: -wobbleAnim.amp * 0.5; duration: 100; easing.type: Easing.InOutSine }
    NumberAnimation { target: fx; property: "wobbleRot"; to: wobbleAnim.amp * 0.25; duration: 100; easing.type: Easing.InOutSine }
    NumberAnimation { target: fx; property: "wobbleRot"; to: 0; duration: 120; easing.type: Easing.OutSine }
  }
  function wobble(amp) {
    wobbleAnim.amp = amp
    wobbleAnim.restart()
  }

  // ---- Glitch (cyberpunk) ----------------------------------------------------
  property real gx: 0
  Rectangle {
    z: -1
    x: fx.gx
    width: fx.width
    height: fx.height
    radius: fx.corner
    color: "#00e5ff"
    opacity: fx.gx !== 0 ? 0.75 : 0
  }
  Rectangle {
    z: -1
    x: -fx.gx
    y: fx.gx !== 0 ? 1 : 0
    width: fx.width
    height: fx.height
    radius: fx.corner
    color: "#ff2bd6"
    opacity: fx.gx !== 0 ? 0.75 : 0
  }
  // Screen tear: two thin slices of the box jump sideways.
  property real tearY1: 0
  property real tearY2: 0
  property real tearDx1: 0
  property real tearDx2: 0
  function reTear(on) {
    tearY1 = Math.random() * Math.max(1, height - 2)
    tearY2 = Math.random() * Math.max(1, height - 2)
    tearDx1 = on ? (Math.random() < 0.5 ? -1 : 1) * (3 + Math.random() * 6) : 0
    tearDx2 = on ? (Math.random() < 0.5 ? -1 : 1) * (2 + Math.random() * 5) : 0
  }
  Rectangle { x: fx.tearDx1; y: fx.tearY1; width: fx.width; height: 2; color: fx.fill; visible: fx.tearDx1 !== 0 }
  Rectangle { x: fx.tearDx2; y: fx.tearY2; width: fx.width; height: 1.5; color: fx.fill; visible: fx.tearDx2 !== 0 }

  SequentialAnimation {
    id: glitchAnim
    // Hard steps, no easing: jitter the ghosts, tear the box, flicker it.
    ScriptAction { script: { fx.gx = 3; fx.flick = 0.3; fx.reTear(true) } }
    PauseAnimation { duration: 45 }
    ScriptAction { script: { fx.gx = -3; fx.flick = 1; fx.reTear(true) } }
    PauseAnimation { duration: 40 }
    ScriptAction { script: { fx.gx = 2; fx.flick = 0.5; fx.reTear(true) } }
    PauseAnimation { duration: 55 }
    ScriptAction { script: { fx.gx = -2; fx.flick = 1; fx.reTear(true) } }
    PauseAnimation { duration: 40 }
    ScriptAction { script: { fx.gx = 1; fx.flick = 0.7; fx.reTear(true) } }
    PauseAnimation { duration: 40 }
    ScriptAction { script: { fx.gx = 0; fx.flick = 1; fx.reTear(false) } }
  }
  function glitchBurst() { glitchAnim.restart() }

  // ---- Sparkles + shimmer (magic) ---------------------------------------------
  property real sparkT: 1
  property color sparkColor: "#ffffff"
  Repeater {
    model: 6

    Text {

      textFormat: Text.PlainText
      required property int index
      readonly property real ang: (index / 6) * Math.PI * 2 + 0.4
      readonly property real dist: 6 + (1 - Math.pow(1 - fx.sparkT, 2)) * (10 + (index % 3) * 5)
      x: fx.width / 2 + Math.cos(ang) * (fx.width * 0.35 + dist) - width / 2
      y: fx.height / 2 + Math.sin(ang) * (fx.height * 0.35 + dist) - height / 2
      text: index % 2 === 0 ? "✦" : "✧"
      color: fx.sparkColor
      font.pixelSize: 7 + (index % 3) * 2
      opacity: fx.sparkT >= 1 ? 0 : Math.sin(fx.sparkT * Math.PI)
      scale: 0.6 + Math.sin(fx.sparkT * Math.PI) * 0.7
      rotation: fx.sparkT * 90 * (index % 2 === 0 ? 1 : -1)
    }
  }
  NumberAnimation { id: sparkAnim; target: fx; property: "sparkT"; from: 0; to: 1; duration: 900; easing.type: Easing.OutCubic }
  function sparkBurst(col) {
    sparkColor = Qt.lighter(col, 1.5)
    sparkAnim.restart()
  }

  Item {
    anchors.fill: parent
    clip: true
    Rectangle {
      id: sheen
      y: -fx.height * 0.2
      width: fx.width * 0.4
      height: fx.height * 1.4
      rotation: 20
      opacity: 0
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: "transparent" }
        GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.55) }
        GradientStop { position: 1.0; color: "transparent" }
      }
    }
  }
  SequentialAnimation {
    id: sheenAnim
    ScriptAction { script: { sheen.x = -sheen.width; sheen.opacity = 1 } }
    NumberAnimation { target: sheen; property: "x"; to: fx.width; duration: 650; easing.type: Easing.InOutSine }
    ScriptAction { script: sheen.opacity = 0 }
  }
  function shimmer() { sheenAnim.restart() }
}
