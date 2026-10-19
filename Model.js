// Pure helpers for the Minimap bar widget. ES5-only so `node tests/model.test.js` runs it.
// Geometry/theme helpers are shared with jgarza.scrollmap.

function normalizeAddress(value) {
  var raw = String(value || "").trim().toLowerCase()
  if (raw.indexOf("0x") === 0) raw = raw.slice(2)
  return /^[0-9a-f]+$/.test(raw) && raw.length > 0 ? "0x" + raw : ""
}

function ipcOf(toplevel) {
  var ipc = toplevel && toplevel.lastIpcObject
  return ipc && typeof ipc === "object" ? ipc : {}
}

function workspaceIdOf(ipc) {
  var ws = ipc && ipc.workspace
  if (!ws) return NaN
  var id = Number(ws.id)
  return isFinite(id) ? id : NaN
}

// Reduce the full toplevel list to the tiled, mapped windows that live on the
// given workspace, each described by the geometry the mini-map needs. Floating
// windows are excluded unless `includeFloating` is set: the scrolling layout
// only tiles, and a floating overlay can distort the proportional strip.
// Addresses of the other members of a Hyprland group (tabbed windows), self
// included, normalized. [] for an ungrouped window.
function groupedOf(ipc) {
  var g = ipc && ipc.grouped
  if (!g || !g.length) return []
  var out = []
  for (var i = 0; i < g.length; i++) {
    var a = normalizeAddress(g[i])
    if (a) out.push(a)
  }
  return out
}

// `live` (optional) is { normalizedAddress: true } from `hyprctl clients`; toplevels
// it doesn't list are stale leftovers of closed windows and are skipped.
function eligibleClients(toplevels, workspaceId, includeFloating, live) {
  var list = toplevels || []
  var target = Number(workspaceId)
  var withFloating = includeFloating === true
  var out = []

  for (var i = 0; i < list.length; i++) {
    var top = list[i]
    if (!top) continue
    var ipc = ipcOf(top)

    if (live && !live[normalizeAddress(top.address || ipc.address)]) continue
    if (ipc.mapped === false) continue
    if (ipc.floating === true && !withFloating) continue
    if (ipc.hidden === true) continue
    if (isFinite(target) && workspaceIdOf(ipc) !== target) continue

    var at = ipc.at || []
    var size = ipc.size || []
    var x = Number(at[0])
    var y = Number(at[1])
    var w = Number(size[0])
    var h = Number(size[1])
    if (!isFinite(x) || !isFinite(y) || !(w > 0) || !(h > 0)) continue

    out.push({
      address: normalizeAddress(top.address || ipc.address),
      appClass: String(ipc.class || ipc.initialClass || ""),
      title: String(top.title || ipc.title || ipc.class || ""),
      floating: ipc.floating === true,
      grouped: groupedOf(ipc),
      pid: Number(ipc.pid) > 0 ? Number(ipc.pid) : 0,
      pinned: ipc.pinned === true,
      fullscreen: Number(ipc.fullscreen) > 0,
      focusHistory: Number.isFinite(Number(ipc.focusHistoryID)) ? Number(ipc.focusHistoryID) : 1e9,
      x: x,
      y: y,
      w: w,
      h: h
    })
  }

  return out
}

// Left-to-right for a horizontal bar, top-to-bottom for a vertical one. The
// off-axis coordinate is the tiebreaker so stacked splits keep a stable order.
function orderByPosition(clients, vertical) {
  var copy = (clients || []).slice()
  copy.sort(function (a, b) {
    var primary = vertical ? a.y - b.y : a.x - b.x
    if (primary !== 0) return primary
    var secondary = vertical ? a.x - b.x : a.y - b.y
    if (secondary !== 0) return secondary
    return String(a.address).localeCompare(String(b.address))
  })
  return copy
}

