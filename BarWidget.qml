import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Workspace label | separator | a row of rectangles, one per window of this
// monitor's active workspace, in layout order. A rectangle's length is the
// window's share of the monitor, windows stacked in one scrolling column are
// stacked rectangles. Focused = accent fill, on screen = foreground outline,
// scrolled off = muted. Left-click focuses, wheel changes workspace,
// right-click opens settings.
BarWidget {
  id: root
  moduleName: "jgarza.minimap"

  readonly property var cfg: Model.resolveSettings(settings)
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- Theme colours (live from colors.toml) -------------------------------
  property var themeColors: ({})
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.themeColors = Model.parseThemeColors(text(), Model.THEME_COLOR_KEYS)
    onFileChanged: reload()
    onLoadFailed: root.themeColors = {}
  }
  readonly property string bgHex: themeColors["background"] || String(Color.background)
  readonly property string fgHex: themeColors["foreground"] || String(root.fg)
  readonly property color accentColor: themeColors["accent"] || Color.accent
  readonly property color mutedColor: Model.ensureContrast(
    themeColors["muted"] || String(Color.muted), bgHex, fgHex, 1.8)

  // ---- Settings popup ------------------------------------------------------
  property bool settingsOpen: false
  readonly property bool opened: settingsOpen
  function open() { settingsOpen = true }
  function close() { settingsOpen = false }
  function toggle() { settingsOpen = !settingsOpen }

  function previewSetting(key, value) {
    var next = Object.assign({}, settings || {})
    next[key] = value
    settings = next
  }
  function saveSetting(key, value) {
    previewSetting(key, value)
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, settings)
  }

  // ---- Monitor / workspace -------------------------------------------------
  property int tick: 0
  readonly property string screenName: String(Screen.name || "")

  readonly property var barMonitor: {
    var _dep = tick
    var ms = Hyprland.monitors ? Hyprland.monitors.values : []
    for (var i = 0; i < ms.length; i++)
      if (ms[i] && String(ms[i].name) === screenName) return ms[i]
    return Hyprland.focusedMonitor || null
  }

  readonly property int workspaceId: {
    var m = barMonitor
    if (m && m.activeWorkspace && isFinite(Number(m.activeWorkspace.id)))
      return Number(m.activeWorkspace.id)
    return Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
  }

  readonly property var monitorSize: {
    var m = barMonitor
    if (!m) return null
    var s = Number(m.scale) || 1
    var w = Number(m.width) / s, h = Number(m.height) / s
    return w > 0 && h > 0 ? { width: w, height: h, x: Number(m.x) || 0, y: Number(m.y) || 0 } : null
  }

  readonly property var viewportRange: {
    var m = barMonitor
    if (!m) return null
    var s = Number(m.scale) || 1
    var mx = Number(m.x), my = Number(m.y)
    var mw = Number(m.width) / s, mh = Number(m.height) / s
    if (!isFinite(mx) || !isFinite(my) || !(mw > 0) || !(mh > 0)) return null
    return vertical ? { start: my, end: my + mh } : { start: mx, end: mx + mw }
  }

  readonly property string activeAddr: Model.normalizeAddress(
    Hyprland.activeToplevel ? Hyprland.activeToplevel.address : "")

  readonly property var rawColumns: {
    var _dep = tick
    if (workspaceId < 0 || !monitorSize) return []
    var tops = Hyprland.toplevels ? Hyprland.toplevels.values : []
    var clients = Model.eligibleClients(tops, workspaceId, cfg.showFloating)
    return Model.buildColumns(clients, monitorSize, viewportRange, vertical, activeAddr)
  }

  // Only swap the model when the drawn data really changed, so delegates (and
  // their hover state) survive the periodic polling.
  property var columns: []
  property string columnsSig: ""
  onRawColumnsChanged: {
    var sig = JSON.stringify(rawColumns)
    if (sig === columnsSig) return
    columnsSig = sig
    columns = rawColumns
  }

  function bump() {
    Hyprland.refreshToplevels()
    if (Hyprland.refreshMonitors) Hyprland.refreshMonitors()
    tick = (tick + 1) & 0x3fffffff
  }

  function dispatch(luaExpr, legacy) {
    Hyprland.dispatch(Hyprland.usingLua ? luaExpr : legacy)
  }
  function focusWindow(addr) {
    if (!addr) return
    dispatch("hl.dsp.focus({ window = \"address:" + addr + "\" })", "focuswindow address:" + addr)
  }
  function stepWorkspace(delta) {
    var rel = delta > 0 ? "r+1" : "r-1"
    dispatch("hl.dsp.focus({ workspace = \"" + rel + "\" })", "workspace " + rel)
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var n = String(event.name)
      // Carries the new focus right away; Hyprland.activeToplevel lags it.
      if (n === "activewindowv2") root.peek(Model.normalizeAddress(event.data))
      if (n.indexOf("window") !== -1 || n.indexOf("workspace") !== -1
          || n.indexOf("monitor") !== -1 || n === "changefloatingmode" || n === "fullscreen") {
        root.bump()
        burstTimer.count = 0
        burstTimer.restart()
      }
    }
  }
  // Follow the scroll animation to its resting place after an event.
  Timer {
    id: burstTimer
    interval: 180
    repeat: true
    property int count: 0
    onTriggered: { root.bump(); if (++count >= 11) stop() }
  }
  // Viewport shifts from plain scroll binds raise no event.
  Timer { interval: 2500; running: root.visible; repeat: true; onTriggered: root.bump() }
  // ---- Layout --------------------------------------------------------------
  // One scale for everything so each box keeps its window's exact aspect
  // ratio: a full-height window is `thickness` tall. If the tape would be
  // wider than maxWidth the whole thing shrinks, not just the widths.
  readonly property real thickness: Math.max(8, Math.round(barSize * 0.75))
  readonly property real crossSize: monitorSize ? (vertical ? monitorSize.width : monitorSize.height) : 1
  readonly property real mainTotal: {
    var t = 0
    for (var i = 0; i < columns.length; i++) t += columns[i].len
    return t
  }
  readonly property real scale: {
    var base = thickness / crossSize
    var n = columns.length
    if (n === 0 || mainTotal <= 0) return base
    var room = cfg.maxWidth - (n - 1) * cfg.gap
    return Math.min(base, Math.max(0.0001, room / mainTotal))
  }

  // ---- Motion ----------------------------------------------------------------
  // Everything physical moves on the same spring so the whole widget feels like
  // one material. Lower damping = bouncier, higher spring = snappier.
  readonly property var motion: Model.motionFor(cfg.animStyle)
  readonly property real springK: motion.k
  readonly property real springD: motion.d
  // Fixed, not themed: some themes' urgent colour is nearly their accent, and a critical
  // alert must never look like the focused box.
  readonly property color urgentColor: "#ff3b3b"

  // The tape: flat absolutely-positioned rows, reconciled into a ListModel so
  // each box keeps its delegate and glides when windows open, close or resize.
  readonly property var tape: Model.layoutTape(columns, {
    scale: scale, gap: cfg.gap, stackGap: Math.max(cfg.gap, 3), vertical: vertical
  })
  property string tapeSig: ""
  property real tapeTotal: 0

  ListModel { id: rows }

  function rowIndex(key) {
    for (var i = 0; i < rows.count; i++)
      if (rows.get(i).key === key) return i
    return -1
  }

  function syncRows() {
    var items = tape.items
    var sig = JSON.stringify(items)
    if (sig === tapeSig) return
    tapeSig = sig
    tapeTotal = tape.total
    var seen = {}
    for (var i = 0; i < items.length; i++) {
      var it = items[i]
      seen[it.key] = true
      var idx = rowIndex(it.key)
      if (idx < 0) {
        rows.append({
          key: it.key, address: it.address, bx: it.bx, by: it.by, bw: it.bw, bh: it.bh,
          focused: it.focused, onScreen: it.onScreen, tabsJson: it.tabsJson,
          floating: it.floating, pinned: it.pinned, fullscreen: it.fullscreen,
          closing: false, closedAt: 0, fresh: reapReady
        })
      } else {
        var cur = rows.get(idx)
        for (var f in it)
          if (cur[f] !== it[f]) rows.setProperty(idx, f, it[f])
        if (cur.closing) { rows.setProperty(idx, "closing", false); rows.setProperty(idx, "closedAt", 0) }
      }
    }
    var any = false
    for (var r = 0; r < rows.count; r++) {
      var row = rows.get(r)
      if (!seen[row.key] && !row.closing) {
        rows.setProperty(r, "closing", true)
        rows.setProperty(r, "closedAt", Date.now())
      }
      if (rows.get(r).closing) any = true
    }
    if (any) reaper.restart()
  }
  onTapeChanged: syncRows()
  Component.onCompleted: { bump(); syncRows(); reapReady = true }
  property bool reapReady: false

  // Closed boxes linger while they shrink away, then get dropped.
  Timer {
    id: reaper
    interval: 500
    onTriggered: {
      var keep = false
      for (var i = rows.count - 1; i >= 0; i--) {
        var row = rows.get(i)
        if (!row.closing) continue
        if (Date.now() - row.closedAt >= 450) rows.remove(i)
        else keep = true
      }
      if (keep) restart()
    }
  }

  // The widget's own width follows the tape on a spring, so neighbours in the
  // bar glide instead of snapping.
  property real animWidth: layout.implicitWidth
  property real animHeight: layout.implicitHeight
  Behavior on animWidth { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }
  Behavior on animHeight { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }
  implicitWidth: animWidth
  implicitHeight: animHeight

  // Workspace label: slides up and out, the new one slides in from below.
  readonly property string workspaceLabel: Model.formatWorkspace(workspaceId, cfg.numberStyle)
  property string shownLabel: workspaceLabel
  onWorkspaceLabelChanged: {
    if (!ready) { shownLabel = workspaceLabel; return }
    if (cfg.animStyle === "cyberpunk") {
      decodeStep = 0
      decoding = true
      shownLabel = decodedLabel(workspaceLabel, 0)
      scrambleTimer.restart()
      numberFx.play("focus")
      return
    }
    labelSwap.restart()
    numberFx.play("focus")
  }

  // Cyberpunk: the label DECODES. Every character starts as glyph noise and
  // locks onto its real value one after another, left to right, while the
  // number glows cyan until the last one lands.
  property int decodeStep: 0
  property bool decoding: false
  readonly property string decodeGlyphs: "0123456789ABCDEF#$%&@/<>=+*"
  function decodedLabel(target, step) {
    var out = ""
    for (var i = 0; i < target.length; i++) {
      var lockAt = 4 + i * 3                       // later characters lock later
      out += step >= lockAt || target.charAt(i) === " "
        ? target.charAt(i)
        : decodeGlyphs.charAt(Math.floor(Math.random() * decodeGlyphs.length))
    }
    return out
  }
  Timer {
    id: scrambleTimer
    interval: 48
    repeat: true
    onTriggered: {
      var target = root.workspaceLabel
      root.decodeStep++
      root.shownLabel = root.decodedLabel(target, root.decodeStep)
      if (root.decodeStep >= 4 + Math.max(1, target.length) * 3) {
        root.shownLabel = target
        root.decoding = false
        stop()
      }
    }
  }

  SequentialAnimation {
    id: labelSwap
    ParallelAnimation {
      NumberAnimation { target: numText; property: "opacity"; to: 0; duration: root.motion.swapOut; easing.type: Easing.InSine }
      NumberAnimation { target: numText; property: "yOff"; to: -numText.height * 0.5; duration: root.motion.swapOut; easing.type: Easing.InSine }
    }
    ScriptAction { script: { root.shownLabel = root.workspaceLabel; numText.yOff = numText.height * 0.5 } }
    ParallelAnimation {
      NumberAnimation { target: numText; property: "opacity"; to: 1; duration: root.motion.swapIn; easing.type: root.cfg.animStyle === "fun" || root.cfg.animStyle === "magic" ? Easing.OutBack : Easing.OutCubic }
      NumberAnimation { target: numText; property: "yOff"; to: 0; duration: root.motion.swapIn; easing.type: root.cfg.animStyle === "fun" || root.cfg.animStyle === "magic" ? Easing.OutBack : Easing.OutCubic }
    }
  }

  GridLayout {
    id: layout
    x: 0
    y: 0
    columns: root.vertical ? 1 : 3
    rowSpacing: Style.space(8)
    columnSpacing: Style.space(10)

    Item {
      id: numHolder
      Layout.alignment: Qt.AlignCenter
      implicitWidth: numText.implicitWidth
      implicitHeight: numText.implicitHeight
      Behavior on implicitWidth { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }

      // Click the number to jump to whatever is alerting (critical first, then newest).
      MouseArea {
        anchors.fill: parent
        anchors.margins: -3
        z: 10
        acceptedButtons: Qt.LeftButton
        cursorShape: root.hasAlerts ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.jumpToAlert()
      }

      // Themed cue for alerts on other workspaces / notifications nobody owns.
      BoxFx {
        id: numberFx
        anchors.fill: parent
        anchors.margins: -3
        corner: 5
        style: root.cfg.animStyle
        level: Math.max(root.otherLevel, root.numberFlash)
        accent: root.accentColor
        urgent: root.urgentColor
      }

      Text {

        textFormat: Text.PlainText
        id: numText
        property real yOff: 0
        y: yOff
        text: root.shownLabel
        color: root.decoding ? "#5ff3ff" : root.accentColor
        font.family: root.fontFamily
        font.pixelSize: Math.round(Style.font.body * 1.35)
        font.bold: true
        Behavior on color { ColorAnimation { duration: root.decoding ? 0 : 260; easing.type: Easing.InOutSine } }
      }
    }

    Rectangle {
      Layout.alignment: Qt.AlignCenter
      Layout.preferredWidth: root.vertical ? root.thickness : 1
      Layout.preferredHeight: root.vertical ? 1 : root.thickness
      color: root.mutedColor
      opacity: 0.7
      Behavior on color { ColorAnimation { duration: 260 } }
    }

    Item {
      id: tapeItem
      Layout.alignment: Qt.AlignCenter
      implicitWidth: root.vertical ? root.thickness : root.tapeTotal
      implicitHeight: root.vertical ? root.tapeTotal : root.thickness
      Behavior on implicitWidth { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }
      Behavior on implicitHeight { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }

      // Where a dragged box will land.
      Rectangle {
        visible: root.dragActive && root.dragTarget >= 0 && root.dragTarget !== root.dragFrom && root.dragTarget < root.tape.cols.length
        z: 60
        radius: 1
        color: root.accentColor
        readonly property var col: visible ? root.tape.cols[root.dragTarget] : null
        readonly property real edge: col ? (root.dragTarget > root.dragFrom ? col.start + col.len + root.cfg.gap / 2 : col.start - root.cfg.gap / 2) : 0
        x: root.vertical ? 0 : edge - 1
        y: root.vertical ? edge - 1 : 0
        width: root.vertical ? parent.width : 2
        height: root.vertical ? 2 : parent.height
      }

      Repeater {
        model: rows

        Rectangle {
          id: rect
          required property string key
          required property string address
          required property real bx
          required property real by
          required property real bw
          required property real bh
          required property bool focused
          required property bool onScreen
          required property string tabsJson
          required property bool floating
          required property bool pinned
          required property bool fullscreen
          required property bool closing
          required property bool fresh

          readonly property var tabsData: tabsJson !== "" ? JSON.parse(tabsJson) : []
          readonly property bool tabbed: tabsData.length > 1
          // Dark marks on a light box, light marks on a dark one (boxes scrolled off screen are dark).
          readonly property color ink: (0.299 * color.r + 0.587 * color.g + 0.114 * color.b) > 0.45
            ? Qt.color(root.bgHex) : root.fg
          readonly property bool hot: root.hoverAddr !== "" && !closing && (root.hoverAddr === address
            || tabsData.some(function (t) { return t.address === root.hoverAddr }))

          // Geometry glides on springs; a brand-new box starts exactly in place.
          x: bx
          y: by
          width: bw
          height: bh
          Behavior on x { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }
          Behavior on y { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }
          Behavior on width { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }
          Behavior on height { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }

          // appear: 0 = collapsed, 1 = present. Grows in, shrinks out on close.
          property bool arrived: !fresh
          property real appear: closing || !arrived ? 0 : 1
          Behavior on appear { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.002 } }
          property real pop: 1
          property real lift: hot ? root.motion.hover : 1
          Behavior on lift { SpringAnimation { spring: 4; damping: 0.45; epsilon: 0.002 } }

          scale: Math.max(0.001, appear * pop * lift)
          transformOrigin: Item.Center
          radius: 2
          // While an alert is on, the whole box takes the alert colour (amber for
          // minor, red for critical).
          property real engage: attnLevel > 0 ? 1 : 0
          Behavior on engage { NumberAnimation { duration: 320; easing.type: Easing.InOutSine } }
          // Fully replaces the normal colours (focus / on-screen / off-screen); the
          // pulse only brightens it.
          readonly property color alertFill: Qt.lighter(fx.tone, 1 + 0.3 * fx.pulse)
          readonly property color baseFill: focused ? root.accentColor : (onScreen ? root.fg : root.mutedColor)
          color: engage > 0.001
            ? Qt.tint(baseFill, Qt.rgba(alertFill.r, alertFill.g, alertFill.b, engage))
            : baseFill
          rotation: fx.wobbleRot
          opacity: Math.min(1, appear * 1.8) * fx.flick * (focused || engage > 0.5 ? 1 : (hot ? 0.95 : (onScreen ? 0.75 : 0.4)))
          Behavior on color { enabled: rect.engage < 0.001 && rect.attnLevel === 0; ColorAnimation { duration: 260; easing.type: Easing.InOutSine } }
          Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.InOutSine } }

          // Taking focus gives the box a quick swell that settles back.
          onFocusedChanged: if (focused && root.ready && arrived) { focusPop.restart(); fx.play("focus") }
          SequentialAnimation {
            id: focusPop
            NumberAnimation { target: rect; property: "pop"; to: root.motion.popTo; duration: root.motion.popIn; easing.type: Easing.OutSine }
            NumberAnimation { target: rect; property: "pop"; to: 1; duration: root.motion.popOut; easing.type: Easing.OutBack; easing.overshoot: root.motion.popOvershoot }
          }

          // Drag-to-reorder: the box follows the pointer on a translate (not x/y, which spring).
          property bool dragging: false
          property real dragDX: 0
          property real dragDY: 0
          Behavior on dragDX { enabled: !rect.dragging; SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }
          Behavior on dragDY { enabled: !rect.dragging; SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }
          transform: Translate { x: rect.dragDX; y: rect.dragDY }
          z: dragging ? 50 : 0

          // fullscreen / pinned / floating marks
          StateMarks {
            z: 4
            visible: root.cfg.stateMarkers && !rect.closing
            pinned: rect.pinned
            fullscreen: rect.fullscreen
            floating: rect.floating
            ink: rect.ink
          }

          // Themed one-shot effects and the attention cue for this box.
          readonly property int attnLevel: root.cfg.attention ? (root.attention[key] || 0) : 0
          BoxFx {
            id: fx
            z: 5
            style: root.cfg.animStyle
            level: rect.attnLevel
            accent: root.accentColor
            urgent: root.urgentColor
            fill: rect.color
            onLevelChanged: if (level === 0 && root.ready) play("resolve")
          }

          // The hover label finds its anchor box through this registry.
          property string regAddr: ""
          function reg() {
            if (regAddr === address) return
            if (regAddr !== "") root.unregisterItem(regAddr, rect)
            regAddr = address
            root.registerItem(address, rect, 0)
          }
          onAddressChanged: reg()
          Component.onCompleted: { reg(); Qt.callLater(function () { rect.arrived = true; if (rect.fresh) fx.play("appear") }) }
          Component.onDestruction: {
            try { if (regAddr !== "") root.unregisterItem(regAddr, rect); root.hoverLeft(regAddr) } catch (e) {}
          }

          // Style "letter": a t in the middle of the box.
          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            opacity: rect.tabbed && root.cfg.groupStyle === "letter" ? 1 : 0
            visible: opacity > 0.01
            Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.InOutSine } }
            text: "t"
            color: rect.ink
            font.family: root.fontFamily
            font.pixelSize: Math.max(8, Math.round(rect.height * 0.8))
            font.bold: true
          }

          // Style "tabbar": one nub per tab along the top edge, the visible
          // tab dark, the rest faint. Each nub hovers/clicks as its window.
          Row {
            id: tabRow
            opacity: rect.tabbed && root.cfg.groupStyle === "tabbar" ? 1 : 0
            visible: opacity > 0.01
            Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.InOutSine } }
            x: 2
            y: 2
            spacing: 1
            readonly property int count: rect.tabbed ? rect.tabsData.length : 0
            readonly property real nubW: count > 0 ? (rect.width - 4 - (count - 1)) / count : 0

            Repeater {
              model: tabRow.count

              Rectangle {
                id: nub
                required property int index
                readonly property var tab: rect.tabsData[index] || null
                readonly property string tabAddr: tab ? tab.address : ""
                width: Math.max(1, tabRow.nubW)
                height: Math.max(3, Math.round(rect.height * 0.3))
                radius: height / 2.5
                color: rect.ink
                opacity: tab && tab.active ? 0.9 : 0.3
                Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.InOutSine } }

                property string regAddr: ""
                function reg() {
                  if (regAddr === tabAddr) return
                  if (regAddr !== "") root.unregisterItem(regAddr, nub)
                  regAddr = tabAddr
                  if (tabAddr !== "") root.registerItem(tabAddr, nub, 1)
                }
                onTabAddrChanged: reg()
                Component.onCompleted: reg()
                Component.onDestruction: {
                  try { if (regAddr !== "") root.unregisterItem(regAddr, nub); root.hoverLeft(regAddr) } catch (e) {}
                }

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -1
                  acceptedButtons: Qt.LeftButton | (root.cfg.boxActions ? (Qt.MiddleButton | Qt.RightButton) : 0)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  enabled: tabRow.visible && !rect.closing
                  onClicked: function (mouse) {
                    if (mouse.button === Qt.MiddleButton) root.runAction("close", nub.tabAddr)
                    else if (mouse.button === Qt.RightButton) root.openBoxMenu(nub, nub.tabAddr, true, rect.floating, rect.pinned, rect.fullscreen)
                    else root.focusWindow(nub.tabAddr)
                  }
                  onEntered: root.hoverEntered(nub.tabAddr)
                  onExited: root.hoverLeft(nub.tabAddr)
                }
              }
            }
          }

          MouseArea {
            id: body
            anchors.fill: parent
            // The bar claims left-button presses on every widget (it drags modules around), so a box
            // only ever sees left *clicks*. Dragging a box therefore uses the right button.
            acceptedButtons: Qt.LeftButton | (root.cfg.boxActions || root.cfg.dragReorder ? Qt.RightButton : 0) | (root.cfg.boxActions ? Qt.MiddleButton : 0)
            hoverEnabled: true
            enabled: !rect.closing
            cursorShape: Qt.PointingHandCursor
            property point pressAt: Qt.point(0, 0)
            property bool moved: false

            onPressed: function (mouse) {
              if (mouse.button !== Qt.RightButton) return
              // Measured in the tape's coordinates: the box itself moves under the pointer while dragged.
              pressAt = mapToItem(tapeItem, mouse.x, mouse.y)
              moved = false
              fx.play("click", mouse.x, mouse.y)
            }
            onPositionChanged: function (mouse) {
              if (!root.cfg.dragReorder || !(pressedButtons & Qt.RightButton)) return
              var here = mapToItem(tapeItem, mouse.x, mouse.y)
              var dx = here.x - pressAt.x, dy = here.y - pressAt.y
              if (!moved && Math.abs(root.vertical ? dy : dx) < 6) return
              if (!moved) { root.dragFrom = root.columnOfRow(rect); root.dragActive = true }
              moved = true
              rect.dragging = true
              rect.dragDX = root.vertical ? 0 : dx
              rect.dragDY = root.vertical ? dy : 0
              root.dragTarget = Model.slotAt(root.tape.cols, root.vertical ? here.y : here.x)
            }
            onReleased: function (mouse) {
              if (!rect.dragging) return
              var to = root.dragTarget
              var from = root.dragFrom
              rect.dragging = false
              rect.dragDX = 0
              rect.dragDY = 0
              root.dragActive = false
              root.reorderColumns(from, to, rect.address)
            }
            onClicked: function (mouse) {
              if (moved) { moved = false; return }
              if (mouse.button === Qt.MiddleButton) root.runAction("close", rect.address)
              else if (mouse.button === Qt.RightButton) {
                if (root.cfg.boxActions) root.openBoxMenu(rect, rect.address, rect.tabbed, rect.floating, rect.pinned, rect.fullscreen)
                else root.toggle()                       // only dragging is on: right-click still opens settings
              }
              else root.focusWindow(rect.address)
            }
            onEntered: { root.hoverEntered(rect.address); if (root.cfg.animStyle === "ripple") fx.play("click", mouseX, mouseY) }
            onExited: root.hoverLeft(rect.address)
          }
        }
      }
    }
  }

  // Style-specific effect when the workspace changes.
  WorkspaceFx {
    id: wsFx
    anchors.fill: parent
    z: 20
    source: layout
    style: root.cfg.animStyle
    bg: root.bgHex
    accent: root.accentColor
    ox: numHolder.x + numHolder.width / 2
    oy: numHolder.y + numHolder.height / 2
  }

  // Wheel switches workspace; right-click opens settings. Left presses fall
  // through to the rectangles.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.RightButton
    // With box actions or dragging on, right-presses on a box belong to the box (menu / drag);
    // settings move to the number and separator.
    onPressed: function (mouse) {
      if (!root.cfg.boxActions && !root.cfg.dragReorder) return
      var p = mapToItem(tapeItem, mouse.x, mouse.y)
      if (p.x >= 0 && p.y >= 0 && p.x <= tapeItem.width && p.y <= tapeItem.height) mouse.accepted = false
    }
    onClicked: root.toggle()
    onWheel: function (wheel) {
      if (wheel.angleDelta.y === 0) return
      root.stepWorkspace(wheel.angleDelta.y > 0 ? -1 : 1)
    }
  }

  // ---- Attention -------------------------------------------------------------
  // `alerts` is the source of truth: window address -> level (1 minor, 2
  // critical). reconcile() turns it into per-box cues (`attention`, keyed by
  // row key) for windows on this workspace and `otherLevel` for the number when
  // the alerting window lives elsewhere. A cue ends when its window is focused.
  property var alerts: ({})
  property var attention: ({})
  property int otherLevel: 0
  property int numberFlash: 0
  property var seenNotifs: ({})
  property var seenOrder: []
  function seenBefore(id) {
    if (seenNotifs[id]) return true
    seenNotifs[id] = true
    seenOrder.push(id)
    if (seenOrder.length > 200) delete seenNotifs[seenOrder.shift()]   // bounded
    return false
  }

  property var alertAt: ({})
  readonly property bool hasAlerts: Object.keys(alerts).length > 0

  function addAlert(addr, level) {
    if (!cfg.attention || !addr) return
    var next = Object.assign({}, alerts)
    next[addr] = Math.max(level, next[addr] || 0)
    alerts = next
    var times = Object.assign({}, alertAt)
    times[addr] = Date.now()
    alertAt = times
    reconcile()
  }

  // Find the window an alert belongs to (names + sender processes) and light it; an alert nobody
  // owns pulses the number instead.
  function raiseAlert(names, pids, level) {
    if (!cfg.attention) return
    var tops = Hyprland.toplevels ? Hyprland.toplevels.values : []
    var addr = Model.matchNotificationWindow(names,
      Model.eligibleClients(tops, workspaceId, true).concat(Model.eligibleClients(tops, NaN, true)), pids)
    if (addr === "") { flashNumber(level); return }
    if (addr === activeAddr) return
    addAlert(addr, level)
  }

  function jumpToAlert() {
    var target = Model.pickAlertTarget(alerts, alertAt)
    if (target !== "") focusWindow(target)
  }

  function reconcile() {
    var tops = Hyprland.toplevels ? Hyprland.toplevels.values : []
    var existing = {}
    for (var t = 0; t < tops.length; t++) existing[Model.normalizeAddress(tops[t].address)] = true
    var r = Model.reconcileAlerts(alerts, existing, activeAddr, columns)
    if (r.changed) alerts = r.alerts
    if (JSON.stringify(r.attention) !== JSON.stringify(attention)) attention = r.attention
    if (r.otherLevel !== otherLevel) otherLevel = r.otherLevel
  }
  onColumnsChanged: reconcile()
  onWorkspaceIdChanged: { reconcile(); if (ready) wsFx.play() }

  // A notification nobody owns still deserves a nudge on the number.
  Timer { id: numberFlashOff; interval: 3200; onTriggered: root.numberFlash = 0 }
  function flashNumber(level) {
    if (!cfg.attention) return
    numberFlash = Math.max(numberFlash, level)
    numberFlashOff.restart()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || event.name !== "urgent") return
      root.addAlert(Model.urgentAddress(event.data), 1)
    }
  }

  // Desktop notifications from ANY daemon (bin/notify-watch listens on the
  // session bus; it falls back to Omarchy's notification files via inotifywait).
  function script(name) {
    var value = String(Qt.resolvedUrl("bin/" + name))
    return value.indexOf("file://") === 0 ? decodeURIComponent(value.substring(7)) : value
  }
  // If the watcher dies, bring it back (2 s, doubling to 30 s) instead of
  // leaving alerts silently dead.
  property bool notifRun: true
  property int notifBackoff: 2000
  Timer {
    id: notifRestart
    onTriggered: root.notifRun = true
  }
  Process {
    id: notifWatch
    running: root.cfg.attention && root.notifRun
    command: ["python3", "-I", root.script("notify-watch"), "--source", "auto"]
    onExited: {
      if (!root.cfg.attention) return
      console.warn("jgarza.minimap: notify-watch exited, restarting in " + root.notifBackoff + " ms")
      root.notifRun = false
      notifRestart.interval = root.notifBackoff
      notifRestart.restart()
      root.notifBackoff = Math.min(30000, root.notifBackoff * 2)
    }
    stdout: SplitParser {
      onRead: function (line) {
        var n = Model.parseNotification(line)
        if (!n) return
        // The same toast shows up in the popup dir, then again in history.
        if (root.seenBefore(n.id)) return
        root.notifBackoff = 2000
        root.raiseAlert(n.names, n.pids, n.level)
      }
    }
  }

  // ---- Box actions menu -------------------------------------------------------
  property bool menuOpen: false
  property Item menuAnchor: null
  property string menuMode: "main"          // "main" | "workspaces"
  property var menuWin: ({ address: "", tabbed: false, floating: false, pinned: false, fullscreen: false })
  readonly property var menuItems: Model.menuItemsFor(menuWin)

  function openBoxMenu(anchorItem, address, tabbed, floating, pinned, fullscreen) {
    if (!cfg.boxActions || !anchorItem) return
    settingsOpen = false
    menuAnchor = anchorItem
    menuWin = { address: address, tabbed: tabbed === true, floating: floating === true, pinned: pinned === true, fullscreen: fullscreen === true }
    menuMode = "main"
    menuOpen = true
  }

  // One entry point for every action (menu, middle-click, IPC). Everything but focusing and
  // opening the settings needs the Box actions toggle, so a stray call cannot close windows.
  function runAction(id, addr, arg) {
    if (id === "settings") { menuOpen = false; settingsOpen = true; return }
    if (id !== "focus" && !cfg.boxActions) return
    var cmds = Model.actionCommand(id, addr, Hyprland.usingLua === true, arg)
    for (var i = 0; i < cmds.length; i++) Hyprland.dispatch(cmds[i])
    menuOpen = false
    bump()
  }

  // ---- Drag to reorder ----------------------------------------------------------
  property bool dragActive: false
  property int dragFrom: -1
  property int dragTarget: -1

  function columnOfRow(rect) {
    var start = vertical ? rect.by : rect.bx
    var cols = tape.cols
    for (var i = 0; i < cols.length; i++)
      if (Math.abs(cols[i].start - start) < 1) return i
    return Model.slotAt(cols, start + (vertical ? rect.bh : rect.bw) / 2)
  }

  function addressAtColumn(index) {
    var c = tape.cols[index]
    if (!c) return ""
    for (var i = 0; i < tape.items.length; i++) {
      var main = vertical ? tape.items[i].by : tape.items[i].bx
      if (Math.abs(main - c.start) < 1) return tape.items[i].address
    }
    return ""
  }

  function reorderColumns(from, to, addr) {
    if (!cfg.dragReorder) return
    var plan = Model.swapPlan(from, to)
    if (plan.length === 0) return
    var a = addr && addr !== "" ? addr : addressAtColumn(from)
    if (a === "") return
    focusWindow(a)
    var cmds = Model.swapCommands(plan, Hyprland.usingLua === true)
    for (var i = 0; i < cmds.length; i++) Hyprland.dispatch(cmds[i])
    bump()
  }

  // ---- Scripting: omarchy-shell minimap <function> ------------------------------
  // alert/clear/jump are the public API; menu/action/reorder drive the same code paths
  // without a pointer (handy for tests and screenshots).
  IpcHandler {
    target: "minimap"

    function alert(app: string, level: string): void {
      var name = String(app || "").slice(0, 256)
      if (name === "") return
      root.raiseAlert([name], [], level === "critical" ? 2 : 1)
    }
    function clear(): void { root.alerts = ({}); root.alertAt = ({}); root.reconcile() }
    function jump(): void { root.jumpToAlert() }
    // The alert state as JSON: address -> level, per-box cues, the number's level, jump target.
    function alerts(): string {
      return JSON.stringify({ alerts: root.alerts, attention: root.attention, otherLevel: root.otherLevel,
                              numberFlash: root.numberFlash, target: Model.pickAlertTarget(root.alerts, root.alertAt) })
    }
    // The boxes as JSON (row index, window address, layout position, state flags).
    function list(): string {
      var out = []
      for (var i = 0; i < rows.count; i++) {
        var r = rows.get(i)
        out.push({ index: i, address: r.address, bx: r.bx, by: r.by, bw: r.bw, bh: r.bh, floating: r.floating,
                   pinned: r.pinned, fullscreen: r.fullscreen, focused: r.focused, closing: r.closing })
      }
      return JSON.stringify(out)
    }
    function menu(index: int): void {
      if (index < 0 || index >= rows.count) return
      var row = rows.get(index)
      var entry = root.items[row.address]
      root.openBoxMenu(entry ? entry.item : root, row.address, row.tabsJson !== "", row.floating, row.pinned, row.fullscreen)
    }
    function action(id: string, index: int, arg: int): void {
      if (index < 0 || index >= rows.count) return
      root.runAction(String(id), rows.get(index).address, arg)
    }
    function reorder(from: int, to: int): void { root.reorderColumns(from, to, "") }
  }

  // ---- Hover / focus label -------------------------------------------------
  // A liquid pill under the bar naming the hovered window, or the newly
  // focused one for a moment. It glides and stretches between boxes.
  property string hoverAddr: ""
  property string peekAddr: ""
  property bool ready: false
  property var items: ({})
  property int itemsRev: 0

  // A tab nub is a better hover anchor than its box, so it wins (prio 1 vs 0).
  function registerItem(addr, item, prio) {
    var cur = items[addr]
    if (cur && cur.prio > (prio || 0) && cur.item) return
    items[addr] = { item: item, prio: prio || 0 }
    itemsRev++
  }
  function unregisterItem(addr, item) {
    if (items[addr] && items[addr].item === item) { delete items[addr]; itemsRev++ }
  }
  function hoverEntered(addr) { hoverClear.stop(); hoverAddr = addr }
  function hoverLeft(addr) { if (hoverAddr === addr) hoverClear.restart() }

  Timer { interval: 1500; running: true; onTriggered: root.ready = true }
  Timer { id: hoverClear; interval: 140; onTriggered: root.hoverAddr = "" }
  Timer { id: peekTimer; interval: 1800; onTriggered: root.peekAddr = "" }

  function peek(addr) {
    if (!ready || addr === "") return
    peekAddr = addr
    peekTimer.restart()
  }
  onActiveAddrChanged: { peek(activeAddr); reconcile() }

  readonly property string shownAddr: hoverAddr !== "" ? hoverAddr : peekAddr
  readonly property var shownWin: {
    if (shownAddr === "") return null
    for (var i = 0; i < columns.length; i++)
      for (var j = 0; j < columns[i].windows.length; j++)
      {
        var w = columns[i].windows[j]
        if (w.address === shownAddr) return w
        if (w.tabs)
          for (var k = 0; k < w.tabs.length; k++)
            if (w.tabs[k].address === shownAddr) return w.tabs[k]
      }
    return null
  }
  readonly property var shownItem: {
    var _rev = itemsRev
    return shownAddr !== "" && items[shownAddr] ? items[shownAddr].item : null
  }
  // Resolve an application icon from its window class (same lookup scrollmap uses).
  function resolveIcon(cls) {
    var value = String(cls || "")
    if (!value) return ""
    if (bar && bar.shell && bar.shell.appLibrary) return bar.shell.appLibrary.iconSource(value)
    var direct = Quickshell.iconPath(value, true)
    return direct ? direct : Quickshell.iconPath(value.toLowerCase(), true)
  }

  readonly property string labelText: shownWin ? String(shownWin.title || shownWin.appClass || "") : ""

  // The tab keeps showing its last label while it fades out instead of going blank.
  property string heldLabel: ""
  property string heldClass: ""
  onShownWinChanged: {
    if (shownWin && labelText !== "") {
      heldLabel = labelText
      heldClass = String(shownWin.appClass || "")
    }
  }
  readonly property string tabLabel: labelText !== "" ? labelText : heldLabel
  readonly property string tabClass: shownWin ? String(shownWin.appClass || "") : heldClass

  PopupWindow {
    id: tip
    readonly property bool wanted: root.shownWin !== null && root.shownItem !== null
      && root.labelText !== "" && !root.settingsOpen
    readonly property real pad: Style.space(6)
    // Spring feel shared by every motion: stiffness / damping (0..1, lower = bouncier).
    readonly property real springK: 3.2
    readonly property real springD: 0.34
    // Position moves are instant on a fresh appearance, springy afterwards.
    property bool animatePos: false
    readonly property real along: Style.space(760)
    readonly property real maxPillW: Style.space(560)
    readonly property bool left: root.bar && root.bar.position === "left"
    // Same fill as the bar so the tab reads as part of it.
    readonly property color tabColor: root.bar && !root.bar.transparent ? root.bar.background : Color.popups.background
    readonly property bool bottom: root.bar && root.bar.position === "bottom"

    anchor {
      window: root.QsWindow.window
      adjustment: PopupAdjustment.None
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      rect.width: 1
      rect.height: 1
    }
    visible: root.QsWindow.window !== null && (wanted || pill.presence > 0.003)
    color: "transparent"
    implicitWidth: root.vertical ? maxPillW + pad * 2 : along
    implicitHeight: root.vertical ? along : pill.height + pad
    // Only the pill takes input; the rest of the window is click-through.
    mask: Region { item: pill }

    onWantedChanged: {
      if (!wanted) return
      if (pill.presence < 0.05) {
        animatePos = false
        place()
        Qt.callLater(function () { tip.animatePos = true })
      } else {
        place()
      }
    }
    Connections {
      target: root
      function onShownItemChanged() { if (tip.wanted) tip.place() }
      function onColumnsChanged() { if (tip.wanted) Qt.callLater(tip.place) }
    }

    function clamp(v, lo, hi) { return Math.max(lo, Math.min(v, Math.max(lo, hi))) }

    function place() {
      var win = root.QsWindow.window
      var item = root.shownItem
      if (!win || !item) return
      var o = win.contentItem.mapFromItem(root, 0, 0)
      var c = win.contentItem.mapFromItem(item, item.width / 2, item.height / 2)
      var m = Style.space(4)
      if (!root.vertical) {
        var wx = clamp(o.x - Style.space(12), m, win.width - along - m)
        var wy = bottom ? -implicitHeight : win.height
        anchor.rect.x = Math.round(wx)
        anchor.rect.y = Math.round(wy)
        pill.targetX = clamp(c.x - wx - pill.targetW / 2, 0, along - pill.targetW)
        pill.targetY = bottom ? pad : 0
      } else {
        var vx = left ? o.x + root.width + m : o.x - implicitWidth - m
        var vy = clamp(o.y - Style.space(12), m, win.height - along - m)
        anchor.rect.x = Math.round(vx)
        anchor.rect.y = Math.round(vy)
        pill.targetY = clamp(c.y - vy - pill.height / 2, 0, along - pill.height)
        pill.targetX = left ? pad : implicitWidth - pill.targetW - pad
      }
    }

    Item {
      id: pill
      property real targetX: 0
      property real targetY: 0
      // Flare = radius of the concave corners where the tab meets the bar;
      // corner = radius of its free top corners. Vertical bars get a plain pill.
      readonly property real flare: root.vertical ? 0 : Style.space(10)
      readonly property real corner: Math.min(Style.space(13), height / 2)
      readonly property real targetW: Math.min(tip.maxPillW, metrics.width + iconBox.width + flare * 2 + Style.space(40))

      // Natural width: Text.implicitWidth shrinks under elide constraints.
      TextMetrics {
        id: metrics
        text: root.tabLabel
        font.family: root.fontFamily
        font.pixelSize: Math.round(Style.font.body * 1.3)
      }

      // rounded-tab outline (css-tip.com/rounded-tab), flat edge at the bottom.
      readonly property string tabPath: {
        var W = width, H = height, r = flare, R = corner
        if (r <= 0) {
          var h = H / 2
          return "M " + h + " 0 L " + (W - h) + " 0 A " + h + " " + h + " 0 0 1 " + (W - h) + " " + H
            + " L " + h + " " + H + " A " + h + " " + h + " 0 0 1 " + h + " 0 Z"
        }
        return "M 0 " + H
          + " A " + r + " " + r + " 0 0 0 " + r + " " + (H - r)
          + " L " + r + " " + R
          + " A " + R + " " + R + " 0 0 1 " + (r + R) + " 0"
          + " L " + (W - r - R) + " 0"
          + " A " + R + " " + R + " 0 0 1 " + (W - r) + " " + R
          + " L " + (W - r) + " " + (H - r)
          + " A " + r + " " + r + " 0 0 0 " + W + " " + H + " Z"
      }

      x: targetX
      y: targetY + lift
      width: targetW
      height: textItem.implicitHeight + Style.space(18)
      // 0 = hidden, 1 = shown. One spring drives the slide and the fade, so
      // the tab sinks while it fades. It rises out of the bar edge: parked a
      // full height behind it (the popup window clips it there).
      property real presence: tip.wanted ? 1 : 0
      readonly property real lift: root.vertical ? 0 : (1 - presence) * (tip.bottom ? height : -height)
      opacity: Math.max(0, Math.min(1, presence * 2.2))

      Behavior on presence { SpringAnimation { spring: tip.springK; damping: tip.springD; epsilon: 0.002 } }
      Behavior on x { enabled: tip.animatePos; SpringAnimation { spring: tip.springK; damping: tip.springD; epsilon: 0.3 } }
      Behavior on y { enabled: tip.animatePos; SpringAnimation { spring: tip.springK; damping: tip.springD; epsilon: 0.3 } }
      Behavior on width { enabled: tip.animatePos; SpringAnimation { spring: tip.springK; damping: tip.springD; epsilon: 0.3 } }

      // Fills the gap under the tab while the spring overshoots; clipped away
      // by the popup window otherwise.
      Rectangle {
        visible: !root.vertical
        x: pill.flare
        width: parent.width - pill.flare * 2
        height: Style.space(12)
        y: tip.bottom ? parent.height - 1 : -height + 1
        color: tip.tabColor
      }

      Shape {
        id: shape
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        transform: Scale { yScale: (root.vertical || tip.bottom) ? 1 : -1; origin.y: shape.height / 2 }

        ShapePath {
          fillColor: tip.tabColor
          strokeColor: "transparent"
          PathSvg { path: pill.tabPath }
        }
      }

      Item {
        id: iconBox
        anchors.left: parent.left
        anchors.leftMargin: pill.flare + Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        width: Math.round(textItem.implicitHeight * 1.2)
        height: width

        Image {
          id: iconImg
          anchors.fill: parent
          source: root.resolveIcon(root.tabClass)
          sourceSize.width: Math.round(width * Screen.devicePixelRatio)
          sourceSize.height: Math.round(height * Screen.devicePixelRatio)
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
          mipmap: true
          visible: status === Image.Ready
        }
        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: iconImg.status !== Image.Ready
          text: root.tabClass !== "" ? root.tabClass.charAt(0).toUpperCase() : "•"
          color: root.shownAddr === root.activeAddr ? root.accentColor : root.mutedColor
          font.family: root.fontFamily
          font.pixelSize: Math.round(Style.font.body * 1.3)
          font.bold: true
        }
      }

      Text {

        textFormat: Text.PlainText
        id: textItem
        anchors.left: iconBox.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.rightMargin: pill.flare + Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        text: root.tabLabel
        elide: Text.ElideRight
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Math.round(Style.font.body * 1.3)
      }
    }
  }

  // ---- Box menu popup ---------------------------------------------------------------
  QtObject {
    id: menuOwner
    function close() { root.menuOpen = false }
  }

  PopupCard {
    id: menuPopup
    anchorItem: root.menuAnchor ? root.menuAnchor : root
    bar: root.bar
    owner: menuOwner
    open: root.menuOpen
    contentWidth: fittedContentWidth(Style.space(190))
    contentHeight: fittedContentHeight(menuColumn.implicitHeight)

    Column {
      id: menuColumn
      anchors.fill: parent
      spacing: Style.space(2)

      Repeater {
        model: root.menuMode === "main" ? root.menuItems : []

        MenuRow {
          required property var modelData
          width: menuColumn.width
          label: modelData.label
          enabledRow: modelData.enabled
          danger: modelData.danger === true
          submenu: modelData.submenu === true
          onPicked: {
            if (modelData.id === "moveto") root.menuMode = "workspaces"
            else root.runAction(modelData.id, root.menuWin.address)
          }
        }
      }

      MenuRow {
        visible: root.menuMode === "workspaces"
        width: menuColumn.width
        label: "Back"
        back: true
        onPicked: root.menuMode = "main"
      }

      Flow {
        visible: root.menuMode === "workspaces"
        width: menuColumn.width
        spacing: Style.space(3)

        Repeater {
          model: root.menuMode === "workspaces" ? 10 : 0

          MenuRow {
            required property int index
            width: Math.floor((menuColumn.width - Style.space(3) * 4) / 5)
            label: String(index + 1)
            centered: true
            onPicked: root.runAction("moveto", root.menuWin.address, index + 1)
          }
        }
      }
    }
  }

  // ---- Settings popup ------------------------------------------------------
  PopupCard {
    id: settingsPopup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.settingsOpen
    contentWidth: fittedContentWidth(Style.space(260))
    contentHeight: fittedContentHeight(settingsColumn.implicitHeight)

    Column {
      id: settingsColumn
      anchors.fill: parent
      spacing: Style.space(6)

      Text {

        textFormat: Text.PlainText
        text: "MINIMAP"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Repeater {
        model: Model.NUMBER_STYLE_ORDER.map(function (id) {
          return { value: id, label: Model.NUMBER_STYLES[id].label, description: Model.NUMBER_STYLES[id].description }
        })

        Item {
          id: row
          required property var modelData
          readonly property bool checked: root.cfg.numberStyle === modelData.value
          width: parent.width
          implicitHeight: Math.max(dot.height, texts.implicitHeight) + Style.space(6)

          Rectangle {
            id: dot
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.topMargin: Style.space(3)
            width: Style.space(14)
            height: width
            radius: width / 2
            color: row.checked ? Color.accent : "transparent"
            border.width: 2
            border.color: row.checked ? Color.accent : Qt.darker(root.fg, 1.3)
            Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.InOutSine } }
            Behavior on border.color { ColorAnimation { duration: 200; easing.type: Easing.InOutSine } }
          }
          Column {
            id: texts
            anchors.left: dot.right
            anchors.leftMargin: Style.space(8)
            anchors.right: parent.right
            Text {
              textFormat: Text.PlainText
              text: row.modelData.label
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: row.checked
            }
            Text {
              textFormat: Text.PlainText
              text: row.modelData.description
              color: Qt.darker(root.fg, 1.35)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.saveSetting("numberStyle", row.modelData.value)
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: root.mutedColor
        opacity: 0.4
      }

      Text {

        textFormat: Text.PlainText
        text: "Tabbed windows"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Repeater {
        model: Model.GROUP_STYLE_ORDER.map(function (id) {
          return { value: id, label: Model.GROUP_STYLES[id].label, description: Model.GROUP_STYLES[id].description }
        })

        Item {
          id: grow
          required property var modelData
          readonly property bool checked: root.cfg.groupStyle === modelData.value
          width: parent.width
          implicitHeight: Math.max(gdot.height, gtexts.implicitHeight) + Style.space(6)

          Rectangle {
            id: gdot
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.topMargin: Style.space(3)
            width: Style.space(14)
            height: width
            radius: width / 2
            color: grow.checked ? Color.accent : "transparent"
            border.width: 2
            border.color: grow.checked ? Color.accent : Qt.darker(root.fg, 1.3)
            Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.InOutSine } }
            Behavior on border.color { ColorAnimation { duration: 200; easing.type: Easing.InOutSine } }
          }
          Column {
            id: gtexts
            anchors.left: gdot.right
            anchors.leftMargin: Style.space(8)
            anchors.right: parent.right
            Text {
              textFormat: Text.PlainText
              text: grow.modelData.label
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: grow.checked
            }
            Text {
              textFormat: Text.PlainText
              text: grow.modelData.description
              color: Qt.darker(root.fg, 1.35)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.saveSetting("groupStyle", grow.modelData.value)
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: root.mutedColor
        opacity: 0.4
      }

      Text {

        textFormat: Text.PlainText
        text: "Animation"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Repeater {
        model: Model.ANIM_STYLE_ORDER.map(function (id) {
          return { value: id, label: Model.ANIM_STYLES[id].label, description: Model.ANIM_STYLES[id].description }
        })

        OptionRow {
          required property var modelData
          width: parent.width
          label: modelData.label
          description: modelData.description
          checked: root.cfg.animStyle === modelData.value
          onPicked: root.saveSetting("animStyle", modelData.value)
        }
      }

      OptionRow {
        width: parent.width
        square: true
        label: "Attention cues"
        description: "Urgent windows and notifications: minor and critical"
        checked: root.cfg.attention
        onPicked: root.saveSetting("attention", !root.cfg.attention)
      }

      OptionRow {
        width: parent.width
        square: true
        label: "State markers"
        description: "Marks for fullscreen, pinned and floating windows"
        checked: root.cfg.stateMarkers
        onPicked: root.saveSetting("stateMarkers", !root.cfg.stateMarkers)
      }

      OptionRow {
        width: parent.width
        square: true
        label: "Box actions"
        description: "Right-click a box for a window menu, middle-click closes it"
        checked: root.cfg.boxActions
        onPicked: root.saveSetting("boxActions", !root.cfg.boxActions)
      }

      OptionRow {
        width: parent.width
        square: true
        label: "Drag to reorder"
        description: "Hold the right mouse button on a box and drag sideways"
        checked: root.cfg.dragReorder
        onPicked: root.saveSetting("dragReorder", !root.cfg.dragReorder)
      }

      Rectangle {
        width: parent.width
        height: 1
        color: root.mutedColor
        opacity: 0.4
      }

      Item {
        id: floatRow
        width: parent.width
        implicitHeight: Math.max(box.height, floatText.implicitHeight) + Style.space(6)

        Rectangle {
          id: box
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.topMargin: Style.space(0)
          width: Style.space(14)
          height: width
          radius: 3
          color: root.cfg.showFloating ? Color.accent : "transparent"
          border.width: 2
          border.color: root.cfg.showFloating ? Color.accent : Qt.darker(root.fg, 1.3)
          Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.InOutSine } }
          Behavior on border.color { ColorAnimation { duration: 200; easing.type: Easing.InOutSine } }
        }
        Column {
          id: floatText
          anchors.left: box.right
          anchors.leftMargin: Style.space(8)
          anchors.right: parent.right
          Text {
            textFormat: Text.PlainText
            text: "Show floating windows"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: root.cfg.showFloating
          }
          Text {
            textFormat: Text.PlainText
            text: "Include floating windows in the tape"
            color: Qt.darker(root.fg, 1.35)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.saveSetting("showFloating", !root.cfg.showFloating)
        }
      }
    }
  }

  // One row of the box menu.
  component MenuRow: Rectangle {
    id: mrow
    property string label: ""
    property bool enabledRow: true
    property bool danger: false
    property bool submenu: false
    property bool back: false
    property bool centered: false
    signal picked()

    implicitHeight: Style.space(24)
    radius: Style.space(5)
    color: area.containsMouse && enabledRow ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14) : "transparent"
    opacity: enabledRow ? 1 : 0.4
    Behavior on color { ColorAnimation { duration: 120 } }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      horizontalAlignment: mrow.centered ? Text.AlignHCenter : Text.AlignLeft
      text: (mrow.back ? "\u2039 " : "") + mrow.label + (mrow.submenu ? "  \u203a" : "")
      color: mrow.danger ? root.urgentColor : root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    MouseArea {
      id: area
      anchors.fill: parent
      hoverEnabled: true
      enabled: mrow.enabledRow
      cursorShape: Qt.PointingHandCursor
      onClicked: mrow.picked()
    }
  }

  // A selectable settings row: radio dot (or checkbox when `square`).
  component OptionRow: Item {
    id: opt
    property string label: ""
    property string description: ""
    property bool checked: false
    property bool square: false
    signal picked()

    implicitHeight: Math.max(mark.height, optTexts.implicitHeight) + Style.space(6)

    Rectangle {
      id: mark
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.topMargin: Style.space(3)
      width: Style.space(14)
      height: width
      radius: opt.square ? 3 : width / 2
      color: opt.checked ? Color.accent : "transparent"
      border.width: 2
      border.color: opt.checked ? Color.accent : Qt.darker(root.fg, 1.3)
      Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.InOutSine } }
      Behavior on border.color { ColorAnimation { duration: 200; easing.type: Easing.InOutSine } }
    }
    Column {
      id: optTexts
      anchors.left: mark.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      Text {
        textFormat: Text.PlainText
        text: opt.label
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: opt.checked
      }
      Text {
        textFormat: Text.PlainText
        text: opt.description
        color: Qt.darker(root.fg, 1.35)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: opt.picked()
    }
  }
}