// How much of [start, end] falls inside [lo, hi], as a fraction of (end - start).
function overlapFraction(start, end, lo, hi) {
  var span = end - start
  if (!(span > 0)) return 0
  var a = Math.max(start, Math.min(lo, hi))
  var b = Math.min(end, Math.max(lo, hi))
  return b > a ? (b - a) / span : 0
}

// ---- Window size -----------------------------------------------------------
// Window size is shown as bracket padding, not pixel width, and it is
// continuous: every pixel of resize nudges the brackets. sizeFraction gives
// 0..1: a tiled window's extent along the bar's axis over the monitor's; a
// floating window's area over the monitor's, square-rooted so it grows at the
// same rate as a side length (a quarter-screen float reads as half size).
function sizeFraction(client, monitor, vertical) {
  if (!client || !monitor) return 0
  var mw = Number(monitor.width)
  var mh = Number(monitor.height)
  if (!(mw > 0) || !(mh > 0)) return 0
  var f = client.floating === true
    ? Math.sqrt(Math.max(0, (client.w * client.h) / (mw * mh)))
    : (vertical ? client.h / mh : client.w / mw)
  if (!isFinite(f)) return 0
  // Rounded so sub-pixel geometry jitter doesn't churn the row model.
  return Math.round(Math.max(0, Math.min(1, f)) * 1000) / 1000
}

// Shape the 0..1 size into padding: size^exponent. Above 1 the curve is
// convex, so big windows get disproportionately more room and are easy to
// tell apart from half-size ones, while small windows stay compact. 1 is
function clampInt(value, lo, hi, fallback) {
  var n = Number(value)
  if (value === null || value === undefined || value === "" || !isFinite(n)) return fallback
  return Math.max(lo, Math.min(hi, Math.round(n)))
}

function boolOr(value, fallback) {
  return value === true || value === false ? value : fallback
}
// ---- Theme colours -------------------------------------------------------
// The state colours come straight from the active theme's colors.toml, so a
// theme switch recolours the strip live. Same tolerant line regex as
// Color.qml's own loader; returns only the keys found.
// `background`/`foreground` feed ensureContrast below.
var THEME_COLOR_KEYS = ["accent", "muted", "background", "foreground"]

function parseThemeColors(raw, keys) {
  var wanted = {}
  var list = keys || THEME_COLOR_KEYS
  for (var i = 0; i < list.length; i++) wanted[list[i]] = true
  var out = {}
  var lines = String(raw || "").split("\n")
  for (var j = 0; j < lines.length; j++) {
    var m = lines[j].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (!m) continue
    if (wanted[m[1]] && out[m[1]] === undefined) out[m[1]] = m[2]
  }
  return out
}

// Picks the more readable of two text colours on a (possibly translucent)
// fill composited over `under`. Colours are { r, g, b, a } in 0..1 - a QML
// color already has these. Returns "primary" or "alt".
function relativeLuminance(c) {
  function lin(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}
function contrastRatio(a, b) {
  var la = relativeLuminance(a), lb = relativeLuminance(b)
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}
function readableOn(fill, under, primary, alt) {
  var a = fill.a === undefined ? 1 : fill.a
  var composite = {
    r: fill.r * a + under.r * (1 - a),
    g: fill.g * a + under.g * (1 - a),
    b: fill.b * a + under.b * (1 - a)
  }
  return contrastRatio(primary, composite) >= contrastRatio(alt, composite) ? "primary" : "alt"
}

function hexToRgb(hex) {
  var m = /^#?([0-9a-f]{6})$/i.exec(String(hex || "").trim())
  if (!m) return null
  var n = parseInt(m[1], 16)
  return { r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255 }
}

function rgbToHex(c) {
  function h(v) {
    var s = Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16)
    return s.length === 1 ? "0" + s : s
  }
  return "#" + h(c.r) + h(c.g) + h(c.b)
}

// Some themes' `muted` is nearly invisible as a text colour on the bar. Mix
// `hex` toward `towardHex`
// (the foreground) in 5% steps until it reaches `minRatio` contrast against
// `bgHex`. Returns `hex` unchanged when it already reads, or when any input
// fails to parse.
function ensureContrast(hex, bgHex, towardHex, minRatio) {
  var c = hexToRgb(hex), bg = hexToRgb(bgHex), to = hexToRgb(towardHex)
  if (!c || !bg || !to) return hex
  var want = Number(minRatio) || 3
  for (var t = 0; t <= 1.0001; t += 0.05) {
    var mixed = {
      r: c.r + (to.r - c.r) * t,
      g: c.g + (to.g - c.g) * t,
      b: c.b + (to.b - c.b) * t
    }
    if (contrastRatio(mixed, bg) >= want) return t === 0 ? hex : rgbToHex(mixed)
  }
  return towardHex
}


// ---- Workspace labels ----------------------------------------------------
var NUMBER_STYLE_ORDER = ["numbers", "roman", "japanese", "dots"]
var NUMBER_STYLES = {
  numbers: { label: "Numbers", description: "1 2 3 4 5" },
  roman: { label: "Roman", description: "I II III IV V" },
  japanese: { label: "Japanese", description: "一 二 三 四 五" },
  dots: { label: "Dots", description: ". : .: :: .::" }
}
var DEFAULT_NUMBER_STYLE = "numbers"

function resolveNumberStyle(id) {
  return Object.prototype.hasOwnProperty.call(NUMBER_STYLES, id) ? id : DEFAULT_NUMBER_STYLE
}

function toRoman(n) {
  var table = [[10, "X"], [9, "IX"], [5, "V"], [4, "IV"], [1, "I"]]
  var out = ""
  for (var i = 0; i < table.length; i++) {
    while (n >= table[i][0]) { out += table[i][1]; n -= table[i][0] }
  }
  return out
}

var KANJI = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
function toJapanese(n) {
  if (n <= 10) return KANJI[n]
  if (n < 20) return "十" + KANJI[n - 10]
  var tens = Math.floor(n / 10), ones = n % 10
  return KANJI[tens] + "十" + KANJI[ones]
}

// Dots: ':' is a pair, '.' is the odd one, no spaces: 1 '.', 2 ':', 3 '.:',
// 4 '::', 5 '.::', 9 '.::::', 10 ':::::', 11 '.:::::'.
function toDots(n) {
  return (n % 2 === 1 ? "." : "") + new Array(Math.floor(n / 2) + 1).join(":")
}

function formatWorkspace(n, style) {
  var id = Math.round(Number(n))
  if (!isFinite(id) || id < 1) return String(n)
  switch (resolveNumberStyle(style)) {
    case "roman": return toRoman(id)
    case "japanese": return toJapanese(id)
    case "dots": return toDots(id)
    default: return String(id)
  }
}

// ---- Columns -------------------------------------------------------------
// Windows that share a scrolling-layout column (same x/width) are stacked in
// one slot. Input: eligibleClients() output. Output, left-to-right:
// [{ x, w, windows: [client sorted top-to-bottom] }]. On a vertical bar the
// roles of x/y swap so "columns" become rows.
// Windows of one Hyprland group share a position and size. Fold each group
// into a single client that carries `tabs` (in group order); the visible tab
// is the focused one if it is in the group, else the most recently focused.
// Everything else passes through with `tabs: null`.
function collapseGroups(clients, activeAddr) {
  var active = normalizeAddress(activeAddr)
  var list = clients || []
  var byAddr = {}
  for (var i = 0; i < list.length; i++) byAddr[list[i].address] = list[i]
  var seen = {}
  var out = []
  for (var j = 0; j < list.length; j++) {
    var c = list[j]
    if (seen[c.address]) continue
    var members = []
    if (c.grouped && c.grouped.length > 1) {
      for (var k = 0; k < c.grouped.length; k++) {
        var m = byAddr[c.grouped[k]]
        if (m) members.push(m)
      }
    }
    if (members.length < 2) {
      seen[c.address] = true
      out.push(copyClient(c, null))
      continue
    }
    var head = members[0]
    for (var h = 0; h < members.length; h++) {
      seen[members[h].address] = true
      if (members[h].address === active) head = members[h]
    }
    if (!members.some(function (m) { return m.address === active })) {
      for (var n = 0; n < members.length; n++)
        if (members[n].focusHistory < head.focusHistory) head = members[n]
    }
    var tabs = members.map(function (m) {
      return { address: m.address, title: m.title, appClass: m.appClass, active: m.address === head.address }
    })
    out.push(copyClient(head, tabs))
  }
  return out
}

function copyClient(c, tabs) {
  return {
    address: c.address, appClass: c.appClass, title: c.title, floating: c.floating,
    pinned: c.pinned === true, fullscreen: c.fullscreen === true,
    x: c.x, y: c.y, w: c.w, h: c.h, tabs: tabs
  }
}

function groupColumns(clients, vertical) {
  var list = orderByPosition(clients, vertical)
  var cols = []
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    var start = vertical ? c.y : c.x
    var len = vertical ? c.h : c.w
    var last = cols.length ? cols[cols.length - 1] : null
    if (last && Math.abs(last.start - start) <= 2 && Math.abs(last.len - len) <= 4) {
      last.windows.push(c)
    } else {
      cols.push({ start: start, len: len, windows: [c] })
    }
  }
  return cols
}

// Everything a column needs to be drawn at true aspect ratio. `monitor` is
// { width, height, x, y } in logical px. Per column: `len` (px along the bar's
// axis); per window: `off` and `span` (px along the cross axis, relative to
// the monitor's edge) - the caller multiplies all of them by one scale.
function buildColumns(clients, monitor, viewport, vertical, activeAddr) {
  var view = viewport && viewport.end > viewport.start ? viewport : null
  var active = normalizeAddress(activeAddr)
  var crossOrigin = monitor ? Number(vertical ? monitor.x : monitor.y) || 0 : 0
  return groupColumns(collapseGroups(clients, active), vertical).map(function (col) {
    var visible = view ? overlapFraction(col.start, col.start + col.len, view.start, view.end) : 1
    return {
      key: col.windows.map(function (w) { return w.address }).join(","),
      len: col.len,
      visibleFraction: visible,
      windows: col.windows.map(function (w) {
        return {
          key: w.tabs ? w.tabs.map(function (t) { return t.address }).sort()[0] : w.address,
          address: w.address,
          title: w.title,
          appClass: w.appClass,
          tabs: w.tabs,
          floating: w.floating === true,
          pinned: w.pinned === true,
          fullscreen: w.fullscreen === true,
          off: (vertical ? w.x : w.y) - crossOrigin,
          span: vertical ? w.w : w.h,
          focused: active !== "" && (w.address === active
            || (w.tabs ? w.tabs.some(function (t) { return t.address === active }) : false))
        }
      })
    }
  })
}

// Flat, absolutely-positioned rectangles for the tape, in bar pixels. Rows are
// keyed by `key` (stable across a group's active-tab changes) so the view can
// reconcile them and animate each one. Interior edges of stacked windows are
// pulled in by half of `stackGap`; outer edges stay put.
function layoutTape(columns, o) {
  var scale = Number(o.scale) || 0
  var gap = Number(o.gap) || 0
  var stackGap = Number(o.stackGap) || 0
  var vertical = o.vertical === true
  var items = []
  var bounds = []
  var cursor = 0
  for (var i = 0; i < (columns || []).length; i++) {
    var col = columns[i]
    var len = col.len * scale
    var n = col.windows.length
    for (var j = 0; j < n; j++) {
      var w = col.windows[j]
      var inStart = n > 1 && j > 0 ? stackGap / 2 : 0
      var inEnd = n > 1 && j < n - 1 ? stackGap / 2 : 0
      var cross = Math.max(1, w.span * scale - inStart - inEnd)
      var cs = w.off * scale + inStart
      var tabs = w.tabs && w.tabs.length > 1 ? w.tabs : null
      items.push({
        key: w.key,
        address: w.address,
        bx: vertical ? cs : cursor,
        by: vertical ? cursor : cs,
        bw: vertical ? cross : len,
        bh: vertical ? len : cross,
        focused: w.focused === true,
        onScreen: col.visibleFraction > 0.02,
        floating: w.floating === true,
        pinned: w.pinned === true,
        fullscreen: w.fullscreen === true,
        tabsJson: tabs ? JSON.stringify(tabs) : ""
      })
    }
    bounds.push({ start: cursor, len: len })
    cursor += len + gap
  }
  return { items: items, total: Math.max(0, cursor - (items.length ? gap : 0)), cols: bounds }
}

// ---- Animation styles -----------------------------------------------------
var ANIM_STYLE_ORDER = ["smooth", "cyberpunk", "fun", "magic", "ripple"]
var ANIM_STYLES = {
  smooth: { label: "Smooth", description: "Calm springs and soft fades (default)" },
  cyberpunk: { label: "Cyberpunk", description: "Glitches, RGB split and hard flickers" },
  fun: { label: "Fun", description: "Big bouncy pops, wobble and shockwaves" },
  magic: { label: "Magic", description: "Sparkles and shimmering light" },
  ripple: { label: "Ripple", description: "Android-style ink ripples" }
}
function resolveAnimStyle(id) {
  return Object.prototype.hasOwnProperty.call(ANIM_STYLES, id) ? id : "smooth"
}

// Numbers the QML reads so it never branches on a style name for timing.
// k/d = spring stiffness/damping; pop* = swell on focus gain; hover = hover
// scale; swapOut/swapIn = workspace number swap (ms); wobble = degrees.
var MOTION = {
  smooth:    { k: 3.0, d: 0.40, popTo: 1.18, popOvershoot: 1.4, popIn: 120, popOut: 520, hover: 1.08, swapOut: 110, swapIn: 240, wobble: 0 },
  cyberpunk: { k: 5.5, d: 0.80, popTo: 1.00, popOvershoot: 0.0, popIn: 60,  popOut: 140, hover: 1.04, swapOut: 70,  swapIn: 90,  wobble: 0 },
  fun:       { k: 2.4, d: 0.18, popTo: 1.38, popOvershoot: 2.8, popIn: 110, popOut: 640, hover: 1.14, swapOut: 120, swapIn: 420, wobble: 10 },
  magic:     { k: 2.6, d: 0.32, popTo: 1.22, popOvershoot: 1.8, popIn: 180, popOut: 620, hover: 1.10, swapOut: 150, swapIn: 360, wobble: 0 },
  ripple:    { k: 3.2, d: 0.50, popTo: 1.06, popOvershoot: 1.0, popIn: 100, popOut: 360, hover: 1.05, swapOut: 100, swapIn: 220, wobble: 0 }
}
function motionFor(style) { return MOTION[resolveAnimStyle(style)] }

// ---- Attention -------------------------------------------------------------
// Hyprland's `urgent` event carries the window address (no 0x).
function urgentAddress(data) { return normalizeAddress(String(data || "").split(",")[0]) }

function nameTokens(value) {
  var v = String(value || "").trim().toLowerCase().replace(/\.desktop$/, "")
  if (!v) return []
  var out = [v]
  var last = v.split(".").pop()
  if (last && last !== v) out.push(last)
  return out
}

// Which window does a notification belong to? `names` are the notification's
// app name / icon name; they are compared with each window's class: exact
// token match first, then a contains match for names of 4+ characters.
// Lower = more likely the sender. The focused window (history 0) can't be the one asking for
// attention, so any other window of the same app ranks ahead of it.
function focusRank(c) {
  if (c.focusHistory === undefined) return 1e9
  return c.focusHistory === 0 ? 1e8 : c.focusHistory
}
function mostRecent(list) {
  var best = list[0]
  for (var i = 1; i < list.length; i++) if (focusRank(list[i]) < focusRank(best)) best = list[i]
  return best
}

function matchNotificationWindow(names, clients, pids) {
  // The sender's process is stronger evidence than its name: a window owned by
  // the sender, or by the nearest ancestor that owns any window (the terminal
  // a script runs in), is the answer; several such windows -> most recent.
  for (var p = 0; p < (pids || []).length; p++) {
    var owned = (clients || []).filter(function (c) { return c.pid > 0 && c.pid === Number(pids[p]) })
    if (owned.length) return mostRecent(owned).address
  }
  var wanted = []
  for (var i = 0; i < (names || []).length; i++) wanted = wanted.concat(nameTokens(names[i]))
  if (!wanted.length) return ""
  var exact = null
  var loose = null
  // An app name can't say WHICH of several windows of that app sent it. The
  // best guess is the one used most recently (lowest focusHistory), which is
  // normally the terminal / chat the user just left.
  function better(c, cur) { return !cur || focusRank(c) < focusRank(cur) }
  for (var j = 0; j < (clients || []).length; j++) {
    var tokens = nameTokens(clients[j].appClass)
    var isExact = false, isLoose = false
    for (var a = 0; a < wanted.length; a++)
      for (var b = 0; b < tokens.length; b++) {
        if (wanted[a] === tokens[b]) isExact = true
        else if (wanted[a].length >= 4 && tokens[b].length >= 4
            && (wanted[a].indexOf(tokens[b]) !== -1 || tokens[b].indexOf(wanted[a]) !== -1)) isLoose = true
      }
    if (isExact && better(clients[j], exact)) exact = clients[j]
    else if (isLoose && better(clients[j], loose)) loose = clients[j]
  }
  return exact ? exact.address : (loose ? loose.address : "")
}

// Notification urgency (0 low, 1 normal, 2 critical) -> attention level:
// 1 = minor, 2 = critical. Window `urgent` events are minor.
function attentionLevel(urgency) { return Number(urgency) >= 2 ? 2 : 1 }

// Row key of the box that holds `addr` (directly or as a tab), "" if none.
function rowKeyFor(columns, addr) {
  for (var i = 0; i < (columns || []).length; i++)
    for (var j = 0; j < columns[i].windows.length; j++) {
      var w = columns[i].windows[j]
      if (w.address === addr) return w.key
      if (w.tabs)
        for (var k = 0; k < w.tabs.length; k++)
          if (w.tabs[k].address === addr) return w.key
    }
  return ""
}

// Turn the alert table (address -> level) into what the view draws.
//   existing  set of addresses that still have a window ({addr: true})
//   columns   this workspace's buildColumns() output
// Alerts for closed windows, and for the focused window (or any tab of its
// group), are dropped. Alerts for windows in `columns` become per-box cues
// (`attention`, row key -> level); the rest raise `otherLevel` for the number.
function reconcileAlerts(alerts, existing, activeAddr, columns) {
  var active = normalizeAddress(activeAddr)
  var focusedKey = active !== "" ? rowKeyFor(columns, active) : ""
  var keep = {}, attention = {}, other = 0, changed = false
  for (var addr in (alerts || {})) {
    var level = alerts[addr]
    var focused = addr === active || (focusedKey !== "" && rowKeyFor(columns, addr) === focusedKey)
    if (!existing[addr] || focused) { changed = true; continue }
    keep[addr] = level
    var key = rowKeyFor(columns, addr)
    if (key !== "") attention[key] = Math.max(attention[key] || 0, level)
    else other = Math.max(other, level)
  }
  return { alerts: keep, attention: attention, otherLevel: other, changed: changed }
}

// One JSON line from the notification service -> { id, level, names } or null.
function parseNotification(line) {
  var n = null
  try { n = JSON.parse(line) } catch (e) { return null }
  if (!n || typeof n !== "object") return null
  var pids = []
  if (Number(n.pid) > 0) pids.push(Number(n.pid))
  for (var i = 0; i < (n.ancestors || []).length; i++)
    if (Number(n.ancestors[i]) > 1) pids.push(Number(n.ancestors[i]))
  return {
    id: String(n.timestamp) + "-" + String(n.id),
    level: attentionLevel(n.urgency),
    names: [n.app, n.appIcon].concat(n.extraNames || []),
    pids: pids
  }
}

// ---- Box actions -----------------------------------------------------------
// Rows of the right-click box menu. `win` = { tabbed, floating, pinned, fullscreen }.
// Pin only works on floating windows (Hyprland: "does not qualify to be pinned").
function menuItemsFor(win) {
  var w = win || {}
  var items = [
    { id: "focus", label: "Focus", enabled: true },
    { id: "float", label: w.floating ? "Make tiled" : "Make floating", enabled: true },
    { id: "fullscreen", label: w.fullscreen ? "Exit fullscreen" : "Fullscreen", enabled: true },
    { id: "pin", label: w.pinned ? "Unpin" : "Pin", enabled: w.floating === true || w.pinned === true }
  ]
  if (w.tabbed) items.push({ id: "ungroup", label: "Ungroup tabs", enabled: true })
  items.push({ id: "moveto", label: "Move to workspace", enabled: true, submenu: true })
  items.push({ id: "close", label: "Close window", enabled: true, danger: true })
  items.push({ id: "settings", label: "Settings...", enabled: true })
  return items
}

// Hyprland dispatch strings for a menu action, in order. [] for anything invalid:
// the address must be a hex address and a workspace a whole number 1..10.
function actionCommand(id, addr, usingLua, arg) {
  var a = normalizeAddress(addr)
  if (!a) return []
  var lua = usingLua === true
  var focus = lua ? 'hl.dsp.focus({ window = "address:' + a + '" })' : "focuswindow address:" + a
  switch (id) {
    case "focus": return [focus]
    case "close":
      return [lua ? 'hl.dsp.window.close({ window = "address:' + a + '" })' : "closewindow address:" + a]
    case "float":
      return [lua ? 'hl.dsp.window.float({ action = "toggle", window = "address:' + a + '" })' : "togglefloating address:" + a]
    case "fullscreen": return [focus, lua ? "hl.dsp.window.fullscreen()" : "fullscreen 0"]
    case "pin": return [focus, lua ? "hl.dsp.window.pin()" : "pin"]
    case "ungroup": return [focus, lua ? "hl.dsp.group.toggle()" : "togglegroup"]
    case "moveto":
      var ws = Number(arg)
      if (!(ws >= 1 && ws <= 10) || Math.round(ws) !== ws) return []
      return [focus, lua ? 'hl.dsp.window.move({ workspace = "' + ws + '" })' : "movetoworkspace " + ws]
  }
  return []
}

// ---- Jump to alert -----------------------------------------------------------
// `alerts` = address -> level, `at` = address -> ms timestamp. Critical beats minor,
// then the most recent wins. "" when there is nothing to jump to.
function pickAlertTarget(alerts, at) {
  var best = "", bestLevel = 0, bestAt = -1
  for (var addr in (alerts || {})) {
    var level = Number(alerts[addr]) || 0
    var t = Number((at || {})[addr]) || 0
    if (level > bestLevel || (level === bestLevel && t > bestAt)) { best = addr; bestLevel = level; bestAt = t }
  }
  return best
}

// Dispatch strings for a swapPlan: ["r","r"] -> two `swapcol r`.
function swapCommands(plan, usingLua) {
  var out = []
  for (var i = 0; i < (plan || []).length; i++) {
    var d = plan[i] === "l" ? "l" : (plan[i] === "r" ? "r" : "")
    if (!d) return []
    out.push(usingLua === true ? 'hl.dsp.layout("swapcol ' + d + '")' : "layoutmsg swapcol " + d)
  }
  return out
}

// ---- Drag to reorder ---------------------------------------------------------
// Column index whose centre is nearest to `pos` (px along the bar's axis).
// `cols` is layoutTape().cols = [{ start, len }].
function slotAt(cols, pos) {
  var list = cols || []
  var best = -1, bestDist = Infinity
  for (var i = 0; i < list.length; i++) {
    var d = Math.abs(list[i].start + list[i].len / 2 - Number(pos))
    if (d < bestDist) { best = i; bestDist = d }
  }
  return best
}

// The swapcol steps that move a column from index `from` to `to`: ["r", "r", ...] / ["l", ...].
function swapPlan(from, to) {
  var f = Math.round(Number(from)), t = Math.round(Number(to))
  if (!isFinite(f) || !isFinite(t) || f === t || f < 0 || t < 0) return []
  var out = []
  for (var i = 0; i < Math.abs(t - f); i++) out.push(t > f ? "r" : "l")
  return out
}

var GROUP_STYLE_ORDER = ["tabbar", "letter"]
var GROUP_STYLES = {
  tabbar: { label: "Tab bar", description: "A row of tabs along the top of the box" },
  letter: { label: "Letter \"t\"", description: "A t in the middle of the box" }
}
function resolveGroupStyle(id) {
  return Object.prototype.hasOwnProperty.call(GROUP_STYLES, id) ? id : "tabbar"
}

function resolveSettings(raw) {
  var s = raw || {}
  return {
    numberStyle: resolveNumberStyle(String(s.numberStyle || "")),
    maxWidth: clampInt(s.maxWidth, 60, 600, 200),
    gap: clampInt(s.gap, 0, 12, 3),
    showFloating: s.showFloating === true,
    groupStyle: resolveGroupStyle(String(s.groupStyle || "")),
    animStyle: resolveAnimStyle(String(s.animStyle || "")),
    attention: s.attention !== false,
    boxActions: s.boxActions === true,
    dragReorder: s.dragReorder === true,
    stateMarkers: s.stateMarkers !== false
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeAddress: normalizeAddress, eligibleClients: eligibleClients,
    orderByPosition: orderByPosition, overlapFraction: overlapFraction,
    sizeFraction: sizeFraction, clampInt: clampInt,
    THEME_COLOR_KEYS: THEME_COLOR_KEYS, parseThemeColors: parseThemeColors,
    ensureContrast: ensureContrast, hexToRgb: hexToRgb, rgbToHex: rgbToHex,
    NUMBER_STYLE_ORDER: NUMBER_STYLE_ORDER, NUMBER_STYLES: NUMBER_STYLES,
    resolveNumberStyle: resolveNumberStyle, formatWorkspace: formatWorkspace,
    groupedOf: groupedOf, collapseGroups: collapseGroups,
    GROUP_STYLE_ORDER: GROUP_STYLE_ORDER, GROUP_STYLES: GROUP_STYLES, resolveGroupStyle: resolveGroupStyle,
    groupColumns: groupColumns, layoutTape: layoutTape,
    ANIM_STYLE_ORDER: ANIM_STYLE_ORDER, ANIM_STYLES: ANIM_STYLES, resolveAnimStyle: resolveAnimStyle,
    motionFor: motionFor, attentionLevel: attentionLevel,
    menuItemsFor: menuItemsFor, actionCommand: actionCommand, pickAlertTarget: pickAlertTarget,
    slotAt: slotAt, swapPlan: swapPlan, swapCommands: swapCommands,
    rowKeyFor: rowKeyFor, reconcileAlerts: reconcileAlerts, parseNotification: parseNotification, urgentAddress: urgentAddress, matchNotificationWindow: matchNotificationWindow, buildColumns: buildColumns, resolveSettings: resolveSettings
  }
}
